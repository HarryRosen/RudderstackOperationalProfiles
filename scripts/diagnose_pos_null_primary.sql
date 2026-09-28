-- scripts/diagnose_pos_null_primary.sql
--
-- Triage for the 148,442 POS profiles reported with a NULL primary_customerid
-- (Prakash Manoharan, prod, 2026-09-22). That report splits them into:
--
--   Defect A  105,486 rows  primary never promoted, customer_ids_list is populated
--   Defect B   42,956 rows  POS profile and CRM customerid sit on different identities
--
-- These queries decide what each bucket actually is before any model change is made.
-- All read-only.
--
-- The short version of the disagreement this resolves:
--
--   contact_with_retail derives the primary through
--     contact_retail.customerid -> contact_retail.contactid -> contact.contactid
--   and then filters WHERE contact.seccodeid IN (02, 04, 17).
--
--   customer_ids_list is array_agg over inputs/contact_retail with NO seccode filter.
--
-- So a profile whose contacts are all seccode 18 / SYST / 10 / advisor-private gets a
-- populated customer_ids_list and a null primary BY DESIGN. That is the population
-- section 5 of validate_salesentity_merge_request.sql measures (114,881 after run B),
-- and Defect A is expected to be a subset of it. Section A1 below proves or disproves
-- that in one query.

-- ---------------------------------------------------------------------------
-- A1. What is Defect A actually made of? This is the query that decides whether any
--     model change is warranted, and it splits the population three ways:
--
--       seccode 18 / SYST / 10 / advisor-private
--           Working as designed. "Fixing" this is a policy change, not a bug fix - it
--           means promoting retired-business-line and non-customer records to primary,
--           which is the decision the project explicitly made the other way. It may
--           still be the right call for the POS use case, but it is a product decision
--           with downstream blast radius, not a defect.
--
--       <no contact row>
--           Arguably a real bug and cheap to fix. contact_with_retail INNER JOINs
--           sysdba.contact, so a contact_retail row whose contactid has no contact row
--           is dropped. views/salesentity_merge_request.sql deliberately ALLOWS that
--           same case through as a valid stitching id, so excluding it here is
--           inconsistent with how the rest of the project treats orphans.
--
--       seccode 02 / 04
--           Should be impossible. Any volume here is a genuine defect in
--           contact_with_retail and needs investigating before anything else.
-- ---------------------------------------------------------------------------
WITH defect_a AS (
  SELECT user_main_id, explode(customer_ids_list) AS customerid
  FROM datalayer_prod.rudderstackoperationalprofiles.user_feature_view
  WHERE primary_customerid IS NULL
    AND size(customer_ids_list) > 0
),
resolved AS (
  SELECT a.user_main_id,
         a.customerid,
         c.seccodeid,
         cr.contactid
  FROM defect_a a
  LEFT JOIN datalayer_prod.sysdba.contact_retail cr ON cr.customerid = a.customerid
  LEFT JOIN datalayer_prod.sysdba.contact c ON c.contactid = cr.contactid
)
SELECT
  CASE
    WHEN contactid IS NULL                            THEN 'no contact_retail row'
    WHEN seccodeid IS NULL                            THEN 'orphan - no contact row'
    WHEN seccodeid IN ('F6UJ9A000002','F6UJ9A000004') THEN 'BUG - 02/04 should have a primary'
    WHEN seccodeid  = 'F6UJ9A000017'                  THEN '17 only - merged secondary'
    WHEN seccodeid  = 'F6UJ9A000018'                  THEN '18 - retired line, by design'
    ELSE                                                   concat('other seccode: ', seccodeid)
  END                              AS bucket,
  count(*)                         AS customerid_rows,
  count(DISTINCT user_main_id)     AS profiles
FROM resolved
GROUP BY 1
ORDER BY customerid_rows DESC;


