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

`places/` (City -> Area -> District, F4 and F46): ten hand-written square
"areas" (Maadi, Nasr City, Heliopolis, Zamalek, New Cairo, Dokki, Sheikh
Zayed, 6th of October, Smouha, Downtown Cairo; admin_level 7), four
districts (admin_level 9: Fifth Settlement, First Settlement, District 14,
6th District) and four named places, in the shape of
`tools/import_schools/fetch_osm_places.py`'s output. **Not real borders and
not OpenStreetMap data**: rough boxes for development and tests only.
