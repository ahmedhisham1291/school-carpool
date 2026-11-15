# Review: branch schools-osm (real schools list on staging, F4)

Reviewer: independent review agent, 15 Nov 2026.
Scope: `git diff main...HEAD` at 57eed68 (CI run 43727851654 green in
branch mode), with a focus on the first real run in the owner's Cloud Shell
against `school-carpool-staging`.

## Verdict: PASS (after three review fixes on this branch)

No open blockers. I fixed three small problems on the branch myself (below).
The other items are recommendations; none of them stops the first run.

## Fixed during review (separate commits)

1. **Search key check let read-only rights through**
   (`tool/algolia_keys.py`, `FORBIDDEN_FOR_SEARCH`). The app's one-hour
   secured keys inherit every right of the parent search key. Only write
   rights were refused, so a key with `logs` (other people's queries and IP
   addresses), `analytics`, `usage`, `browse` or `listIndexes` would have
   been accepted and passed on to phones. Fix: an allowlist (`search`
   only), a message that points to the search-only key in section 4 of
   the guide, a test for each extra right, and one line in
   docs/algolia-setup.md. Commit 6e1127a.
2. **`--replace-algolia` with no terminal turned search off**
   (`tool/cloud_setup.sh`, Algolia block in step 6). With the keys stored,
   `--replace-algolia` and no TTY, the script reached the "keys stored but
   ALGOLIA_APP_ID is empty" branch. That message was wrong, and
   `ALGOLIA_ON` stayed empty, so the deploy switched a working staging back
   to `SCHOOL_SEARCH_PROVIDER=fake`. Fix: with no TTY the stored keys are
   kept and a to-do line is printed. I checked both cases with a stubbed
   harness (`bash -n` is clean). Commit ac88058.
3. **Overpass `[timeout:900]` was over the main server's policy**
   (`tools/import_schools/fetch_osm_schools.py`, `QUERY_TIMEOUT_S`). The
   wiki "Overpass API" asks that "your requests are processed in no more
   than 10 minutes". A higher timeout also makes a busy server more likely
   to refuse the query before it runs. The value is now 540 s, and the
   test asserts that it stays at 600 s or less. Commit c0610dd.

## Checked and OK

**1. Secrets**
- Keys are typed with `read -r -s`. They pass only through bash builtins
  (`printf`) and stdin: to `tr`, to `algolia_keys.py` (which reads stdin)
  and to `gcloud secrets ... --data-file=-`. They never appear in argv.
- The sync passes the Write key to `npm` through the environment, which
  only the same user and root can read.
- There is no `set -x` or xtrace anywhere, and the docs never suggest
  `bash -x`.
- Keys are never printed, and the verdict lines contain no key (a test
  covers this). Keys are cleared after use, never written to the repo and
  not exported.
- The placeholder `unused` is replaced only if real keys are missing or
  `--replace-algolia` is given, and an identical write and search key is
  refused.
- `GET /1/keys/{key}` needs the `search` ACL, and a key may read its own
  rights (algolia.com/doc/rest-api/search/get-api-key). A Write key
  without `search` gives code 2, is accepted, and is checked by the sync,
  as documented.

**2. Overpass**
- The query syntax matches the Overpass QL wiki:
  - `out center;`: "tags" would drop coordinates, and "center" adds a
    centre to ways and relations.
  - `area["ISO3166-1"="EG"][admin_level=2]`, the same form the wiki uses
    for DK.
  - `(area.eg)`: ways and relations match when a member is inside the
    area.
  - The default maxsize (512 MB) is plenty.
- Endpoints: overpass-api.de, overpass.private.coffee (formerly kumi) and
  maps.mail.ru (VK Maps) are all in the wiki's current public list with no
  key needed.
- Polite use: a User-Agent is sent, servers are tried one at a time and
  never in parallel, and the script waits 30 s after 429 or 406.
- The script refuses an answer the server marks with a "remark" or one
  with fewer than 1,000 schools, writes files atomically, and does not
  download again within 7 days.
- Conversion is correct for nodes and for the centres of ways and
  relations.
- The ISO 3166-2:EG codes are complete (27).
- Border pieces are stitched in either direction. A gap skips only that
  governorate, and the nearest town is used there instead.
- Memory: a response of 30 to 60 MB in `json.loads` is a few hundred MB.
  That fits Cloud Shell, and the governorate geometry is the larger part.

**3. Importer and loader**
- The importer reads `osm/` first, skips `.part` files and does not read
  `sample/`.
- The latitude-band index for point-in-polygon is correct, because every
  edge that crosses a latitude is listed in that latitude's band.