-- ---------------------------------------------------------------------------
-- A2. Profile-level view of the same thing. A profile is only a genuine defect if NONE
--     of its customerids resolve to a live 02/04 contact. If a profile has a 02/04
--     customerid available and still came out with a null primary, that is a real bug
--     and this is the query that surfaces it.
-- ---------------------------------------------------------------------------
WITH defect_a AS (
  SELECT user_main_id, explode(customer_ids_list) AS customerid
  FROM datalayer_prod.rudderstackoperationalprofiles.user_feature_view
  WHERE primary_customerid IS NULL
    AND size(customer_ids_list) > 0
),
per_profile AS (
  SELECT a.user_main_id,
         max(CASE WHEN c.seccodeid IN ('F6UJ9A000002','F6UJ9A000004') THEN 1 ELSE 0 END) AS has_0204,
         max(CASE WHEN c.contactid IS NULL THEN 1 ELSE 0 END)                            AS has_orphan,
         count(DISTINCT a.customerid)                                                    AS customerids
  FROM defect_a a
  LEFT JOIN datalayer_prod.sysdba.contact_retail cr ON cr.customerid = a.customerid
  LEFT JOIN datalayer_prod.sysdba.contact c ON c.contactid = cr.contactid
  GROUP BY 1
)
SELECT
  CASE WHEN has_0204 = 1  THEN 'BUG - had a 02/04 available, still null'
       WHEN has_orphan = 1 THEN 'orphan only - fixable without a policy change'
       ELSE                    'excluded seccodes only - working as designed'
  END                  AS verdict,
  count(*)             AS profiles,
  sum(customerids)     AS customerids,
  max(customerids)     AS most_customerids_on_one_profile
FROM per_profile
GROUP BY 1
ORDER BY profiles DESC;


-- ---------------------------------------------------------------------------
-- A3. Is seccode 18 actually retired? A1 and A2 reduced Defect A to this single
--     question: 105,880 of the 116,393 customerids are seccode 18, zero profiles were
--     stranded with a usable 02/04 primary, and SYST / 10 are unambiguously non-customer
--     records that stay excluded either way.
--
--     The exclusion rests on 18 being a RETIRED business line. These records carry POS
--     profiles, so they transacted at some point. This query decides whether that is
--     history or current activity, which is the input the policy decision actually needs.
--
--     If the bulk last transacted years ago, the exclusion is correct and Defect A is
--     closed as working-as-designed. If a material number transacted in the last year or
--     two, seccode 18 is not retired in practice and promoting it to primary is worth
--     doing - noting it changes primary_customerid for every downstream consumer, not
--     just POS, so it is a decision for the model owner and not a local POS fix.
--
--     ANSWERED, 2026-09-23. Seccode 18 is retired. Of 105,880 customerids across 104,322
--     profiles: 4 transacted in the last 12 months, ZERO in the 12-24 month window, 86,211
--     over 24 months ago and 19,665 never. Oldest 2010-01-02, newest 2026-06-04.
--
--     A two year gap with four stragglers is a line that stopped, not one with residual
--     activity. The exclusion stands and Defect A is closed as working-as-designed.
--
--     The distinction to hold onto: primary_customerid means "the primary of this
--     profile's ACTIVE identity", not "any customerid this contact ever had". A report
--     that needs a customerid on historical rows should read the raw CRM customerid, the
--     way datalayer_prod.tableau_data.gen5y_contacts already does, rather than resolving
--     through the graph. The two are answering different questions and it is correct that
--     they disagree on dormant records.
-- ---------------------------------------------------------------------------
WITH defect_a AS (
  SELECT user_main_id, explode(customer_ids_list) AS customerid
  FROM datalayer_prod.rudderstackoperationalprofiles.user_feature_view
  WHERE primary_customerid IS NULL
    AND size(customer_ids_list) > 0
),
sec18 AS (
  SELECT DISTINCT a.user_main_id, a.customerid, cr.last_transaction_date
  FROM defect_a a
  JOIN datalayer_prod.sysdba.contact_retail cr ON cr.customerid = a.customerid
  JOIN datalayer_prod.sysdba.contact c ON c.contactid = cr.contactid
  WHERE c.seccodeid = 'F6UJ9A000018'
)
SELECT
  count(DISTINCT user_main_id) AS profiles,
  count(*)                     AS customerids,
  count(CASE WHEN last_transaction_date IS NULL THEN 1 END) AS never_transacted,
  count(CASE WHEN last_transaction_date >= add_months(current_date(), -12)  THEN 1 END) AS transacted_last_12m,
  count(CASE WHEN last_transaction_date >= add_months(current_date(), -24)
              AND last_transaction_date <  add_months(current_date(), -12)  THEN 1 END) AS transacted_12_to_24m,
  count(CASE WHEN last_transaction_date <  add_months(current_date(), -24)  THEN 1 END) AS transacted_over_24m_ago,
  min(last_transaction_date)   AS oldest_transaction,
  max(last_transaction_date)   AS newest_transaction
