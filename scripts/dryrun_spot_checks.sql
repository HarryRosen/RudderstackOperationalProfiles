-- scripts/dryrun_spot_checks.sql
--
-- Pre-flight blast-radius checks. Every query here is read-only and runs against the
-- CURRENT materialized state, so all of it can be run before either pb run.
--
-- Run A (deterministic ORDER BY in contact_with_retail) does not touch the id graph at
-- all, so its effect can be computed exactly from the live stitcher: sections A1 to A3.
--
-- Run B (salesentity edges) does change the graph, so its effect is predicted rather
-- than computed: sections B1 to B4 simulate the fusion with label propagation over the
-- existing clusters. Treat the B numbers as close estimates, not guarantees - pb's
-- stitcher also walks email and user_id edges that these queries do not re-walk, so
-- real fusions can be slightly larger than predicted here, never smaller.
--
-- Companion files: validate_salesentity_merge_request.sql (during and after the runs),
-- README.md (rationale and guards).

-- ---------------------------------------------------------------------------
-- 0. Find the materialized contact_with_retail. pb writes Material_<model>_<hash>_<n>
--    tables; section A2 and A3 need whichever name comes back here.
-- ---------------------------------------------------------------------------
SHOW TABLES IN datalayer_prod.rudderstackoperationalprofiles LIKE '*contact_with_retail*';


-- ---------------------------------------------------------------------------
-- A1. Run A eligible population. A profile can only move if more than one customerid
--     competes inside a single seccode partition. Everything else is arithmetically
--     incapable of changing, whatever the ORDER BY says.
--
--     This is the ceiling on run A. Expect the large majority of partitions to hold
--     exactly one customerid, i.e. contested should be a small slice of the total.
-- ---------------------------------------------------------------------------
WITH ucm AS (
  SELECT user_main_id, other_id AS customerid
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
  WHERE other_id_type = 'user_id'
),
ucd AS (
  SELECT ucm.user_main_id, c.seccodeid, cr.customerid
  FROM ucm
  JOIN datalayer_prod.sysdba.contact_retail cr ON ucm.customerid = cr.customerid
  JOIN datalayer_prod.sysdba.contact c ON cr.contactid = c.contactid
  WHERE c.seccodeid IN ('F6UJ9A000002','F6UJ9A000004','F6UJ9A000017')
)
SELECT
  seccodeid,
  count(*)                                                       AS partitions,
  count(CASE WHEN n > 1 THEN 1 END)                              AS contested_partitions,
  round(100.0 * count(CASE WHEN n > 1 THEN 1 END) / count(*), 2) AS pct_contested,
  max(n)                                                         AS max_customerids_in_one_partition
FROM (
  SELECT user_main_id, seccodeid, count(DISTINCT customerid) AS n
  FROM ucd
  GROUP BY 1, 2
)
GROUP BY seccodeid
ORDER BY seccodeid;


