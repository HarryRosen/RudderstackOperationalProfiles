-- scripts/dryrun_salesentity_bridge.sql
--
-- Pre-flight blast-radius checks for inputs/salesentity_bridge. Read-only, and every
-- query runs against the CURRENT materialized state, so all of it can be run before the
-- pb run. Requires the view to be deployed first.
--
-- The bridge changes the id graph, so its effect is predicted rather than computed:
-- sections C3 to C6 simulate the fusion with label propagation over the existing
-- clusters. Treat the numbers as a LOWER BOUND - pb's stitcher also re-walks email and
-- user_id edges these queries do not, so real fusions can come out slightly larger than
-- predicted here, never smaller.
--
-- Companion files:
--   diagnose_pos_null_primary.sql  why this view exists, with the measured evidence
--   README.md                      deploy, permissions, ownership, rollback
--   dryrun_spot_checks.sql         the equivalent checks for salesentity_merge_request
--
-- Expected population, measured 2026-09-23: 42,960 POS profiles stranded because their
-- customerid exists only in salesentity. Of those the POS-side report found 42,093 whose
-- CRM identity already holds a correct primary_customerid.

-- ---------------------------------------------------------------------------
-- C0. BASELINE. Run this immediately before the pb run, and again after.
--
--     Section 5 of validate_salesentity_merge_request.sql does NOT measure this change.
--     It filters on size(customer_ids_list) >= 1, and the profiles this view rescues have
--     an EMPTY customer_ids_list - that is precisely what makes them stranded. Section 5
--     should stay roughly flat across this run; this query is the headline instead.
--
--     Nor is it derivable from primary_customerid_snapshot, which carries neither
--     pkcustomerno nor customer_ids_list. Capture it before the run or not at all.
--
--     Expected: about 59,839 before, dropping by roughly 42,093 after. The remainder is
--     the 16,713 with no identificationno plus the 166 matching nothing, neither of which
--     this view can reach - they need a source-side fix.
--
--     As with run B, do not read 0b's gained_a_primary as the recovery count. A rescued
--     POS profile usually merges INTO the CRM identity, so its user_main_id disappears
--     and it lands in merged_away rather than gained_a_primary. This query is the number
--     that answers "how many POS profiles were recovered".
-- ---------------------------------------------------------------------------
SELECT
  count(*) AS stranded_pos_profiles,
  count(CASE WHEN size(pkcustomerno) > 1 THEN 1 END) AS with_multiple_pos_ids
FROM datalayer_prod.rudderstackoperationalprofiles.user_feature_view
WHERE primary_customerid IS NULL
  AND (customer_ids_list IS NULL OR size(customer_ids_list) = 0)
  AND pkcustomerno IS NOT NULL;


-- ---------------------------------------------------------------------------
-- C1. Shape of the bridge. Expect roughly 43,000 edges.
--
--     customerids should be very close to edges: the ideal bridge row is one customerid
--     mapping to exactly one contact. A large gap means the degree cap is doing more work
--     than expected and C2 is where to look.
-- ---------------------------------------------------------------------------
SELECT
  count(*)                                              AS edges,
  count(DISTINCT customerid)                            AS customerids,
  count(DISTINCT contactid)                             AS contactids,
  round(count(*) / count(DISTINCT customerid), 3)       AS contacts_per_customerid,
  count(CASE WHEN contact_row_missing THEN 1 END)       AS orphan_contact_rows,
  count(CASE WHEN seccodeid = 'F6UJ9A000002' THEN 1 END) AS seccode_02,
  count(CASE WHEN seccodeid = 'F6UJ9A000004' THEN 1 END) AS seccode_04,
  count(CASE WHEN seccodeid = 'F6UJ9A000017' THEN 1 END) AS seccode_17
FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_bridge;


-- ---------------------------------------------------------------------------
-- C2. The UNGUARDED direction. The view caps contacts per customerid at 6, but does not
--     cap customerids per contact, because one person legitimately holds many duplicated
--     customer records - MONETTI and MYDLAND carry 59 and 54 with a single surname and
--     email each. Capping it would drop real recoveries.
--
--     This is the review that replaces that cap. A contactid pulling in 50+ POS profiles
--     is worth opening before the run; one pulling in 3 is the expected case.
-- ---------------------------------------------------------------------------
SELECT contactid,
       count(DISTINCT customerid) AS customerids_bridged,
       min(seccodeid)             AS seccodeid
FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_bridge
GROUP BY contactid
ORDER BY customerids_bridged DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- C3. Edge triage against the live graph. Splits the bridge by what it would actually do.
--
--     cross_cluster_real_merges is the number that matters. Unlike the merge view, the
--     no-op bucket here should be SMALL: by construction these customerids have no
--     contact_retail row, so there is usually nothing already joining the two sides.
--     A large no-op count would mean the scope guard is not doing what it claims.
--
--     customerid_not_in_stitcher counts bridge rows whose customerid appears on no
--     profile at all - salesentity customerids that never reached vstore.customer. Those
--     are inert: the edge is emitted but there is no POS profile to rescue.
-- ---------------------------------------------------------------------------
WITH uid AS (
  SELECT other_id AS customerid, user_main_id
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
  WHERE other_id_type = 'user_id'
),
cid AS (
  SELECT other_id AS contactid, user_main_id
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
  WHERE other_id_type = 'contact_id'
),
e AS (
  SELECT b.customerid, b.contactid,
         u.user_main_id AS umid_customer,
         c.user_main_id AS umid_contact
  FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_bridge b
  LEFT JOIN uid u ON u.customerid = b.customerid
  LEFT JOIN cid c ON c.contactid  = b.contactid
)
SELECT
  count(*) AS total_edges,
  count(CASE WHEN umid_customer IS NOT NULL AND umid_contact IS NOT NULL
              AND umid_customer =  umid_contact THEN 1 END) AS noop_already_same_cluster,
  count(CASE WHEN umid_customer IS NOT NULL AND umid_contact IS NOT NULL
              AND umid_customer <> umid_contact THEN 1 END) AS cross_cluster_real_merges,
  count(CASE WHEN umid_customer IS NULL THEN 1 END)         AS customerid_not_in_stitcher,
  count(CASE WHEN umid_contact  IS NULL THEN 1 END)         AS contactid_not_in_stitcher
FROM e;


-- ---------------------------------------------------------------------------
-- C4. Fusion blast radius. Label propagation over the cluster-merge graph implied by the
--     cross-cluster edges, so the collapse is visible before pb runs.
--
--     Three passes covers chains about 8 clusters deep. Read worst_case_fusion: the
--     comparable figure from the merge view's dry run was 31 clusters into 93 ids, and
--     that turned out to be a single person. Anything far past that is a hub worth
--     opening in C5 first.
-- ---------------------------------------------------------------------------
WITH uid AS (
  SELECT other_id AS customerid, user_main_id
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
  WHERE other_id_type = 'user_id'
),
cid AS (
  SELECT other_id AS contactid, user_main_id
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
  WHERE other_id_type = 'contact_id'
),
pairs AS (
  SELECT DISTINCT u.user_main_id AS a, c.user_main_id AS b
  FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_bridge br
  JOIN uid u ON u.customerid = br.customerid
  JOIN cid c ON c.contactid  = br.contactid
  WHERE u.user_main_id <> c.user_main_id
),
edges AS (
  SELECT a AS u, b AS v FROM pairs
  UNION SELECT b, a FROM pairs
  UNION SELECT a, a FROM pairs
  UNION SELECT b, b FROM pairs
),
l1 AS (SELECT u AS node, min(v) AS label FROM edges GROUP BY u),
l2 AS (SELECT e.u AS node, min(l1.label) AS label FROM edges e JOIN l1 ON l1.node = e.v GROUP BY e.u),
l3 AS (SELECT e.u AS node, min(l2.label) AS label FROM edges e JOIN l2 ON l2.node = e.v GROUP BY e.u),
groups AS (SELECT label, count(DISTINCT node) AS clusters_fused FROM l3 GROUP BY label)
SELECT
  count(*)                                        AS post_run_profiles_affected,
  sum(clusters_fused)                             AS existing_profiles_absorbed,
  sum(clusters_fused) - count(*)                  AS net_profile_count_reduction,
  max(clusters_fused)                             AS worst_case_fusion,
  count(CASE WHEN clusters_fused =  2 THEN 1 END) AS simple_pairs,
  count(CASE WHEN clusters_fused >  5 THEN 1 END) AS groups_over_5
