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
   the report; `WIKIDATA_CONTACT` adds a contact to the User-Agent.
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

## Stopped: City → Area → District (two later requests)

Not started, by the rule "if the spec and a prompt disagree, stop and
ask":

- The spec (section 7 data model, F4/F5/F9/F32) and the code already have
  an **`areas` collection with a different meaning**: an area belongs to
  ONE school (id, schoolId, name, centre), managed by admins, and carpools
  (`areaId`), carpool search, chat area groups and the admin panel use it.
  The new requests define `areas` as qism/markaz/new city inside a
  governorate. Reusing the name would break carpools; renaming either
  changes the spec.
- The address request changes the home-address model (today
  `homes/{uid}` with a Places-picked point and a rounded public record)
  and adds a feature (next free ID would be F46).

Question for the owner (one answer unblocks both commits):

1. Keep the existing per-school `areas` and add the new hierarchy under
   new names: `placeAreas` (qism/markaz/new city) and `placeDistricts`,
   with schools getting `placeAreaId`/`districtId`; carpools keep their
   school areas. **Or**
2. Replace per-school areas by the new governorate areas (carpools,
   search and chat groups would use governorate areas/districts; a
   migration of staging's fake carpools; spec F4/F5/F9/F32 and section 7
   change).

Prepared facts for either answer: Egypt's governorates are
`admin_level=4` with `ISO3166-2=EG-*`; the admin level of qism/markaz and
of neighbourhoods in Egypt could not be verified here (taginfo and the
Egypt boundary pages are not reachable from this workspace), so the
fetch must measure coverage per level at run time rather than assume 5,
6 or 8.