-- ---------------------------------------------------------------------------
-- A2. Run A exact diff. Recomputes contact_with_retail with the new ORDER BY against
--     the live stitcher and diffs it against what is materialized today.
--
--     REPLACE <cwr_table> with the name section 0 returned.
--
--     Caveat worth holding onto: the CURRENT value is a first_value with an empty
--     ORDER BY, so it is nondeterministic. A row showing as changed here does not mean
--     the new rule is wrong, it means the old rule had no opinion. The numbers that
--     must hold are gained = 0 and lost = 0; primary_changed can be any size.
-- ---------------------------------------------------------------------------
WITH ucm AS (
  SELECT user_main_id, other_id AS customerid
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
  WHERE other_id_type = 'user_id'
),
ucd AS (
  SELECT ucm.user_main_id, c.contactid, c.seccodeid, c.createdate,
         cr.customerid, cr.last_transaction_date
  FROM ucm
  JOIN datalayer_prod.sysdba.contact_retail cr ON ucm.customerid = cr.customerid
  JOIN datalayer_prod.sysdba.contact c ON cr.contactid = c.contactid
  WHERE c.seccodeid IN ('F6UJ9A000002','F6UJ9A000004','F6UJ9A000017')
),
prioritized AS (
  SELECT user_main_id, customerid,
    CASE WHEN seccodeid = 'F6UJ9A000002' THEN first_value(customerid) OVER (
      PARTITION BY user_main_id, seccodeid
      ORDER BY last_transaction_date DESC NULLS LAST, createdate ASC NULLS LAST, customerid ASC
      ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) END AS mainline_customerid,
    CASE WHEN seccodeid = 'F6UJ9A000004' THEN first_value(customerid) OVER (
      PARTITION BY user_main_id, seccodeid
      ORDER BY last_transaction_date DESC NULLS LAST, createdate ASC NULLS LAST, customerid ASC
      ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) END AS outlet_customerid
  FROM ucd
),
proposed AS (
  SELECT DISTINCT user_main_id,
    CAST(COALESCE(
      MAX(mainline_customerid) OVER (PARTITION BY user_main_id),
      MAX(outlet_customerid)   OVER (PARTITION BY user_main_id)
    ) AS STRING) AS primary_customerid
  FROM prioritized
),
live AS (
  SELECT DISTINCT user_main_id, primary_customerid
  FROM datalayer_prod.rudderstackoperationalprofiles.<cwr_table>
)
-- FULL OUTER, not INNER: an inner join silently drops any profile that exists on only
-- one side, which is exactly the failure this check is meant to catch. profile_appeared
-- and profile_vanished must both be 0, alongside gained and lost.
SELECT
  count(*) AS profiles_compared,
  count(CASE WHEN l.user_main_id IS NULL THEN 1 END) AS profile_appeared,
  count(CASE WHEN p.user_main_id IS NULL THEN 1 END) AS profile_vanished,
  count(CASE WHEN l.primary_customerid IS NULL
              AND p.primary_customerid IS NOT NULL THEN 1 END) AS gained_a_primary,
  count(CASE WHEN l.primary_customerid IS NOT NULL
              AND p.primary_customerid IS NULL THEN 1 END)     AS lost_a_primary,
  count(CASE WHEN l.primary_customerid <> p.primary_customerid THEN 1 END) AS primary_changed
FROM live l
FULL OUTER JOIN proposed p ON p.user_main_id = l.user_main_id;


-- ---------------------------------------------------------------------------
-- A3. Run A eyeball sample. Profiles where more than one customerid competes, with the
--     dates driving the new choice. new_rank = 1 is what run A will pick. Confirm the
--     winner is genuinely the more recently transacted record.
-- ---------------------------------------------------------------------------
WITH ucm AS (
  SELECT user_main_id, other_id AS customerid
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
  WHERE other_id_type = 'user_id'
),
ucd AS (
  SELECT ucm.user_main_id, c.contactid, c.seccodeid, c.createdate,
         cr.customerid, cr.last_transaction_date
  FROM ucm
  JOIN datalayer_prod.sysdba.contact_retail cr ON ucm.customerid = cr.customerid
  JOIN datalayer_prod.sysdba.contact c ON cr.contactid = c.contactid
  WHERE c.seccodeid IN ('F6UJ9A000002','F6UJ9A000004')
),
contested AS (
  SELECT user_main_id, seccodeid
  FROM ucd
  GROUP BY 1, 2
  HAVING count(DISTINCT customerid) > 1
),
sample AS (
  SELECT DISTINCT user_main_id FROM contested LIMIT 25
)
SELECT u.user_main_id, u.seccodeid, u.customerid,
       u.last_transaction_date, u.createdate,
       row_number() OVER (PARTITION BY u.user_main_id, u.seccodeid
         ORDER BY u.last_transaction_date DESC NULLS LAST,
                  u.createdate ASC NULLS LAST, u.customerid ASC) AS new_rank
FROM ucd u
JOIN contested ct ON ct.user_main_id = u.user_main_id AND ct.seccodeid = u.seccodeid
JOIN sample s ON s.user_main_id = u.user_main_id
ORDER BY u.user_main_id, u.seccodeid, new_rank;