FROM sec18;


-- ---------------------------------------------------------------------------
-- B1. Why did the POS profile never stitch to CRM? pkcustomerno and identificationno
--     are both typed user_id in models/inputs.yaml, and contact_retail.customerid is
--     too, so the join is exact string equality on identificationno = customerid.
--     Anything that breaks that equality leaves the POS profile stranded.
--
--     Read the buckets as different fixes:
--       identificationno_missing    POS customer never linked back to CRM. No edge to
--                                   recover - this needs fixing at the source, not here.
--       matches_contact_retail      Should have stitched and did not. Investigate as a
--                                   real stitching defect before anything else.
--       only_in_salesentity         The contact_retail / salesentity disagreement again,
--                                   on the customerid->contactid axis this time. Fixable
--                                   with a new edge source, same shape as the
--                                   salesentity_merge_request work.
--       no_crm_match_anywhere       identificationno points at nothing. Source data issue.
--
--     ANSWERED, 2026-09-23. Of 59,839 stranded POS profiles:
--       16,713  identificationno missing        source fix, not recoverable from the graph
--            0  matches contact_retail          no stitching defect exists
--       42,960  ONLY IN SALESENTITY             the entire actionable population
--          166  no CRM match anywhere           source data
--
--     42,960 lands within 4 rows of the 42,956 the POS-side report scoped independently.
--     B2 ruled out formatting: 43,126 profiles carry an identificationno, zero match
--     contact_retail as-is and zero match after stripping leading zeros. B3 confirms it
--     row by row - contact_retail_contactid is null on every sample row while
--     salesentity_contactid is populated on every one.
--
--     Root cause: the model bridges customerid to contactid ONLY through contact_retail.
--     These customerids have no contact_retail row at all, so no edge exists or can. Same
--     contact_retail / salesentity disagreement that motivated salesentity_merge_request,
--     but a different shape - that view handles a customerid present in BOTH and pointing
--     at different contacts, whereas this is a customerid present in salesentity ONLY.
-- ---------------------------------------------------------------------------
WITH defect_b AS (
  SELECT user_main_id, explode(pkcustomerno) AS pk
  FROM datalayer_prod.rudderstackoperationalprofiles.user_feature_view
  WHERE primary_customerid IS NULL
    AND (customer_ids_list IS NULL OR size(customer_ids_list) = 0)
    AND pkcustomerno IS NOT NULL
),
vc AS (
  SELECT pkcustomerno, identificationno
  FROM datalayer_prod.vstore.customer
),
cr_ids AS (
  SELECT DISTINCT CAST(customerid AS STRING) AS customerid
  FROM datalayer_prod.sysdba.contact_retail
  WHERE customerid IS NOT NULL
),
se_ids AS (
  SELECT DISTINCT CAST(customerid AS STRING) AS customerid
  FROM datalayer_prod.sysdba.salesentity
  WHERE customerid IS NOT NULL
)
SELECT
  count(*) AS pos_profiles,
  count(CASE WHEN coalesce(trim(vc.identificationno), '') = '' THEN 1 END)
    AS identificationno_missing,
  count(CASE WHEN coalesce(trim(vc.identificationno), '') <> ''
              AND cr.customerid IS NOT NULL THEN 1 END)
    AS matches_contact_retail,
  count(CASE WHEN coalesce(trim(vc.identificationno), '') <> ''
              AND cr.customerid IS NULL AND se.customerid IS NOT NULL THEN 1 END)
    AS only_in_salesentity,
  count(CASE WHEN coalesce(trim(vc.identificationno), '') <> ''
              AND cr.customerid IS NULL AND se.customerid IS NULL THEN 1 END)
    AS no_crm_match_anywhere
