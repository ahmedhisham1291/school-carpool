# Real schools list on staging (branch schools-osm)

Owner decision (15 Nov 2026 16:44): load every Egyptian school and
kindergarten we can get from open data into staging; staging uses Algolia
for school search (paid plan accepted if needed). The coordinator said
"go" on the owner's behalf.

## Plan

1. `tools/import_schools/fetch_osm_schools.py` (stdlib only, run in Cloud
   Shell): Overpass query for `amenity=school|kindergarten` (nodes, ways,
   relations) inside Egypt (`area["ISO3166-1"="EG"][admin_level=2]`,
   `out center tags;`), public endpoints tried in turn with retries and
   backoff, converted to the GeoJSON the importer reads (OSM tags +
   `osm_id`/`osm_type` like the HDX export) in `data/schools/osm/`, with a
   fetch report (date, endpoint, counts, ODbL attribution). Governorate
   boundaries (`admin_level=4`, `ISO3166-2=EG-*`, `out geom;`) stitched
   into MultiPolygons in `data/schools/boundaries/`; skipped (with the
   reason) if the answer is incomplete. Unit tests with fixtures, no
   network.
2. Importer: read `data/schools/osm/`; boundaries matched by ISO 3166-2
   code first; point-in-polygon indexed by latitude band (a detailed
   governorate border has tens of thousands of points); benchmark with
   ~25,000 synthetic schools (duplicate search is already grid based).
3. `load_schools.ts`: batched with progress and retries, idempotent (already
   matched by ID and source keys); new `--hide-sample <sample schools.json>`
   marks the hand-written sample schools `searchHidden: true` (kept as
   documents, so anything that points at them still works, but out of
   search) once real data is loaded. Admin-edited and parent schools are
   never touched.
4. Algolia on staging from `tool/cloud_setup.sh`: asks for the App ID, the
   Write API key and the Search-only API key (keys hidden), checks them
   against Algolia, stores the keys in Secret Manager (only over the
   placeholder `unused` unless `--replace-algolia`), writes
   `SCHOOL_SEARCH_PROVIDER=algolia`, `ALGOLIA_APP_ID`,
   `ALGOLIA_INDEX=schools_staging` into `functions/.env.staging` before the
   deploy, and prints the non-secret lines to commit. New `sync` command
   in `algolia_schools.ts` (settings + every active school in batches of
   1,000 + removal of hidden/inactive ones; no clear, works with the Write
   key).
5. Step 12 "Schools": fetch (skipped if `SKIP_SCHOOLS_FETCH=1` or the
   download is under 7 days old), import (with owner CSVs), load, Algolia
   sync; counts printed; failures become to-do lines.
6. App: the Firestore fallback outside the emulators refuses a partial list
   (200 or more schools read) with a clear "search unavailable" error, and
   "algolia" without a usable key is an error, not a silent fallback.
   Hidden sample schools are skipped by the fallback.
7. Docs: docs/algolia-setup.md (owner guide), SETUP.md 14, COSTS.md,
   open-items.md, DECISIONS.md, data/schools/README.md, .gitignore.

## Open questions (none blocking)

- Algolia's dashboard Write API key is not limited to one index. SETUP
  14.4 suggested index-limited keys made by hand; the guide offers that as
  an optional hardening step.

## What was built

- `tools/import_schools/fetch_osm_schools.py` + `test_fetch_osm_schools.py`:
  Overpass download (schools `out center;`, governorates `out geom;`
  stitched into MultiPolygons), three public endpoints tried in turn
  (2 attempts each, 30 s pause after 429/406 as the main server's policy
  asks), clear error if all fail, refuses an answer the server marks as
  stopped ("remark") or with under 1,000 schools, keeps the earlier file
  then. Writes atomically; `--max-age-days 7` reuses a recent download.
- Importer: reads `data/schools/osm/` first; ISO 3166-2 match for borders;
  point-in-polygon by latitude bands. Benchmark here: 26,000 synthetic
  schools (45 % packed around Cairo) with 27 borders of 20,000 points each:
  about 9 s; without borders about 10 s (duplicate search was already grid
  based, not O(n^2)).
