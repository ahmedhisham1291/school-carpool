# schools-fixes (16 Nov 2026)

Branch `schools-fixes` off main (1984c7d), after the owner's first full
staging run (7,098 schools kept; 6,202 loaded new). The coordinator gave
the go for the owner.

## Asks and what was done

1. **OSM per-governorate crash** (EG-ALX traceback): `fetch_parts` caught
   only `fetch_osm_schools.FetchError`; run as a script that module is
   `__main__`, so its FetchError is another class and went through. Every
   error of a part is now recorded (status line) and the other parts go
   on; the second pass retries. **Slow parts:** each governorate is three
   pieces: `tags` (exact tag lookups), `names` (the anchored Arabic regex,
   which finished in the failed run), `named` (every named feature with an
   amenity/building/office/landuse/education/school key, no regex; in the 9
   biggest governorates per quadrant; the Latin and KG name rules run in
   Python). The unanchored case-insensitive Latin regex (line 16, where
   maps.mail.ru stopped) is gone. Not measured against the servers here.
2. **Overture names:** the language comes from the letters (Arabic ->
   name:ar, Latin -> name:en, mixed -> the dominant script), names.common
   and names.rules win when they give a language. Earlier loaded schools
   were already split by the importer (has_arabic), so only the report
   count was wrong; the loader updates any name that changes.
3. **Courses/centres drops:** dropped_<reason>.csv per reason (name,
   names, source, id, category, governorate, confidence; no position).
   New reasons: tutoring centres (سنتر, دروس, كورسات, IELTS, ...) and Quran
   memorisation (دار تحفيظ, كتاب); Azhar institutes kept; Overture
   preschool/day-care places named for small children kept even with
   "Academy", "Club", "Center".
4. **Areas:** fetch_adm2.py (HDX COD-AB, geoBoundaries fallback, or a local
   file; standard-library shapefile reader); the import uses ADM2 units as
   Areas, OSM named places and boundaries as Districts; the loader sets the
   old OSM areas inactive. New cities: reported per run (adm2_report.md).
5. **Algolia DEADLINE_EXCEEDED:** paged reads (500, only the index fields,
   each page retried), each page sent before the next is read; the loader,
   admin-grams and places reads are paged too.
6. **Algolia record warning:** a to-do line above 8,000 records
   (ALGOLIA_RECORD_WARN). Note: Algolia's free plan is 50,000 records and
   10,000 searches a month (pricing change of Aug 2026; docs/COSTS.md), so
   8,000 is a conservative line, not the limit.
7. **Automatic de-duplication:** dedupe.py (rules in DECISIONS.md), merged.csv,
   `mergedFrom`, loader hides merged documents (status merged, mergedInto),
   admin-edited survivor, parents' schools only flagged.
8. **Name script:** name_clean.py (mojibake repair, NFKC, controls/emoji,
   Arabic/Latin check); our pipeline is UTF-8 end to end, so mojibake is
   upstream. Loader hides loaded schools that the rules now drop (and
   brings back ones that pass again).
9. **Review decisions** (data/schools/review/decisions.csv, README there)
   and build/schools/review_input.csv. Commit 40bebda.
10. **Menus:** helper texts instead of silently disabled Area/District
   (admin Schools search, admin "Move to area", app browse, address form);
   a city with no areas: the address goes on without an area, district
   typed and optional (server accepts it only when the city has no area).

## Not run here

No network to Overpass, HDX, geoBoundaries, Overture or PyPI; no Flutter
SDK. Python tests (116) and Functions tests run here; Flutter widget tests
written, not run; shellcheck not installed (`bash -n` only).