FROM defect_b b
JOIN vc ON vc.pkcustomerno = b.pk
LEFT JOIN cr_ids cr ON cr.customerid = CAST(vc.identificationno AS STRING)
LEFT JOIN se_ids se ON se.customerid = CAST(vc.identificationno AS STRING);


-- ---------------------------------------------------------------------------
-- B2. Format check. The report's example pairs pkcustomerno '00000000392223' with an
--     expected customerid of '909900104347' - one zero-padded, one not. If
--     identificationno carries padding that contact_retail.customerid does not, exact
--     match stitching fails on every affected row and the fix is a normalisation in
--     inputs.yaml, not a new edge source.
--
--     matched_only_after_trim_zeros is the number that decides it. Anything above zero
--     means padding alone is breaking real links.
-- ---------------------------------------------------------------------------
WITH defect_b AS (
  SELECT user_main_id, explode(pkcustomerno) AS pk
  FROM datalayer_prod.rudderstackoperationalprofiles.user_feature_view
  WHERE primary_customerid IS NULL
    AND (customer_ids_list IS NULL OR size(customer_ids_list) = 0)
    AND pkcustomerno IS NOT NULL
),
vc AS (
  SELECT pkcustomerno, trim(identificationno) AS identificationno
  FROM datalayer_prod.vstore.customer
  WHERE coalesce(trim(identificationno), '') <> ''
),
cr_ids AS (
  SELECT DISTINCT CAST(customerid AS STRING) AS customerid
  FROM datalayer_prod.sysdba.contact_retail
  WHERE customerid IS NOT NULL
)
SELECT
  count(*) AS pos_profiles_with_identificationno,
  count(CASE WHEN raw.customerid IS NOT NULL THEN 1 END)  AS matched_as_is,
  count(CASE WHEN raw.customerid IS NULL
              AND stripped.customerid IS NOT NULL THEN 1 END) AS matched_only_after_trim_zeros,
  count(CASE WHEN raw.customerid IS NULL
              AND stripped.customerid IS NULL THEN 1 END)     AS unmatched_either_way
FROM defect_b b
JOIN vc ON vc.pkcustomerno = b.pk
LEFT JOIN cr_ids raw      ON raw.customerid      = vc.identificationno
LEFT JOIN cr_ids stripped ON stripped.customerid = regexp_replace(vc.identificationno, '^0+', '');


-- ---------------------------------------------------------------------------
-- B3. Eyeball sample. Twenty Defect B profiles with the raw values on both sides, so the
--     mismatch can be read directly rather than inferred from counts.
-- ---------------------------------------------------------------------------
WITH defect_b AS (
  SELECT user_main_id, explode(pkcustomerno) AS pk
  FROM datalayer_prod.rudderstackoperationalprofiles.user_feature_view
  WHERE primary_customerid IS NULL
    AND (customer_ids_list IS NULL OR size(customer_ids_list) = 0)
    AND pkcustomerno IS NOT NULL
)
SELECT b.user_main_id,
       b.pk                                        AS pkcustomerno,
       vc.identificationno,
       length(vc.identificationno)                 AS identificationno_len,
       regexp_replace(trim(vc.identificationno), '^0+', '') AS identificationno_unpadded,
       cr.contactid                                AS contact_retail_contactid,
       se.contactid                                AS salesentity_contactid
FROM defect_b b
JOIN datalayer_prod.vstore.customer vc ON vc.pkcustomerno = b.pk
LEFT JOIN datalayer_prod.sysdba.contact_retail cr ON CAST(cr.customerid AS STRING) = CAST(vc.identificationno AS STRING)
LEFT JOIN datalayer_prod.sysdba.salesentity   se ON CAST(se.customerid AS STRING) = CAST(vc.identificationno AS STRING)
LIMIT 20;
