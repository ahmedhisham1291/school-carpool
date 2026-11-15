# schools-sources (16 Nov 2026)

Branch `schools-sources` off main (f8bcd60). The coordinator gave the go
for the owner.

## Asks

1. Make the broad OpenStreetMap query finish: split it per governorate
   (27 parts, `[timeout:180]`, failover, merge and dedupe by OSM id;
   partial success keeps older per-governorate files, with their dates).
   Split the places download the same way.
2. Overture Maps Places as a third source (DuckDB, Egypt's box, categories
   and confidence, ar/en names, same importer rules and dedupe, 30-day cache,
   attribution in D24).
3. Step-12 summary: counts per source including Overture; OSM status per
   governorate.
4. Optional: the `ENFORCE_APP_CHECK.value() invoked during function
   deployment` flood in the deploy log.
5. Tests with fixtures; Python and Functions tests; `bash -n`.
6. (Added) `why_missing.py` and a step-12 names check; categories in one
   place, with a university switch that stays off (owner decision); drop rules
   checked against real-world names (international, British, American,
   language, STEM, Azhar institutes).
7. (Added) After load_schools, run `schools:admin-grams` when that npm
   script exists (admin-schools-search branch); merge main when it lands.

## What was done

- `overpass_split.py`: parts (governorate relation id from the
  governorates download, else the ISO3166-2 tag), per-part files with
  `fetched_at` and query id, reuse when recent, a second pass after 90 s,
  older file when a part still fails, a time budget, merge by OSM object and
  geometry type, status lines and a one-line summary.
- `fetch_osm_schools.py`: borders first (their relation ids are the search
  areas), the broad query per governorate, the amenity-only query for all
  of Egypt as a safety net, merged file `egypt_schools_osm.geojson` with
  per-governorate statuses. The whole download is reused only when every
  part was fresh (query id `split-1`, else `split-1-partial`).
- `fetch_osm_places.py`: one query per governorate for boundaries
  (`out geom`) and named places (`out center`) together.
- `fetch_overture_schools.py`: verified against the Overture docs and the
  schema/docs repositories (16 Nov 2026): release from the STAC catalog
  (`latest`; fallback 2026-10-21.0), `taxonomy.primary` / `alternates`
  (the old `categories` column was removed in Sept 2026), `confidence`,
  `operating_status`, `names.common` per language, `sources[].dataset`,
  `addresses[].country`. Points: bbox.xmin/ymin, so no spatial extension.
- `schools_import.py`: `data/schools/categories.json`; Overture
  classification; Overture ranked last as main entry; neighbours inside
  Egypt's box dropped (`beyond_border`); Al-Azhar institutes kept as
  schools; schools mapped as `language_school` / `prep_school` / `college`
  kept when the name reads like a school (not "centre", "institute",
  driving, music, ...); French "Collège de/Saint ..." names are schools;
  `office=educational_institution` with a school's name kept; "nursing"
  (تمريض) became a weak word (Egyptian secondary nursing schools);
  `nursery` added to the English kindergarten words; `amenity=childcare`
  kept as kindergarten (nurseries are in, owner decision).
- `why_missing.py`: runs the import in-process, loose name matching,
  verdicts kept / merged / dropped (reason) / not in any source; notes
  governorates with no OSM data.
- Functions: `appCheckOption` (plain `true` while `firebase deploy`
  loads the code, the parameter at runtime): stops the warning flood. The
  cause is in firebase-functions itself: `onCall` calls `.value()` on an
  Expression passed as `enforceAppCheck` when the function is defined
  (src/v2/providers/https.ts on firebase/firebase-functions main, read
  16 Nov 2026), and `.value()` warns when `FUNCTIONS_CONTROL_API=true`.
  Passing the param is already the supported way, so there is no other fix
  on our side. enforceAppCheck is not in the deploy manifest, so the
  runtime behaviour is unchanged. `SchoolKind` accepts `university`.
- Step 12: Overture (installs duckdb with pip when missing; exit 3 is a
  to-do), per-governorate summaries, per-source line, names check, admin
  search terms fill when the npm script exists.

## Not run here

- No network to Overpass, Overture's S3, the STAC catalog or PyPI from
  this workspace, and no duckdb package: the per-governorate download, the
  Overture query and the names check have not run on real data. The DuckDB
  SQL was checked by reading the docs, not executed.
- No Flutter SDK (no app change in this branch).
- Functions tests run with the stub node_modules; the real
  firebase-functions types were read from its source, not compiled against.
- shellcheck is not installed here; `bash -n` only.

## Estimate: schools from Overture for Egypt

No count could be run here. Reasoning: Overture Places has about 64 to 88
million places worldwide, about 60 million of them from Meta (Facebook
pages). Egypt is a heavy Facebook country and private schools,
kindergartens and nurseries almost all have a page, so the education
categories should be well covered; public schools much less (few pages).
Guess for Egypt's box: 15,000 to 40,000 rows in the school, kindergarten
and nursery categories at confidence 0.2+, about half to two thirds above
0.5. After the name rules (courses, centres, academies with a school
category are common on Facebook) and the merge with OSM/Wikidata, I expect
**roughly 5,000 to 15,000 new schools, kindergartens and nurseries** on
top of today's 896, with nurseries and private schools the largest groups
and English-only or transliterated names common (Arabic `names.common.ar`
is often missing). The first real run gives the numbers per category,
confidence band and dataset in `data/schools/overture/fetch_report.md`.

## Open questions

- Confidence threshold: 0.5 to start; tune after seeing the bands.
- Duplicates between Overture and OSM with different spellings (Latin vs
  Arabic) are not merged automatically; they go to "likely duplicates" when
  similar, otherwise both stay. The admin panel merge handles the rest.