- `load_schools.ts`: paged reads, batches of 400 with retries and progress,
  `--hide-sample` (sample schools get `searchHidden`, stay as documents).
  `catalog.ts`: `planSampleHiding`, `planIndexSync`, hidden schools are not
  search records. `algolia_schools.ts`: `sync` (no clear, works with the
  Write API key), `reindex` kept for the Admin key.
- `tool/cloud_setup.sh`: Algolia keys in step 6 (`tool/algolia_keys.py`
  checks them; the search key must not be able to write), env lines before
  the deploy, `--replace-algolia`; step 12 "Schools" (fetch, import with
  owner CSVs, load, sync, counts; failures become to-do lines).
- App: outside the emulators the Firestore fallback refuses 200+ schools
  ("search unavailable" instead of a partial list), skips hidden sample
  schools; "algolia" without a usable key is an error.
- Docs: docs/algolia-setup.md, SETUP.md 14, COSTS.md, open-items.md (A9,
  D23 to D25), owner-cloud-shell.md, DECISIONS.md, data/schools README.

## Sources checked (15 Nov 2026)

- Public Overpass endpoints and the main server's usage policy:
  OpenStreetMap wiki "Overpass API" (wiki.openstreetmap.org/wiki/Overpass_API).
  overpass.kumi.systems is no longer listed there, so it is not used.
- Query syntax (`[out:json][timeout:...]`, `nwr`, regex filters, `out`
  verbosity and `center`/`geom`): wiki "Overpass API/Overpass QL"; area by
  tags and `(area.name)`: Overpass API User's Manual
  (dev.overpass-api.de/overpass-doc/en/full_data/area.html). The brief's
  `out center tags;` would drop node coordinates, so `out center;` is used.
- ISO 3166-2:EG codes: statoids.com/ueg.html.
- Algolia Free plan (10,000 searches/month, 50,000 records) and Grow
  prices: algolia.com/pricing, algolia.com/pricing/grow-plan,
  support.algolia.com "How am I billed on the Grow plan?"; key rights:
  algolia.com/doc/rest-api/search/get-api-key, support article on Admin vs
  Write API key; dashboard path: support article "How do I find my Admin
  API key?".

## Tests (honest status)

- Python importer + fetch: **run here, 44 pass** (`python3 -m unittest
  discover -s tools/import_schools`); tool tests **run here, 14 pass**
  (incl. 5 new for `algolia_keys.py`); sample import unchanged (42 kept).
- Functions: **run here, 765 pass, 0 fail** (`node --test` with the
  workspace's type stubs; `tsc` shows only the known stub noise, 162
  lines vs 165 at the branch start, none new).
- `bash -n` and **shellcheck 0.10.0: clean** on tool/cloud_setup.sh. The
  Algolia prompt block and step 12 were also run here with stubbed
  gcloud/npm (5 Algolia scenarios, one full step 12 with 26,000 schools).
- Flutter: **written, not run here** (no SDK): 2 new tests in
  `test/schools/schools_logic_test.dart`.
- Not run anywhere yet: the real Overpass download, the real Algolia calls,
  the load into staging Firestore (no internet here; first run is the
  owner's Cloud Shell run).

## Open questions / notes

- The first load triggers `syncSchoolToSearch` once per new school (with
  `maxInstances` 10 they queue for some minutes); the step-12 sync sends
  the same records anyway, so the index is complete either way.
- The dashboard's Write API key is not limited to one index; index-limited
  keys are an optional step in docs/algolia-setup.md (recommended before
  prod).
- After the owner's run, the three non-secret lines the script prints
  (`SCHOOL_SEARCH_PROVIDER=algolia`, `ALGOLIA_APP_ID=...`,
  `ALGOLIA_INDEX=schools_staging`) must be committed to
  functions/.env.staging; until then a rerun asks for the Application ID
  again (keys are kept).