-- ---------------------------------------------------------------------------
-- A4. Pre-existing hubs. Not a run A concern - run A only picks deterministically among
--     whatever is already there. This exists because run B can only ever make a hub
--     bigger, so the worst profiles today are the ones to look at before adding edges.
--
--     A1 reported a 02 partition holding 59 distinct customerids against an outlet max
--     of 3, so at least one hub predates all of this work.
--
--     distinct_lastnames is the tell. One surname across many customerids is a single
--     person with a messy record and is fine. Many surnames means the profile is already
--     over-stitched from some other edge source, and run B will compound it.
-- ---------------------------------------------------------------------------
WITH ucm AS (
  SELECT user_main_id, other_id AS customerid
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
  WHERE other_id_type = 'user_id'
),
ucd AS (
  SELECT ucm.user_main_id, c.contactid, c.seccodeid, cr.customerid,
         lower(trim(c.email))    AS email,
         upper(trim(c.lastname)) AS lastname
  FROM ucm
  JOIN datalayer_prod.sysdba.contact_retail cr ON ucm.customerid = cr.customerid
  JOIN datalayer_prod.sysdba.contact c ON cr.contactid = c.contactid
  WHERE c.seccodeid IN ('F6UJ9A000002','F6UJ9A000004')
)
SELECT user_main_id, seccodeid,
       count(DISTINCT customerid) AS customerids,
       count(DISTINCT contactid)  AS contactids,
       count(DISTINCT email)      AS distinct_emails,
       count(DISTINCT lastname)   AS distinct_lastnames,
       min(lastname)              AS sample_lastname
FROM ucd
GROUP BY 1, 2
HAVING count(DISTINCT customerid) >= 10
ORDER BY customerids DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- B1. Run B edge triage. Splits the new edges by what they would actually do to the
--     existing graph. The no-op bucket should be large: most of these contacts are
--     already stitched together through email or customerid.
--
--     cross_cluster_real_merges is the number that matters. That is the real work
--     run B does, and it should be far below the 25,000 to 28,000 total edge count.
-- ---------------------------------------------------------------------------
WITH cid AS (
  SELECT other_id AS contactid, user_main_id
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
  WHERE other_id_type = 'contact_id'
),
e AS (
  SELECT v.primary_id, v.secondary_id,
         ca.user_main_id AS umid_a, cb.user_main_id AS umid_b
  FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_merge_request v
  LEFT JOIN cid ca ON ca.contactid = v.primary_id
  LEFT JOIN cid cb ON cb.contactid = v.secondary_id
)
SELECT
  count(*) AS total_edges,
  count(CASE WHEN umid_a IS NOT NULL AND umid_b IS NOT NULL
              AND umid_a =  umid_b THEN 1 END) AS noop_already_same_cluster,
  count(CASE WHEN umid_a IS NOT NULL AND umid_b IS NOT NULL
              AND umid_a <> umid_b THEN 1 END) AS cross_cluster_real_merges,
  count(CASE WHEN umid_a IS NULL OR umid_b IS NULL THEN 1 END) AS side_not_in_stitcher
FROM e;


