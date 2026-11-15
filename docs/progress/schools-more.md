# More real schools (branch schools-more)

Coordinator's request after the first staging run (16 Nov 2026): Overpass
returned 1,298 features, the import kept 888 (368 dropped for no name, 18
"only school"). The owner wants as many real schools as possible.

## Built

1. **Broad OpenStreetMap query** (`fetch_osm_schools.schools_query`): one
   union of `amenity=school|kindergarten`, `education=school|kindergarten`
   (key approved Feb 2025), named `building=school|kindergarten`, named
   `school=*` / `isced:level=*`, and non-street features whose `name`,
   `name:ar` or `name:en` reads like a school (starts with مدرس / مدارس /
   روض / حضان, optionally after "ال" or "مجمع"; or contains school /
   kindergarten case-insensitive; or the word KG). If it fails on every
   server, the old narrow query is used. The download records its query id,
   so the narrow download already on staging is replaced on the next run
   instead of being kept for 7 days.
2. **One keep/drop rule set** (`schools_import.classify_tags`): amenity
   rules unchanged; education values like amenity; any other amenity or a
   street/shop/place/historic/leisure/... tag → "named like a school but
   mapped as something else" (streets, bus stops, historic madrasas such as
   Sultan Hassan, pitches); names that say university/faculty/كلية/جامعة →
   university; driving/training/music/dance/courses/nursing (Arabic too)
   → courses; centre/academy/مركز/سنتر → courses only when the name does
   not itself read like a school ("مدرسة ... بمركز دسوق" stays; review
   fix); a named building=school is not dropped for a religion tag;
   "مبنى ب"-style building names → building part.
   "Language schools" stay (in Egypt they are ordinary schools). New drop
   reasons are in the report and the step-12 summary.
3. **Names from other tags** (`recover_name`): official_name, alt_name,
   short_name (and their :ar/:en), old_name, then a school-like operator,
   never the ministry/directorate. Counted in the summary. Unnamed schools
   without any of these are still dropped.
