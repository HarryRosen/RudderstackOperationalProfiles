-- scripts/diagnose_null_primary_customerid.sql
--
-- Diagnostics for profiles that carry customer ids but resolve no primary_customerid,
-- and therefore never propagate to the Customer model.
--
-- Background: primary_customerid is a window MAX over the whole user_main_id partition
-- in models/contact_with_retail, so it is constant per profile and
--     primary_customerid IS NULL
-- is equivalent by construction to
--     mainline_customerid IS NULL AND outlet_customerid IS NULL
-- The extra two predicates are redundant. A null primary means the profile has no
-- seccode 02 and no seccode 04 contact reachable through the user_id path.
--
-- A null primary also empties contact_primary_filtered, contact_retail_primary_filtered
-- and address_primary_filtered, which is why these profiles show null name, phone,
-- prefix and postal code. language_preference still reads 'en' because
-- language_preference_filled coalesces to 'en' for every stitched user.
--
-- Baseline taken 2026-09-02, before inputs/salesentity_merge_request was added:
--   125,304 profiles with a non-empty customer_ids_list and a null primary
--     104,330  seccode F6UJ9A000018  retired business line, correctly discarded
--       7,266  seccode SYST00000001  system records, correctly discarded
--       3,077  seccode F6UJ9A000010  non-customer records, correctly discarded
--          70  N/U-prefixed codes    advisor-private records, correctly discarded
--       9,208  contact_retail orphan, no contact row            DEFECT
--       1,134  seccode F6UJ9A000017 with no 02/04 partner       DEFECT
--         224  seccode F6UJ9A000002 in the list, still null     DEFECT
--   10,394 of these gain a primary once the salesentity edges land.

-- 1. Split the null-primary population by what its customer ids actually point at.
WITH bad AS (
  SELECT user_main_id, customer_ids_list
  FROM datalayer_prod.rudderstackoperationalprofiles.user_feature_view
  WHERE array_size(customer_ids_list) >= 1
    AND primary_customerid IS NULL
),
exploded AS (
  SELECT b.user_main_id, t.cid AS customerid
  FROM bad b LATERAL VIEW explode(b.customer_ids_list) t AS cid
)
SELECT
  CASE
    WHEN cr.customerid IS NULL THEN 'A: no contact_retail row for that customerid'
    WHEN c.contactid  IS NULL THEN 'B: contact_retail orphan, no contact row'
    WHEN c.seccodeid  IS NULL THEN 'C: contact.seccodeid is NULL'
    ELSE 'D: seccode ' || c.seccodeid
  END AS bucket,
  count(DISTINCT e.user_main_id) AS profiles,
  count(*)                       AS customerid_rows
FROM exploded e
LEFT JOIN datalayer_prod.sysdba.contact_retail cr ON e.customerid = cr.customerid
LEFT JOIN datalayer_prod.sysdba.contact        c  ON cr.contactid = c.contactid
GROUP BY 1
ORDER BY profiles DESC;

-- 2. Did contact_with_retail produce anything at all for these profiles?
SELECT
  CASE WHEN cwr.user_main_id IS NULL
       THEN 'contact_with_retail empty for profile'
       ELSE 'has rows, but none are 02/04' END AS bucket,
  count(*) AS profiles
FROM datalayer_prod.rudderstackoperationalprofiles.user_feature_view v
LEFT JOIN (SELECT DISTINCT user_main_id
           FROM datalayer_prod.rudderstackoperationalprofiles.contact_with_retail) cwr
  ON v.user_main_id = cwr.user_main_id
WHERE array_size(v.customer_ids_list) >= 1 AND v.primary_customerid IS NULL
GROUP BY 1;

-- 3. Trace a single profile end to end.
SELECT other_id_type, other_id
FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
WHERE user_main_id = 'rid9e177f9f149add6ba1bfe48958fdb6a6'
ORDER BY other_id_type, other_id;

-- 4. Sentinel customerids. Anything above degree 6 is a house or placeholder account
--    and is excluded by the view. Re-run before changing the cap.
WITH pairs AS (
  SELECT DISTINCT CAST(customerid AS STRING) AS customerid, contactid
    FROM datalayer_prod.sysdba.salesentity
   WHERE customerid IS NOT NULL AND contactid IS NOT NULL
  UNION
  SELECT DISTINCT CAST(customerid AS STRING) AS customerid, contactid
    FROM datalayer_prod.sysdba.contact_retail
   WHERE customerid IS NOT NULL AND contactid IS NOT NULL
)
SELECT customerid, count(DISTINCT contactid) AS contact_degree
FROM pairs
GROUP BY 1
HAVING count(DISTINCT contactid) > 6
ORDER BY 2 DESC;
