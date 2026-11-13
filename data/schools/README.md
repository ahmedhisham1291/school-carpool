# data/schools

Put the files for the schools import (F4) here. They are not committed.

- The HDX export "Egypt: Education Facilities (OpenStreetMap Export)":
  the GeoJSON points and polygons (zipped or not) or the CSV.
- Any ministry, governorate or school-group list as CSV (UTF-8).
- Optional: governorate boundaries (GeoJSON, admin level 1) in
  `boundaries/`, for an exact governorate per school.

Then run `python3 tools/import_schools/import_schools.py`. SETUP.md,
section "Schools list", has the download links, the accepted CSV headers
and the load steps.

`sample/` is a small hand-written dataset for development and tests. See
its README.
