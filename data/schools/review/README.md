# Review decisions (data/schools/review)

`decisions.csv` is applied by `tools/import_schools/import_schools.py` on
every import, AFTER all automatic rules (keep/drop, names, duplicates). It is
committed: decisions survive every new download.

Columns (UTF-8, header required): `source,source_id,action,value,reason`

- `source`, `source_id`: the importer's stable source key, as in
  `build/schools/review_input.csv`:
  - `osm`: `n123` / `w123` / `r123` (`node/123`, `way/123`, `relation/123` also accepted)
  - `wikidata`: `Q123`
  - `overture`: the Overture place id
  - `list_<file>`: the row id of an owner CSV list
- `action`, `value`:
  - `drop`: take the entry out (reason in the report: "Dropped by the review")
  - `keep`: keep an entry the rules drop (no name-rule, generic-name or
    script check; a missing position is still a drop)
  - `rename_ar` / `rename_en`: the value is the new Arabic / English name
  - `set_kind`: `school` or `kindergarten` (final, also after merges)
  - `merge_into`: the value is the other entry's key (`osm:n123`,
    `overture:<id>`); that entry's school stays, this one joins it
- `reason`: free text for people (not used by the import).

Rows that cannot be read and keys not found in the current run are listed in
the import summary ("Review decisions applied: ..., not matched in this run: N");
neither stops the import.

`build/schools/review_input.csv` (every run, one row per entry read, kept or
dropped) is the input for the review: source, source_id, final Arabic and
English names, raw names as read, kind, Overture category and confidence,
governorate, position rounded to 3 decimals, drop reason, and the id of the
school it ended in (group_id).
