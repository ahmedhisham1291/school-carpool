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