4. **Wikidata** (`fetch_wikidata_schools.py`): SPARQL for instances of
   school (Q3914) or kindergarten (Q126807) or subclasses, P17 = Egypt
   (Q79), with P625, not dissolved (P576), Arabic and English labels;
   country first with the optimizer off. Rows grouped per QID; classes
   that are not schools (university, college, music/driving school,
   madrasa, monument, ...; an Egyptian "language school" stays a school,
   review fix) mapped to tags the importer drops.
   Source "wikidata", ID `wikidata-Q123`. An OSM school tagged
   `wikidata=Q123` absorbs the item (labels fill missing names, key
   `wikidata:Q123` added; the item is reported as "already in
   OpenStreetMap"); other overlaps go through the usual merge. CC0 note in
   the report; `WIKIDATA_CONTACT` adds a contact to the User-Agent
   (step 12 defaults it to the admin email argument; owner decision).
5. **Overpass retries**: a 502/503/504 or network error moves to the next
   server at once (no 15-60 s waits on a busy server); a pause (30 s, then
   60 s) only after every server failed in a round; the boundaries
   download starts with the server that just answered.
6. **Step 12**: also fetches Wikidata (same 7-day reuse,
   `SKIP_SCHOOLS_FETCH=1` skips both); the summary shows read / dropped /
   kept / "schools with an entry from it" per source (osm, wikidata, owner
   CSV), drop reasons by count, names recovered and per governorate.
7. Docs: SETUP.md 14.1, data/schools/README.md, COSTS.md (Wikidata row),
   open-items D24 (Wikidata credit next to the OSM attribution).

## Sources checked (16 Nov 2026)

- OSM wiki Tag:amenity=school (building=school, school=*, isced:level),
  Proposal:Education tag (approved 2025-02, value list), Item Q22914
  (education=kindergarten = amenity=kindergarten, Wikidata Q126807),
  Overpass QL (`[!"key"]`, `,i`, unions).
- taginfo (taginfo.openstreetmap.org, taginfo.geofabrik.de for Egypt) and
  wikidata.org pages were **not reachable** from this workspace
  (allowlist), so Egypt-specific tag counts were not checked; the query
  is wide on purpose and the report shows what each rule kept or dropped.
- Wikidata: Q3914 = school (search result title), Q126807 = kindergarten
  (OSM wiki item), data CC0 and User-Agent policy (Wikidata:Data access),
  "turn off the optimiser and hand-order the query"
  (Wikidata:SPARQL query service/query optimization). The exact
  `hint:Query hint:optimizer "None"` syntax is the common WDQS form; it was
  not run here.

## Tests (honest status)

- Python: **run here, 64 pass** (`python3 -m unittest discover -s
  tools/import_schools`; new `test_more_sources.py`: query clauses,
  classify rules, name recovery, Wikidata SPARQL text / converter /
  importer / OSM link / retries / 403). Tool tests 14 pass. Sample import
  unchanged (42 kept). 26,000-school benchmark about 7 s.
- Functions: unaffected, **run here, 765 pass** (stubs; tsc noise 162 lines
  as before).
- `bash -n` and shellcheck: clean.
- Not run anywhere: the real broad Overpass query (its runtime on the
  public servers is unknown; the narrow query is the fallback) and the
  real Wikidata query (60 s limit).

## Honest estimate

The first run kept 888 schools. Egypt has tens of thousands of schools
(the ministry runs well over 50,000 public schools alone), but
OpenStreetMap maps only a small part of them, and the broad query can only
find what is mapped. Expected after this branch: roughly **1,500 to 4,000**
kept (named school buildings and school-named POIs without amenity tags
are the main gain, perhaps 500 to 3,000; names from other tags perhaps 20
to 50 of the 368 unnamed; Wikidata perhaps 100 to 400 items, many
already in OSM). This is a guess: taginfo could not be checked from here,
and the step-12 summary will give the real numbers. Getting near complete
coverage needs an official list (ministry or governorate CSV), which the
importer already accepts.

## City -> Area -> District and F46 (branch places-address, off schools-more)

The owner chose option 1 (keep both, 16 Nov 2026): the per-school `areas`
and carpools are unchanged; the new hierarchy is `placeAreas` and
`placeDistricts` (City = governorate). Commits on `places-address`:

1. **Data** (`tools/import_schools`): `fetch_osm_places.py` downloads every
   admin boundary of level 5 to 10 and every named
   place=suburb|quarter|neighbourhood in Egypt (shapes simplified to about
   30 m). `places_import.py` **measures** per level the share of schools
   inside its polygons (no level assumed): Area = finest of 5-7 covering
   at least 50 %, District = finest of 8-10 covering 30 %, falling back
   to coarser then finer levels where a level has no polygon, and named
   places as districts where no district boundary exists. Schools get
   `placeAreaId`, the area's names and `placeDistrictId`; owner-CSV entries
   without a pin get their area from the district column. Report and
   summary: coverage per level, schools per city, top areas, schools
   without an area.
2. **Server:** loader writes `placeAreas`, `placeDistricts`,
   `placeIndex/areas` (idempotent, admin edits kept, counts recomputed);
   rules (read when signed in, lists <= 500, no client writes; index and
   requests closed) with emulator tests; Algolia facet `placeAreaId`;
   "Other" and admin-saved schools get their area from the pin; audited
   admin functions (list, add, rename, deactivate, merge, move a school,
   district requests); requests deleted with the account.
3. **App and admin panel:** design-system `AppDropdownMenu` (M3
   DropdownMenu, filterable, one-line 48 dp items, pinned last item; in the
   gallery); school picker "By area" (City -> Area -> schools A-Z); search
   narrowed by area; admin Places section, Area filter and column on the
   schools list, "Move to area".
4. **F46** (next free ID after F45): the home address in three steps
   (dropdowns; street and building; pin on the map), "Search instead"
   prefill, server checks and geocoding, private address, area-only public
   fields. Spec section 4 and 9, DESIGN, DECISIONS, SETUP 14.6, COSTS.

Not done / notes: street suggestions (no street data yet, plain text);
carpool matching not changed (the public record carries the area and
district for a later filter); onboarding does not ask for an address
today, so the entry points are Profile, the Home tab and the nearby map;
CLAUDE.md still lists F1-F45 (owner edits that file).

Sources checked: OSM wiki Tag:place=quarter (suburb > quarter >
neighbourhood); Key:place, taginfo and the Egypt boundary pages were not
reachable here, hence the run-time measurement.

Tests here: Python 72 pass (incl. 8 new places tests and the sample run);
Functions 794 pass (incl. places and address tests); bash -n and
shellcheck clean. Written, not run: Flutter widget tests (dropdown
dependency, browse, address steps, admin Places), goldens (browse,
address steps AR/EN light/dark, 320 dp at 200 %, admin Places), rules
tests for places and addresses.
