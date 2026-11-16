# Review: schools-fixes (F4 clean schools list, F46 place menus)

Validator review of branch `schools-fixes` (builder head cf44a3c, 8 commits
on main 1984c7d). Owner decisions checked against: no manual duplicate
review (auto-merge, the list must be clean), names only in Arabic or Latin
letters, schools + KG + nurseries only.

**Verdict: PASS** after the validator fixes B1-B6 below (see the end for
the CI run).

## Checked

1. **Dedupe** (dedupe.py, schools_import.find_duplicates):
   - Stages and boys/girls never merge; a stage on one side only is kept
     apart; different people's names (`~` tokens, no one-letter slip) are
     kept apart; chain branches with a place word stay apart beyond 100 m.
   - Transliteration: one letter per Arabic letter (Egyptian ج = g), vowels
     and w/y dropped, doubles squeezed; ث/س/ص -> s, ذ/ز/ظ -> z, ق/ك -> k,
     English q/j/c/ph/ch mapped the same way. Cross-script match needs 85 %
     of skeletons within 300 m. Sane; two-letter skeletons ("nr") can
     collide, which is why common names now need the same site (B1).
   - Survivor: owner list > OSM (node before way) > Wikidata > Overture
     (higher confidence first), then source/id: total and deterministic.
     Merge order is sorted by (distance, rule, ids): same input, same
     groups, no flip-flop. No chains: a newcomer must match the group's
     main entry by a rule; two groups never join.
   - Loader: merged documents get status "merged" + mergedInto +
     mergedBy "import", never deleted; an admin-edited school is the
     survivor and the import's copy is cancelled; two edited schools are
     left alone; parents' schools are only listed.
   - Algolia: `planIndexSync` removes every document that is not active
     or is `searchHidden` (merged and newly dropped schools leave search).
2. **Names** (name_clean.py): mojibake repaired (cp1252 and Latin-1, also
   twice; "Ã‰cole" -> "École"); valid French/Portuguese/German names kept;
   presentation forms and math/fullwidth letters normalised; emoji and
   controls removed; a name below 80 % Arabic/Latin letters is dropped
   (`name_script`, own dropped CSV and count). Diacritics stay in the
   stored name, tatweel is removed (clean_name); matching strips both.
3. **ADM2**: COD-AB Egypt = 27 ADM1, 365 ADM2, reviewed by OCHA 19 Dec
   2024 (catalog record of the HDX dataset; data.humdata.org and
   geoboundaries.org are not reachable from this workspace, so the
   resource names and fields could not be read live). Licence is read from
   the HDX API (`license_title`) or geoBoundaries (`boundaryLicense`) and
   written to adm2_report.md; attribution "OCHA, CAPMAS" is open item D33
   with D24. Point-in-polygon is ray casting on outer rings (B4). The
   loader sets replaced OSM areas and their districts inactive (never
   deletes); per-school `areas` of carpools are a different collection and
   are not touched.
4. **Server**: `parseAddress` accepts an empty area (then no district id);
   `checkAddress` throws `invalid-area` unless `cityHasAreas` is false
   (placeIndex holds no active area with a shape for that governorate); a
   locator without the method counts as "has areas". Counts and district
   requests skip the empty area. Rules files unchanged.
5. **Paged reads** (paged.ts): ordered by document id, `startAfter` the
   last snapshot, stop on a short page: no skip, no duplicate; each page
   retried at most 4 times (5, 10, 15, 20 s), then the error is thrown.
6. **OSM**: the three pieces are valid Overpass QL (exact-value regexes,
   tag existence filters, `(area.g)(s,w,n,e)` chained filters, `out
   center`); quadrants share edges, and features are merged by
   `node/123`-style key, so nothing on a border is lost or doubled. Any
   exception in a part is recorded for that part (the `__main__`
   FetchError crash is gone).
7. **decisions.csv**: per entry keep -> set_kind -> rename -> drop (drop
   wins over keep), then separate (new), merge_into in file order (chains
   and cycles resolve to one school), set_kind again on final schools.
   Bad rows and unmatched keys are reported, never fatal.

## Blocking (fixed by the validator)

