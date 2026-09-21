# scripts

Supporting SQL for this profiles project. Nothing here is run by `pb`; these are
diagnostics and the deploy/validation steps for the warehouse objects the project
reads as inputs.

## Files

| File | Purpose |
|---|---|
| `diagnose_null_primary_customerid.sql` | Splits the null-`primary_customerid` population into buckets, with the 2026-09-02 baseline recorded inline |
| `dryrun_spot_checks.sql` | Blast-radius checks for both runs, all runnable before either one |
| `validate_salesentity_merge_request.sql` | Pre- and post-`pb run` checks for the salesentity edge set |

## salesentity_merge_request

### Why it exists

`primary_customerid` is a window `MAX` over the whole `user_main_id` partition in
`models/contact_with_retail`, so it is constant per profile. A null primary means the
profile has no seccode 02 (mainline) and no seccode 04 (outlet) contact reachable
through the `user_id` path, which also empties `contact_primary_filtered`,
`contact_retail_primary_filtered` and `address_primary_filtered`. Those profiles never
propagate to the Customer model.

Most of the null-primary population is correct: seccode 18 is a retired business line,
and SYST / 10 / advisor-private codes are non-customer records. All are discarded by
design. About 10,400 profiles were not correct, and all three of those defect buckets
had the same cause.

`contact_with_retail` reaches `contact` by the direct route
`contact_retail.customerid -> contact_retail.contactid -> contact.contactid`. The 11
sales and affinity models in `sales_models.yaml` and `sql_models.yaml` instead route
through `sysdba.salesentity`, which can land on a *different* contact. Before
`sysdba.merge_request` existed, that difference was the merge: the surviving contact
kept the dead contact's customerid in `salesentity`, while `contact_retail` still
pointed that customerid at the dead contact.

Rather than patch the join in `contact_with_retail` and let it drift from the 11 models
that already use the bridge, the disagreement is harvested into a `merge_request`-shaped
view of contactid pairs and fed to the id_stitcher. The repair then happens once, at the
stitching layer, and every downstream model inherits it.

### Where it lives

The view definition is in the sibling repo, alongside the other Databricks views:

```
RudderstackDatabricksViews/views/salesentity_merge_request.sql
```

It is deployed to the `rudderstackoperationalprofiles` schema, the same schema `pb`
writes this project's outputs to. The marketing model (`RudderstackProfiles`) has its own
schema and does not read this view; both models continue to run independently. The
catalog is left unqualified in the view definition so `DATABRICKS_CATALOG` selects
`datalayer_prod` or `datalayer_test` at deploy time.

`pb` does not materialize inputs, so nothing it creates collides with this view name.

It is declared as `inputs/salesentity_merge_request` in `models/inputs.yaml` and wired as
an `edge_source` in `models/profiles.yaml`. Both of those land in the run B commit, not
the run A one, so that run A carries no new edges. See Sequencing below.

### Guards

1. **Degree cap, 2 to 6.** Drops house and placeholder customerids. As of 2026-09 eleven
   customerids exceeded it: customerid `0` with 696 contacts, then a contiguous
   `3007xxxxx` block running 139 down to 12. Left in, those alone would emit about
   283,000 pairs and fuse roughly 1,495 unrelated people into 11 profiles. A cap is used
   rather than a hardcoded blocklist so it stays correct as the data grows. The observed
   distribution is tight up to 6 and then jumps straight to 12, so the cut is clean.
2. **One side must be a live 02 or 04 survivor.** Merging two deactivated records to each
   other accomplishes nothing.
3. **Both sides must be 02, 04, 17, or have no `sysdba.contact` row.** This is the same
   allowlist `contact_with_retail` uses, so these edges can only introduce contacts that
   model already accepts. A missing contact row is the `contact_retail` orphan case and
   is allowed through deliberately: `contact_retail.contactid` is a valid stitching id
   whether or not the contact row survived, and blocking it would lose the largest of the
   three defect buckets.

**If `contact_with_retail`'s seccode allowlist changes, change the view's to match.**

The `corroborated` column (matching surname or matching email) is informational only and
is deliberately not filtered on. These are human-driven CRM merges, so a differing name
is still a real merge. A 50-row manual review found 49 unambiguous same-person pairs and
one plausible household case.

### Sequencing

For the smallest attributable delta, land the two changes in separate `pb` runs:

1. **Run A** - the deterministic `ORDER BY` in `contact_with_retail`, no new edges. Only
   profiles with more than one customerid competing in a 02 or 04 partition can move.
   Nothing gains or loses a primary.
2. **Run B** - `inputs/salesentity_merge_request` added as an `edge_source`. About 10,400
   profiles gain a primary; none should lose one.

Landed together, a changed primary cannot be attributed to either cause. Section 0 of
`validate_salesentity_merge_request.sql` snapshots and diffs around each run.

Before committing to either run, `dryrun_spot_checks.sql` predicts both deltas from the
live stitcher without running `pb`. Run A's effect is exact there, since it does not
touch the id graph. Run B's is a lower bound: the simulation only walks the new
contactid edges, so real fusions can come out slightly larger, never smaller.

### Permissions

Creating the view needs `USE CATALOG` on the catalog plus `USE SCHEMA` and `CREATE TABLE`
on `<catalog>.rudderstackoperationalprofiles`. Unity Catalog counts a view as a table for
the CREATE privilege, so a missing grant surfaces as:

```
PERMISSION_DENIED: User does not have CREATE TABLE on Schema
'datalayer_prod.rudderstackoperationalprofiles'.
```

Deploy with the service principal in `RudderstackDatabricksViews/.env`, not from the SQL
editor as an individual user. Individual accounts have `CREATE TABLE` on the test schema
but not the prod one.

Creating the view as the same principal `pb` connects as also keeps the Unity Catalog
ownership chain intact. The view owner needs `SELECT` on `sysdba.salesentity`,
`sysdba.contact_retail` and `sysdba.contact`; the reader then needs only `SELECT` on the
view. If the view is owned by someone other than `pb`, `pb run` fails at read time with a
permission error rather than a data error. Check with:

```sql
SHOW GRANTS ON VIEW <catalog>.rudderstackoperationalprofiles.salesentity_merge_request;
```

### Deploy

From the views repo, with `DATABRICKS_CATALOG` set to the target environment and
`DATABRICKS_SCHEMA` to `rudderstackoperationalprofiles`:

```
cd ../RudderstackDatabricksViews
VIEW_DEFINITION_FILE=./views/salesentity_merge_request.sql node index.js
```

Deploy and validate in `datalayer_test` first, then repeat against `datalayer_prod`.

Then run sections 1 to 4 of `validate_salesentity_merge_request.sql`, run `pb run`, then
run sections 5 and 6. The validation script is written against `datalayer_prod`; change
the catalog when checking test.

### Rollback

Delete the `- from: inputs/salesentity_merge_request` line from
`models/profiles.yaml` and re-run `pb`. The edges are purely additive, so they can only
merge profiles, never split them.
