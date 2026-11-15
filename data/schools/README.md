# data/schools

Put the files for the schools import (F4) here. They are not committed
(`.gitignore` here keeps everything but the READMEs and `sample/`).

- `osm/`: the OpenStreetMap download made by
  `python3 tools/import_schools/fetch_osm_schools.py` (staging's
  `tool/cloud_setup.sh` step 12 runs it): every school and kindergarten in
  Egypt through the Overpass API (a broad query: tags and school-like names;
  the importer decides what counts), plus `fetch_report.md` (date, server,
  counts). Data (c) OpenStreetMap contributors, ODbL 1.0
  (<https://www.openstreetmap.org/copyright>).
- `wikidata/`: Wikidata's schools in Egypt from
  `python3 tools/import_schools/fetch_wikidata_schools.py` (step 12 runs
  it too), plus `fetch_report.md`. Wikidata data is CC0.
- `boundaries/`: governorate borders for an exact governorate per school:
  the OpenStreetMap ones from the same script
  (`egypt_governorates_osm.geojson`) or HDX admin level 1 GeoJSON.
- Instead of `osm/`, the HDX export "Egypt: Education Facilities
  (OpenStreetMap Export)": the GeoJSON points and polygons (zipped or not)
  or the CSV. Not needed with the download above (same data, same IDs).
- Any ministry, governorate or school-group list as CSV (UTF-8), here at
  the top level. cloud_setup.sh imports them together with the download.

Then run `python3 tools/import_schools/import_schools.py`. SETUP.md,
section "Schools list", has the download links, the accepted CSV headers
and the load steps.

`sample/` is a small hand-written dataset for development and tests. See
its README. Once a real list is loaded on staging, the sample schools are
taken out of search there (kept as documents).