- Loader reads are paged by document ID. Writes go in batches of 400, and
  each retry builds a new batch.
- Reruns are idempotent: schools are matched by ID and source keys.
- `--hide-sample` sets only `searchHidden`. It touches only active,
  sample-only, not-admin-edited schools, and documents stay, so children
  and carpools that point at them keep working. Admin and parent schools
  have no sample keys, so they are never picked.
- `syncAction` deletes the hidden schools from the index.
- The first load is about 20,000 to 30,000 writes, a little over the free
  20,000 a day (cents), as COSTS.md says.

**4. Algolia**
- `sync`:
  - applies the settings (`nameAr,nameEn`, `searchKeys`, city;
    `ignorePlurals` ar and en; `queryLanguages` and `indexLanguages` ar
    and en; typo tolerance);
  - sends records in batches of 1,000;
  - removes merged, awaiting-review and hidden schools by ID;
  - never clears the index (`clear` is only in `reindex`);
  - does not retry on 400 to 403;
  - keeps records small, far below the 10 KB record limit.
- The functions and the script use the same index name
  (`ALGOLIA_INDEX=schools_staging` in `.env.staging`, read by
  `defineString`).
- The app's key is still a secured key from `securedSearchKey`, with
  `restrictIndices`, `validUntil` (1 h) and `userToken`.

**5. App**
- If the server says "algolia" and sends no usable key, the app shows an
  error and does not fall back to the fake search. The server's
  `failed-precondition` also maps to "unavailable".
- Outside the emulators, the Firestore fallback refuses 200 or more schools
  and skips hidden ones.
- Prod still uses `UnavailableSchoolSearch`.
- There are tests for both cases. The Flutter tests were written by the
  author and run in CI; they were not run here.

**6. Shell**
- `run_step` runs `( set -e; "$@" )` with the ERR trap off. It is never
  used in an `if`, and in `[ ... ] || run_step` it is the final command of
  the list, so `set -e` still applies.
- `pipefail` is inherited by the `| tee` pipelines.
- Every failure in step 12 becomes a to-do line, and the script goes on.
- `bash -n` is clean. shellcheck is not installed in this workspace, so it
  was not run here; the author reports 0.10.0 clean.

**7. Docs**
- These figures match algolia.com/pricing and /pricing/grow-plan, read on
  15 Nov 2026:
  - Free plan: 10K search requests a month and 50K records.
  - Grow: 10K searches and 100K records included, then USD 0.50 per extra
    1K searches and USD 0.40 per extra 1K records.
- "20 indexes per application" was not found on those pages. It does not
  matter for us (two indexes).
- The guide never asks the owner to paste keys into a chat; it says the
  opposite in bold.

**Tests run here**
- `tools/import_schools`: 44 pass.
- `tool`: 14 pass, plus the new assertions.
- Functions: 765 pass, 0 fail (`node --test` on the build that uses the
  workspace stubs; `npm test` stops at the known type-stub `tsc` noise).

## Recommendations (not blocking)

1. `functions/scripts/load_schools.ts` (`commitWithRetry`): a commit that
   succeeded on the server but timed out in the client is retried, and
   `batch.create` then fails with ALREADY_EXISTS three more times before
   the run stops. A rerun fixes it, but it would be better not to retry
   gRPC code 6 (ALREADY_EXISTS) and to tell the owner to run again.
2. First load with Algolia on:
   - `syncSchoolToSearch` fires once per new school, about 25,000 times.
   - Each failure calls `reportError`, so if Algolia throttles, Sentry's
     free 5K errors a month could fill up in one run.
   - Consider sampling or deduplicating these reports, or loading with the
     trigger set to no-op (for example a `SCHOOLS_BULK_LOAD` flag) and
     relying on the step-12 sync.
3. Reads per rerun are N for the loader plus N for the sync, so 50,000 or
   more with 25,000 schools. That is slightly over the free 50,000 a day
   if the setup script runs twice in a day. COSTS.md counts the loader
   only. The cost is cents; correct the wording.
4. If the owner skips Algolia, step 12 still loads the real list, so the
   staging school picker says "unavailable". This is intended and printed
   as a to-do line. Loading only the sample until Algolia is on would keep
   staging usable.
5. `SCHOOL_INDEX_SETTINGS` has no `customRanking`. That is fine for now
   (no popularity signal). Later, ranking `kind` or verified schools
   higher could help.
6. If the Admin key is pasted as the Write key, `GET /1/keys` probably
   returns "does not exist" (code 2) and the key is accepted. It would then
   live in Functions with full rights. Consider refusing code 2 for the
   write key when the HTTP status is 404.