- **B1 Generic names merged across 500 m and 2 km.** "مدرسة النور",
  "Al Nour School", "الشهيد أحمد ..." exist many times in one city; the
  same-name-500 m and 2 km rules (and kg_section 300 m) would merge
  different schools. Now a core name found in 3 or more ~2 km cells of the
  input is "common": for such a pair only 150 m (same name, 85 % alike,
  cross-script) or 100 m (contained, KG section) merges; the 2 km rule
  never applies; farther pairs are reported as "common name, different
  place". Counting cells, not entries, keeps one school listed by three
  sources from looking common. Tests added.
- **B2 A merge could never be undone.** With no manual review a false
  merge (or a rule change) left a real school hidden for good: planImport
  skips merged documents. Now (a) decisions.csv `separate` keeps two keys
  apart, and (b) the loader brings a school merged by an earlier import
  (`mergedBy: "import"`, not admin-edited, not a parent's) back to active
  when this run has it as its own school and no survivor lists it; a
  school whose group got another survivor is re-pointed to it. Admin
  merges are never touched. Tests added (Python and Functions).
- **B3 ADM2 from current COD-AB files would fail.** OCHA's files processed
  since 2024 use lower-case `adm2_name`/`adm2_name1` with `lang`/`lang1`
  and `adm2_pcode`, and name members `egy_admin2.*` (no "adm2" in the
  name): every unit would have been skipped and the run would fall back to
  geoBoundaries (English names only). Fields are now matched without case,
  names picked by their language column, `admin2` members and resources
  recognised. Test added.
- **B4 A qism inside its markaz.** Outlines keep outer rings only, so a
  city's qism (a hole in the markaz) is inside both; the first by id won.
  Python `assign`, TS `locate` and `candidates` now prefer the smallest
  box (candidates read 16 instead of 10). Tests added.
- **B5 CI red: two new widget tests.** The Arabic check pumped the same
  screen again and kept its state ("Luxor" chosen); the address test
  never reached step 3. Fresh screen per pump; the test now asserts step 3
  and the geocoded address.
- **B6 App bug found by B5: a city with no areas showed a blank step 3.**
  `_cityWithoutAreas` read an autoDispose provider that is gone once step 1
  is off screen, so the draft was null and no pin was ever placed. The
  screen now remembers the city whose area list came back empty.

## Not blocking (open)

- **N1** name_clean docstring says a repair is kept only with Arabic
  letters and fewer odd characters; the code keeps any strict UTF-8
  decode. Correct in practice (tested French and Arabic), wording only.
- **N2** The OSM "named" piece asks only features with an amenity,
  building, office, landuse, education or school key; a school mapped
  with a name and no such key (the old Latin regex caught it) is missed.
  Rare; the Arabic name piece still catches Arabic names.
- **N3** HDX/geoBoundaries resources, field names and licence text could
  not be read live from here (proxy refuses both hosts); the importer
  handles both field schemes and writes what it used to adm2_report.md.
  Owner's step-12 run confirms (D32).
- **N4** A hole in an ADM2 outline that is not another unit (rare) still
  counts as the outer unit.
- **N5** planImport finds an existing school by its first source key; if
  the survivor's primary entry changes, it can land on a merged document
  and be skipped for that run ("merged"). Next run converges; low.
- **N6** Schools brought back by planUnhide are not in that run's area
  counts (they were `searchHidden` when read); the next run fixes counts.
- **N7** An address without an area skips the pin-in-area check; only
  "in Egypt" is checked. Consider checking the pin's governorate.
- **N8** `separate` rows whose keys are not in the run are not listed as
  unmatched.

## Tests

- Python importer: 122 passed here (`python3 -m pytest tools/import_schools`).
- Functions: type-checked here for the touched files; run in CI.
- Flutter analyze, widget tests and goldens: CI only (no SDK here).
- `bash -n tool/*.sh`: clean.

## CI

Full run (full=true) on a449250 (code head with B1-B6): run 43829253505, all
jobs green (Functions and rules tests, Flutter analyze/tests/screenshots,
web/admin/Android compile). The earlier run 43827653335 on cf44a3c failed
(B5). This review file is a docs-only commit on top.
