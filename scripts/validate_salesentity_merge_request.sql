-- scripts/validate_salesentity_merge_request.sql
--
-- Land the two changes in separate pb runs so each delta is attributable:
--   run A  deterministic ORDER BY in contact_with_retail, no new edges
--   run B  inputs/salesentity_merge_request added as an edge_source
-- Landing both at once makes it impossible to tell whether a changed primary came from
-- the tie-break or from a new merge.
--
-- Section 0 before each run. Sections 1 to 4 after deploying the view, before run B.
-- Sections 5 and 6 after each run.
--
-- View definition: RudderstackDatabricksViews/views/salesentity_merge_request.sql

-- 0. Snapshot. Run this immediately BEFORE each pb run, then run 0b immediately after.
--    Overwriting it each time is intentional: each diff then covers exactly one run.
--
--    The snapshot deliberately does NOT live in the prod profiles schema. It is a
--    throwaway diff table, not a model output, and individual accounts do not hold
--    CREATE TABLE on datalayer_prod.rudderstackoperationalprofiles anyway - only the
--    service principal does. datalayer_test is writable by individuals. Cross-catalog
--    joins work inside the metastore, so 0b still reads prod and joins this.
--
--    Swap the target for a personal sandbox schema if you have one; nothing else in
--    this file or the project reads this table.
CREATE OR REPLACE TABLE datalayer_test.rudderstackoperationalprofiles.primary_customerid_snapshot AS
SELECT user_main_id, primary_customerid, mainline_customerid, outlet_customerid
FROM datalayer_prod.rudderstackoperationalprofiles.user_feature_view;

-- 0b. After a pb run, what actually moved.
--
--     FULL OUTER, not INNER. Run B merges roughly 20,825 existing profiles down into
--     9,716, so about 11,109 user_main_ids disappear from user_feature_view entirely.
--     An inner join drops those silently, which hides the single biggest effect of the
--     run. profiles_merged_away is therefore a headline number, not an error case:
--     it should land near the net_profile_count_reduction that dry-run section B2
--     predicted.
--
--     Run A: expect gained = 0, lost = 0, merged_away and new_profiles small and organic,
--            primary_changed near 2,826 (only partitions with more than one competing
--            customerid can move at all).
--     Run B: expect lost = 0 and merged_away near 11,109.
--
--     lost_a_primary counts only profiles that still exist and came out with no primary.
--     That must stay 0 in both runs - a profile that merged away did not lose a primary,
--     it stopped existing, and is counted in merged_away instead.
--
--     DO NOT read gained_a_primary as the recovery count on run B. It can only see
--     profiles whose user_main_id SURVIVES the merge. Most recoveries go the other way:
--     the null-primary profile is absorbed into a cluster that already held a primary,
--     its main_id disappears, and it lands in merged_away. On the real run B that split
--     was 2,080 survivors against a true recovery of 10,418. Section 5 is the number
--     that answers "how many profiles were recovered"; this column is a subset of it.
--
--     ACTUALS, run A (seq 25) then run B (seq 26), 2026-09-21:
--       run A: merged_away 47, new 137, gained 0, lost 0, primary_changed 2,826
--       run B: merged_away 11,125, new 267, gained 2,080, lost 0, primary_changed 266
SELECT
  count(*)                                          AS rows_compared,
  count(CASE WHEN v.user_main_id IS NULL THEN 1 END) AS profiles_merged_away,
  count(CASE WHEN s.user_main_id IS NULL THEN 1 END) AS new_profiles,
  count(CASE WHEN s.user_main_id IS NOT NULL AND v.user_main_id IS NOT NULL
              AND s.primary_customerid IS NULL
              AND v.primary_customerid IS NOT NULL THEN 1 END) AS gained_a_primary,
  count(CASE WHEN s.user_main_id IS NOT NULL AND v.user_main_id IS NOT NULL
              AND s.primary_customerid IS NOT NULL
              AND v.primary_customerid IS NULL THEN 1 END) AS lost_a_primary,
  count(CASE WHEN s.primary_customerid IS NOT NULL
              AND v.primary_customerid IS NOT NULL
              AND s.primary_customerid <> v.primary_customerid THEN 1 END) AS primary_changed
FROM datalayer_prod.rudderstackoperationalprofiles.user_feature_view v
FULL OUTER JOIN datalayer_test.rudderstackoperationalprofiles.primary_customerid_snapshot s
  ON s.user_main_id = v.user_main_id;

-- 1. Shape of the edge set. Expect roughly 25,000 to 28,000 edges.
--    A number far above that means a guard is not firing.
SELECT
  count(*)                                                              AS edges,
  count(DISTINCT via_customerid)                                        AS customerids,
  count(DISTINCT primary_id)                                            AS distinct_primaries,
  count(DISTINCT secondary_id)                                          AS distinct_secondaries,
  count(CASE WHEN seccode_a = seccode_b THEN 1 END)                     AS same_seccode_dupes,
  count(CASE WHEN seccode_a IS NULL OR seccode_b IS NULL THEN 1 END)    AS orphan_side_edges,
  count(CASE WHEN corroborated THEN 1 END)                              AS corroborated_edges
FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_merge_request;

-- 2. Seccode cross-tab. Every row must have a 02 or 04 on at least one side;
--    the other side is 02, 04, 17, or NULL (contact_retail orphan).
SELECT coalesce(seccode_a, '<no contact row>') AS seccode_a,
       coalesce(seccode_b, '<no contact row>') AS seccode_b,
       count(*) AS edges
FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_merge_request
GROUP BY 1, 2
ORDER BY edges DESC;

-- 3. Transitive chaining. Per-customerid degree capping does NOT cover this: contact A
--    can share one customerid with B and a different one with C, and the stitcher unions
--    all three. A long tail is fine. A contactid with 50+ edges is a hub worth reading
--    before running pb.
SELECT contactid, count(*) AS edge_count
FROM (
  SELECT primary_id   AS contactid FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_merge_request
  UNION ALL
  SELECT secondary_id AS contactid FROM datalayer_prod.rudderstackoperationalprofiles.salesentity_merge_request
)
GROUP BY 1
ORDER BY 2 DESC
LIMIT 20;

-- 4. What the seccode-18 exclusion costs. These are customerids where salesentity points
--    at a live 02/04 survivor but contact_retail points at a retired-line contact, i.e.
--    an 18 record that was merged into a real mainline or outlet account. The view
--    discards them per the "18 is completely discarded" rule. If this number is large,
--    revisit that rule: the person behind the 18 record may be a live customer whose
--    profile is being split in two.
WITH pairs AS (
  SELECT DISTINCT CAST(customerid AS STRING) AS customerid, contactid
    FROM datalayer_prod.sysdba.salesentity
   WHERE customerid IS NOT NULL AND contactid IS NOT NULL
  UNION
  SELECT DISTINCT CAST(customerid AS STRING) AS customerid, contactid
    FROM datalayer_prod.sysdba.contact_retail
   WHERE customerid IS NOT NULL AND contactid IS NOT NULL
),
safe AS (
  SELECT customerid FROM pairs
  WHERE customerid <> '0'
  GROUP BY customerid
  HAVING count(DISTINCT contactid) BETWEEN 2 AND 6
)
SELECT count(*) AS edges_blocked_by_the_18_rule
FROM safe s
JOIN pairs a ON a.customerid = s.customerid
JOIN pairs b ON b.customerid = s.customerid AND b.contactid > a.contactid
LEFT JOIN datalayer_prod.sysdba.contact ca ON ca.contactid = a.contactid
LEFT JOIN datalayer_prod.sysdba.contact cb ON cb.contactid = b.contactid
WHERE (ca.seccodeid IN ('F6UJ9A000002','F6UJ9A000004')
    OR cb.seccodeid IN ('F6UJ9A000002','F6UJ9A000004'))
  AND (ca.seccodeid = 'F6UJ9A000018' OR cb.seccodeid = 'F6UJ9A000018');

-- 5. AFTER pb run: the defect buckets should clear.
--    Expect roughly 10,394 fewer null-primary profiles. The 18 / SYST / 10 population
--    should be unchanged. Full baseline is in diagnose_null_primary_customerid.sql.
--
--    BASELINE, measured 2026-09-21 immediately before run A: 125,299.
--    Most of that is correct by design - only the ~10,400 defect bucket is recoverable,
--    the rest is seccode 18 / SYST / 10 and stays null.
--
--    ACTUALS: after run A, 125,299 unchanged, as expected - run A adds no edges and so
--    cannot recover anything. After run B, 114,881, a drop of 10,418 against the 10,419
--    that dry-run section B4 predicted.
--
--    This section, not 0b's gained_a_primary, is the recovery count. See the note on 0b.
--    It is not derivable from primary_customerid_snapshot, which does not carry
--    customer_ids_list, so it has to be captured before each run or not at all.
SELECT count(*) AS null_primary_profiles
FROM datalayer_prod.rudderstackoperationalprofiles.user_feature_view
WHERE array_size(customer_ids_list) >= 1
  AND primary_customerid IS NULL;

-- 6. AFTER pb run: cluster-size regression check. Compare against the same query taken
--    before the change. If the largest cluster grows by more than a few ids, an edge is
--    chaining and the guards need tightening.
--
--    BASELINE, seq 25, immediately after run A (run A adds no edges, so this is equally
--    the pre-run-B baseline). Top 10 by id count:
--      703, 373, 153, 145, 142, 137, 123, 118, 118, 110
--    The 123 and 110 are the MONETTI and MYDLAND profiles from dry-run section A4, where
--    they showed 59 and 54 mainline customerids with a matching contactid each. They are
--    single people with badly duplicated source records, not over-stitched profiles.
--    The 703 and 373 never appeared in A4 because A4 only counts 02/04 customerids;
--    those two are dominated by other id types. Dry-run B3 put the largest post-fusion
--    group at 93 ids total, so run B should not move the head of this list at all.
--
--    ACTUALS after run B (seq 26). The head did not move:
--      703, 373, 153, 145, 145, 137, 129, 118, 118, 110, 101, 95, 93, 87, 84, 82, ...
--    Only three entries changed. rid03bc9729... enters at 93, which is the 31-cluster
--    MACNEIL fusion landing at exactly the id count B3 predicted. MONETTI went 123 to 129
--    and rid1b3b2e30... went 142 to 145, both single people absorbing fragments. No
--    cluster chained, and the two largest profiles are untouched.
SELECT user_main_id, count(*) AS ids
FROM datalayer_prod.rudderstackoperationalprofiles.user_id_stitcher
GROUP BY 1
ORDER BY 2 DESC
LIMIT 20;