-- ---------------------------------------------------------------------------
-- B2. Run B fusion blast radius. Label propagation over the cluster-merge graph implied
--     by the cross-cluster edges, so you can see how many existing profiles collapse
--     into each post-run profile BEFORE running pb.
--
--     Three passes covers chains up to roughly 8 clusters deep, which the degree cap
--     should already make impossible. Read worst_case_fusion: a group swallowing more
--     than a handful of existing profiles is a hub that slipped a guard, and is worth
--     opening in B3 before you run anything.
-- ---------------------------------------------------------------------------
WITH cid AS (
  SELECT other_id AS contactid, user_main_id
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
  WHERE other_id_type = 'contact_id'
),
pairs AS (
  SELECT DISTINCT ca.user_main_id AS a, cb.user_main_id AS b
  FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_merge_request v
  JOIN cid ca ON ca.contactid = v.primary_id
  JOIN cid cb ON cb.contactid = v.secondary_id
  WHERE ca.user_main_id <> cb.user_main_id
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
  count(*)                                       AS post_run_profiles_affected,
  sum(clusters_fused)                            AS existing_profiles_absorbed,
  sum(clusters_fused) - count(*)                 AS net_profile_count_reduction,
  max(clusters_fused)                            AS worst_case_fusion,
  count(CASE WHEN clusters_fused =  2 THEN 1 END) AS simple_pairs,
  count(CASE WHEN clusters_fused >  5 THEN 1 END) AS groups_over_5
FROM groups;


-- ---------------------------------------------------------------------------
-- B3. Run B worst offenders. The 20 largest fusions with the id counts they would carry
--     into the merged profile. total_ids_after is directly comparable to section 6 of
--     validate_salesentity_merge_request.sql, so these rows are the before picture for
--     that regression check.
-- ---------------------------------------------------------------------------
WITH cid AS (
  SELECT other_id AS contactid, user_main_id
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
  WHERE other_id_type = 'contact_id'
),
pairs AS (
  SELECT DISTINCT ca.user_main_id AS a, cb.user_main_id AS b
  FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_merge_request v
  JOIN cid ca ON ca.contactid = v.primary_id
  JOIN cid cb ON cb.contactid = v.secondary_id
  WHERE ca.user_main_id <> cb.user_main_id
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
sizes AS (
  SELECT user_main_id, count(*) AS ids
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
  GROUP BY 1
)
SELECT l3.label               AS surviving_main_id,
       count(DISTINCT l3.node) AS clusters_fused,
       sum(s.ids)              AS total_ids_after,
       max(s.ids)              AS largest_input_cluster
FROM l3
JOIN sizes s ON s.user_main_id = l3.node
GROUP BY l3.label
ORDER BY clusters_fused DESC, total_ids_after DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- B5. Run B post-fusion coherence. A4's diagnostic, applied to the profiles run B would
--     CREATE rather than the ones that exist today.
--
--     B2 reported 56 groups fusing more than 5 clusters, topping out at 31. The degree
--     cap bounds contacts per customerid but cannot bound transitive chaining, so these
--     are the groups where one bad edge reaches furthest. This is the check for that.
--
--     Read distinct_lastnames and distinct_emails exactly as in A4. One surname across
--     a 31-cluster fusion is a person with a badly fragmented record, which is the whole
--     point of the exercise. A double-digit surname count means the chain has walked
--     across unrelated people and the guards need revisiting before pb runs.
-- ---------------------------------------------------------------------------
WITH cid AS (
  SELECT other_id AS contactid, user_main_id
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
  WHERE other_id_type = 'contact_id'
),
pairs AS (
  SELECT DISTINCT ca.user_main_id AS a, cb.user_main_id AS b
  FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_merge_request v
  JOIN cid ca ON ca.contactid = v.primary_id
  JOIN cid cb ON cb.contactid = v.secondary_id
  WHERE ca.user_main_id <> cb.user_main_id
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
  m.label           AS simulated_group_label,
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
LIMIT 56;


-- ---------------------------------------------------------------------------
-- B4. Run B predicted primary recoveries. Currently null-primary profiles that would be
--     fused with a cluster carrying a live 02 or 04 customerid, and so should come out
--     of run B holding a primary.
--
--     Expect this to land near the 10,394 figure in README.md, which is what section 0b
--     of the validation script checks after the fact. Materially lower means a guard is
--     eating recoveries; materially higher means the edges reach further than intended
--     and B2 is the place to look.
-- ---------------------------------------------------------------------------
WITH cid AS (
  SELECT other_id AS contactid, user_main_id
  FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
  WHERE other_id_type = 'contact_id'
),
pairs AS (
  SELECT DISTINCT ca.user_main_id AS a, cb.user_main_id AS b
  FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_merge_request v
  JOIN cid ca ON ca.contactid = v.primary_id
  JOIN cid cb ON cb.contactid = v.secondary_id
  WHERE ca.user_main_id <> cb.user_main_id
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
-- clusters that already carry a live 02/04 customerid, i.e. a usable primary source
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
  FROM l3
  JOIN has_primary_source h ON h.user_main_id = l3.node
),
null_primary_today AS (
  SELECT user_main_id
  FROM datalayer_prod.rudderstackoperationalprofiles.user_feature_view
  WHERE array_size(customer_ids_list) >= 1
    AND primary_customerid IS NULL
)
SELECT count(DISTINCT n.user_main_id) AS profiles_predicted_to_gain_a_primary
FROM null_primary_today n
JOIN l3 ON l3.node = n.user_main_id
JOIN good_groups g ON g.label = l3.label;