FROM groups;


-- ---------------------------------------------------------------------------
-- C5. Post-fusion coherence. The same diagnostic applied to salesentity_merge_request,
--     run against the profiles this view would CREATE.
--
--     Read distinct_lastnames and distinct_emails as before. One surname across a large
--     fusion is a person with a fragmented record, which is the point. A double-digit
--     surname count means the bridge has walked across unrelated people and the guards
--     need revisiting. On the merge view 55 of 56 groups came back single-surname.
-- ---------------------------------------------------------------------------
WITH uid AS (
  SELECT other_id AS customerid, user_main_id
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
  WHERE other_id_type = 'user_id'
),
cid AS (
  SELECT other_id AS contactid, user_main_id
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
  WHERE other_id_type = 'contact_id'
),
pairs AS (
  SELECT DISTINCT u.user_main_id AS a, c.user_main_id AS b
  FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_bridge br
  JOIN uid u ON u.customerid = br.customerid
  JOIN cid c ON c.contactid  = br.contactid
  WHERE u.user_main_id <> c.user_main_id
),
edges AS (
  SELECT a AS u, b AS v FROM pairs
  UNION SELECT b, a FROM pairs
  UNION SELECT a, a FROM pairs
  UNION SELECT b, b FROM pairs
),
l1 AS (SELECT u AS node, min(v) AS label FROM edges GROUP BY u),
l2 AS (SELECT e.u AS node, min(l1.label) AS label FROM edges e JOIN l1 ON l1.node = e.v GROUP BY e.u),
l3 AS (SELECT e.u AS node, min(l2.label) AS label FROM edges e JOIN l2 ON l2.node = e.v GROUP BY e.u),
big AS (
  SELECT label, count(DISTINCT node) AS clusters_fused
  FROM l3 GROUP BY label HAVING count(DISTINCT node) > 5
),
member_contacts AS (
  SELECT b.label, b.clusters_fused, st.other_id AS contactid
  FROM big b
  JOIN l3 ON l3.label = b.label
  JOIN datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher st
    ON st.user_main_id = l3.node AND st.other_id_type = 'contact_id'
)
SELECT
  m.label                     AS simulated_group_label,
  m.clusters_fused,
  count(DISTINCT m.contactid) AS contactids,
  count(DISTINCT CASE WHEN coalesce(trim(c.email), '') <> ''
                      THEN lower(trim(c.email)) END)    AS distinct_emails,
  count(DISTINCT CASE WHEN coalesce(trim(c.lastname), '') NOT IN ('', '-')
                      THEN upper(trim(c.lastname)) END) AS distinct_lastnames,
  min(upper(trim(c.lastname))) AS sample_lastname
FROM member_contacts m
LEFT JOIN datalayer_prod.sysdba.contact c ON c.contactid = m.contactid
GROUP BY m.label, m.clusters_fused
ORDER BY m.clusters_fused DESC, distinct_lastnames DESC
LIMIT 50;


