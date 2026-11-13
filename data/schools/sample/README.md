# SAMPLE schools data (for development and tests only)

**This is not real data and not OpenStreetMap data.** It was written by
hand so that the import tool, its tests and the emulator demo run without
downloading anything.

- `sample_education_facilities_points.geojson` and
  `sample_education_facilities_polygons.geojson` copy the *shape* of the
  HDX OpenStreetMap export (same columns: `name`, `name:ar`, `name:en`,
  `amenity`, `building`, `osm_id`, `osm_type`, ...). About 40 well-known
  schools and a few invented kindergartens in Cairo, Giza and
  Alexandria. Coordinates are approximate (typed from memory, off by up
  to a few hundred metres) and the IDs are made up.
- `sample_ministry_list.csv` copies the shape of a ministry list with
  Arabic headers. Rows marked "(عينة)" / "(sample)" are invented.
- Some entries are there on purpose to exercise the cleaning: a school with
  no name, one called only "مدرسة", a university, a college, a driving
  school, a school in Beirut, duplicates with spelling differences (merged)
  and two pairs that the report lists as "likely duplicates".

Never load the sample into the prod project.

Run it:

```sh
python3 tools/import_schools/import_schools.py --input data/schools/sample
npm --prefix functions run schools:load:emulator
```
