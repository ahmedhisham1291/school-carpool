# Backups and the restore test

Spec section 7: "Back up the database daily and test a restore." Prompt 12.

## What is set up

| What | Where | Status |
| --- | --- | --- |
| Daily Firestore backups | prod: Firestore > Disaster recovery > Backups, daily, kept 7 days (SETUP.md section 5) | on in prod |
| Point-in-time recovery (PITR, any minute of the last 7 days) | `gcloud firestore databases update --database='(default)' --enable-pitr --project=<prod-id>` (SETUP.md 23.7) | **on in prod** (owner decision, 14 Nov 2026) |
| Cloud Storage | soft delete 7 days (`tool/setup_retention.sh`); photos are never overwritten | on |
| Chat (our own, Firestore and Storage) | Covered by the Firestore backups and PITR above; chat photos by the bucket's 7-day soft delete | on in prod |
| Secrets | Secret Manager keeps old versions | on |

## Restore test (run every 3 months and after every big data change)

Done in **staging** with fake data only (never copy production data). Takes
about 30 minutes. Write the result at the bottom.

1. **Prepare.** In staging, note three documents you will check later, for
   example `users/<uid>`, one `carpools/<id>` and one
   `carpools/<id>/schedule/<runId>`. Write their `updatedAt` values.
2. **Back up now.**
   ```sh
   gcloud firestore backups schedules list --database='(default)' --project=<staging-id>
   # if no schedule in staging, take an export instead:
   gcloud firestore export gs://<staging-id>-restore-test/$(date +%F) --project=<staging-id>
   ```
3. **Change data.** In the app (staging build) change the three things: the
   language, the carpool name, and confirm a run.
4. **Restore into a NEW database** (never over the live one):
   ```sh
   # from a scheduled backup:
   gcloud firestore databases restore --source-backup=projects/<staging-id>/locations/europe-west1/backups/<backup-id> \
     --destination-database=restore-test --project=<staging-id>
   # or from the export:
   gcloud firestore databases create --database=restore-test --location=europe-west1 --project=<staging-id>
   gcloud firestore import gs://<staging-id>-restore-test/<date> --database=restore-test --project=<staging-id>
   ```
   With PITR on, instead: `gcloud firestore databases clone --source-database='(default)'
   --snapshot-time=<RFC3339 time before step 3> --destination-database=restore-test`.
5. **Check.** In the console open database `restore-test`: the three
   documents show the values from step 1, not step 3. Count one
   collection in both databases (Firestore > Query > count) and compare.
6. **Clean up.** `gcloud firestore databases delete --database=restore-test --project=<staging-id>`
   and remove the export bucket folder.
7. **Write the result** below: date, who, backup used, time to restore,
   anything that did not match.

A real restore into production follows the same steps, then the app is
pointed at nothing new: copy the needed documents back from `restore-test`
with a reviewed script, never by switching the default database.

**After ANY restore into production (backup or PITR): re-apply deletions.**
A restore can bring back accounts deleted after the backup time. Before
copying anything back, list `closedAccounts` in the LIVE `(default)`
database and leave out every document of those uids. Then run, once:

```sh
GCLOUD_PROJECT=<prod-id> npm --prefix functions run deletions:reapply
```

It schedules every deletion step again for each closed account (purge
steps too for accounts already purged); the next `retentionDaily` runs them
and its report (`retentionRuns/<date>`) shows the counts. Also run
`npm --prefix functions run thumbs:backfill` if Storage was restored.
Add a line to the results table: "deletions re-applied: <n> accounts".

## Results

| Date | Who | Source | Minutes | Result |
| --- | --- | --- | --- | --- |
| | | | | |