-- ---------------------------------------------------------------------------
-- C6. Predicted recoveries. Stranded POS profiles - no customerid, no primary - that
--     would be fused with a cluster already carrying a live 02/04 customerid.
--
--     Expect this near 42,093, the figure the POS-side report measured as having a
--     known-good primary one join away. Materially lower means a guard is eating
--     recoveries; materially higher means the bridge reaches further than intended and
--     C4 is the place to look.
-- ---------------------------------------------------------------------------
WITH uid AS (
  SELECT other_id AS customerid, user_main_id
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
  WHERE other_id_type = 'user_id'
),
cid AS (
  SELECT other_id AS contactid, user_main_id
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
  WHERE other_id_type = 'contact_id'
),
pairs AS (
  SELECT DISTINCT u.user_main_id AS a, c.user_main_id AS b
  FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_bridge br
  JOIN uid u ON u.customerid = br.customerid
  JOIN cid c ON c.contactid  = br.contactid
  WHERE u.user_main_id <> c.user_main_id
),
edges AS (
  SELECT a AS u, b AS v FROM pairs
  UNION SELECT b, a FROM pairs
  UNION SELECT a, a FROM pairs
  UNION SELECT b, b FROM pairs
),
l1 AS (SELECT u AS node, min(v) AS label FROM edges GROUP BY u),
l2 AS (SELECT e.u AS node, min(l1.label) AS label FROM edges e JOIN l1 ON l1.node = e.v GROUP BY e.u),
l3 AS (SELECT e.u AS node, min(l2.label) AS label FROM edges e JOIN l2 ON l2.node = e.v GROUP BY e.u),
has_primary_source AS (
  SELECT DISTINCT st.user_main_id
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher st
  JOIN datalayer_prod.sysdba.contact_retail cr ON cr.customerid = st.other_id
  JOIN datalayer_prod.sysdba.contact c ON c.contactid = cr.contactid
  WHERE st.other_id_type = 'user_id'
    AND c.seccodeid IN ('F6UJ9A000002','F6UJ9A000004')
),
good_groups AS (
  SELECT DISTINCT l3.label
  FROM l3 JOIN has_primary_source h ON h.user_main_id = l3.node
),
stranded_pos AS (
  SELECT user_main_id
  FROM datalayer_prod.rudderstackoperationalprofiles.user_feature_view
  WHERE primary_customerid IS NULL
    AND (customer_ids_list IS NULL OR size(customer_ids_list) = 0)
    AND pkcustomerno IS NOT NULL
)
SELECT count(DISTINCT s.user_main_id) AS pos_profiles_predicted_to_gain_a_primary
FROM stranded_pos s
JOIN l3 ON l3.node = s.user_main_id
JOIN good_groups g ON g.label = l3.label;


-- ---------------------------------------------------------------------------
-- C7. Reverse degree cap: what does each threshold cost?
--
--     The first dry run returned worst_case_fusion = 414 against the merge view's 31,
--     caused by placeholder contacts on the uncapped reverse side - C2 showed one
--     contactid bridging 444 customerids and another 299, and C5 named some of them
--     (TRANSACTIONS, VISITOR, A, and several with no name and no email).
--
--     This table prices each candidate cap. customerids_dropped is the recovery cost;
--     max_fan_in_retained is the new worst case on the reverse side.
--
--     Note a cap alone will not separate clean from junk. RAMNAUTH at 22 has 9 contacts,
--     one email and one surname and looks like a real person; TRANSACTIONS at 22 has 2
--     contacts and no email. Same fan-in, opposite verdict. Pair the cap with C8.
-- ---------------------------------------------------------------------------
WITH deg AS (
  SELECT contactid, count(DISTINCT customerid) AS n
  FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_bridge
  GROUP BY contactid
),
caps AS (SELECT explode(array(5, 10, 15, 20, 25, 30, 50, 100, 250)) AS cap)
SELECT
  c.cap,
  sum(CASE WHEN d.n <= c.cap THEN d.n ELSE 0 END) AS customerids_retained,
  sum(CASE WHEN d.n >  c.cap THEN d.n ELSE 0 END) AS customerids_dropped,
  count(CASE WHEN d.n > c.cap THEN 1 END)         AS contacts_excluded,
  max(CASE WHEN d.n <= c.cap THEN d.n END)        AS max_fan_in_retained
FROM deg d
CROSS JOIN caps c
GROUP BY c.cap
ORDER BY c.cap;


-- ---------------------------------------------------------------------------
-- C8. Who are the high fan-in contacts? Judge junk versus fragmented-but-real directly
--     rather than inferring it from a count. A placeholder contact typically has no
--     email, a junk or missing surname, and often a firstname that reads as a label.
--
--     Anything identified here as a placeholder should be excluded by name or by a
--     blank-identity rule in the view, not only by the numeric cap in C7 - C5 found
--     VISITOR at a fan-in of 11, well inside any cap worth setting.
-- ---------------------------------------------------------------------------
WITH deg AS (
  SELECT contactid, count(DISTINCT customerid) AS customerids_bridged
  FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_bridge
  GROUP BY contactid
  HAVING count(DISTINCT customerid) >= 10
)
SELECT
  d.contactid,
  d.customerids_bridged,
  c.seccodeid,
  upper(trim(c.firstname))   AS firstname,
  upper(trim(c.lastname))    AS lastname,
  lower(trim(c.email))       AS email,
  CAST(c.createdate AS DATE) AS createdate
FROM deg d
LEFT JOIN datalayer_prod.sysdba.contact c ON c.contactid = d.contactid
ORDER BY d.customerids_bridged DESC
LIMIT 60;


-- ---------------------------------------------------------------------------
-- C9. Is name-blanking a historical convention or junk data?
--
--     C8 showed high fan-in contacts with null names, doubled names (MM/MM, A/A, L/L),
--     initials and numerics. Two readings: placeholder records, or the house style for
--     a customer who gave no details, in which case they are real people and excluding
--     them by name would discard legitimate bridges across the whole edge set.
--
--     This decides it on prevalence and age together:
--       a convention shows up as a large share of contacts, concentrated in older
--       createdates, with an ORDINARY fan-in distribution
--       junk shows up as a small number of contacts with a wildly high fan-in
--
--     Read max_fan_in and avg_fan_in per pattern against contacts. A pattern covering
--     20% of contacts at avg_fan_in near 1 is a convention and must not be excluded by
--     name. The same pattern on 40 contacts at avg_fan_in 60 is a catch-all bucket.
-- ---------------------------------------------------------------------------
WITH deg AS (
  SELECT contactid, count(DISTINCT customerid) AS fan_in
  FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_bridge
  GROUP BY contactid
)
SELECT
  CASE
    WHEN coalesce(trim(c.email), '') <> ''                               THEN 'has email'
    WHEN coalesce(trim(c.lastname), '') IN ('', '.', '-')                THEN 'blank or dash name'
    WHEN upper(trim(c.firstname)) = upper(trim(c.lastname))              THEN 'doubled name'
    WHEN trim(c.lastname) RLIKE '^[0-9]+$'                               THEN 'numeric name'
    WHEN length(trim(c.lastname)) <= 2                                   THEN 'initials'
    ELSE                                                                      'named, no email'
  END                                          AS pattern,
  count(*)                                     AS contacts,
  sum(d.fan_in)                                AS customerids_bridged,
  round(avg(d.fan_in), 2)                      AS avg_fan_in,
  max(d.fan_in)                                AS max_fan_in,
  min(year(c.createdate))                      AS oldest_year,
  percentile_approx(year(c.createdate), 0.5)   AS median_year,
  max(year(c.createdate))                      AS newest_year
FROM deg d
LEFT JOIN datalayer_prod.sysdba.contact c ON c.contactid = d.contactid
GROUP BY 1
ORDER BY contacts DESC;


-- ---------------------------------------------------------------------------
-- C10. The decisive test: is a high fan-in contact ONE person or MANY?
--
--      Whatever the CRM contact looks like, the POS side may still carry identifying
--      detail. If the customerids bridging into one contact resolve to many different
--      surnames in vstore.customer, the bridge would merge unrelated people and the
--      contact must be excluded regardless of why its name is blank. If they resolve to
--      one surname, it is a single fragmented customer and the bridge is correct.
--
--      Run DESCRIBE first - column names on vstore.customer need confirming before this
--      is trusted, and the name columns below are a guess:
--        DESCRIBE datalayer_prod.vstore.customer;
-- ---------------------------------------------------------------------------
WITH deg AS (
  SELECT contactid, count(DISTINCT customerid) AS fan_in
  FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_bridge
  GROUP BY contactid
  HAVING count(DISTINCT customerid) >= 20
),
bridged AS (
  SELECT b.contactid, b.customerid, d.fan_in
  FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_bridge b
  JOIN deg d ON d.contactid = b.contactid
)
SELECT
  br.contactid,
  max(br.fan_in)                                     AS customerids_bridged,
  count(DISTINCT upper(trim(vc.lastname)))           AS distinct_pos_lastnames,
  count(DISTINCT lower(trim(vc.emailaddress)))       AS distinct_pos_emails,
  min(upper(trim(vc.lastname)))                      AS sample_lastname_a,
  max(upper(trim(vc.lastname)))                      AS sample_lastname_b
FROM bridged br
LEFT JOIN datalayer_prod.vstore.customer vc
  ON CAST(vc.identificationno AS STRING) = CAST(br.customerid AS STRING)
GROUP BY br.contactid
ORDER BY customerids_bridged DESC
LIMIT 30;
