# Prompt 4B: Schools list for Egypt (F4) — progress note

Branch: `prompt-04b-schools` (from the Prompt 4 branch, which includes
`main` with the design refresh). Date: 13 Nov 2026. The coordinator gave
"go" on the owner's behalf.

**Status: code complete; the Python tool and the Functions unit tests were
run here; the Flutter code and the rules tests were not compiled or run**
(no Flutter SDK or package registry in this workspace). See "Verified here
vs not run".

## Plan that was followed

1. Import tool (Python, standard library only) with a hand-written sample
   and its tests.
2. Functions: idempotent loader, Algolia sync and secured search key,
   parent "Other" schools, children linked to a school, approve/merge
   follow-ups in the admin panel functions.
3. Rules for `schools` (active and own pending only) with emulator tests.
4. App: search interface (Algolia and a fake), school picker, "Other"
   form, picker field in the child form (registration and "add a child"),
   About with the OpenStreetMap credit; AR/EN strings; tests and
   screenshots.
5. SETUP section 14, COSTS, DESIGN, CI step, this note.

## How it works

**Import** (`tools/import_schools`, Python 3.11+, no packages). Reads
`data/schools/`: the HDX OpenStreetMap export (GeoJSON points and
polygons, plain or zipped, or its CSV), any ministry/governorate/school
group CSV (English or Arabic headers), and optional governorate
boundaries in `data/schools/boundaries/`. It keeps `amenity=school` and
`kindergarten` (drops universities, colleges, courses, childcare), keeps
Arabic and English names (one fills in for the other when missing),
governorate (from the file, the boundaries, or the nearest of about 140
reference towns), city or district, location, source and source ID.
Names are normalized for matching only (alef forms, yaa/alef maqsura,
taa marbuta, diacritics, tatweel, digits; same rules as the server and the
app). Duplicates are merged when the names match (one slip per word
allowed, generic words like "مدرسة"/"School" ignored, a shorter name
fully inside a longer one counts) within 300 m; a list entry without a
pin merges into the one same-name school of its governorate. Output:
`build/schools/schools.json` and `report.md` (per governorate, dropped
with reasons and examples, merged groups, likely duplicates not merged).
Same input, same output and IDs (`osm-n123`, `list_<file>-<id>`).

**Load** (`npm --prefix functions run schools:load:emulator` or
`schools:load:cloud`): matches each school by ID or by any source key,
writes only new or changed schools, never touches schools an admin
edited (`adminEdited`, set by every admin save), merged schools or
parents' schools, and deletes nothing. Second run of the same file: no
writes (checked in CI on the emulator).

**Search.** `syncSchoolToSearch` (Firestore trigger) puts active schools
in Algolia with names, normalized names, governorate, city and point only,
and removes anything else; it does nothing when no indexed field changed
or when `SCHOOL_SEARCH_PROVIDER=fake`. The app asks `getSchoolSearchKey`
for a one-hour **secured key** limited to the index (HMAC of
`restrictIndices` and `validUntil` with the search-only key; the parent
key and the write key stay in Secret Manager). On the emulators the app
uses `FirestoreSchoolSearch`: it reads up to 200 active schools once and
matches on the phone (same normalization, prefix and one-slip typo
matching). In a cloud project where the server still says "fake", the
app uses the same fallback. No Algolia account is needed for dev or CI.

**Picker** (registration's child step and Profile > Children > add or
edit): a picker field opens the school picker. Search as you type (2
letters, 300 ms debounce), Arabic or English, governorate filter chip
(sheet with the 27 governorates), the parent's own schools awaiting
review first and marked, and **"Other school" as the last row in every
state**. "Other" opens a short form (name, governorate, optional pin
pasted from Google Maps) → `addOtherSchool` saves `schools/{id}` with
`status: awaiting_review`, `source: parent`, `addedBy: uid`; the picker
returns it and the parent carries on. At most 5 pending per parent; the
same name in the same governorate returns the existing one.

**Admin queue** (Prompt 4's "New schools"): already reads
`schools` with `status == awaiting_review`, so parents' schools appear
there. Approving now clears `addedBy` (every parent can read active
schools, so the parent's uid must not stay on it); the trigger then
indexes it, and a second parent finds it. Merging now also renames the
moved children's `schoolName`.

**Children.** `submitVerification` requires a `schoolId` per child: an
active school, or the parent's own pending school; a school merged
meanwhile is followed to its target. Anything else: `unknown-school`
("Choose the school again."). The child keeps `schoolId` and the shown
name (or the school's Arabic name).

**About** (Profile > About): app description, "© OpenStreetMap
contributors, available under the Open Database License (ODbL)", a row
that copies `https://www.openstreetmap.org/copyright`, and the
open-source licences page.

## Data model

| Where | Change |
| --- | --- |
| `schools/{id}` | New fields: `kind`, `cityAr`, `sourceId`, `sourceKeys`, `importedAt`, `adminEdited`. `addedBy` only while a parent's school awaits review. IDs from the import are stable (`osm-n123`). |
| `children/{id}` | `schoolId` now set at submission (was `null`). |
| Algolia index | `objectID, nameAr, nameEn, searchKeys, kind, governorate, city, cityAr, _geoloc`. Nothing about parents. |
| Functions | `addOtherSchool`, `getSchoolSearchKey`, `syncSchoolToSearch`; params `SCHOOL_SEARCH_PROVIDER`, `ALGOLIA_APP_ID`, `ALGOLIA_INDEX`; secrets `ALGOLIA_WRITE_KEY`, `ALGOLIA_SEARCH_KEY`. |
| Rules | `schools`: get/list for signed-in users when active, or awaiting review and `addedBy == uid`; lists at most 200; no app writes. `areas` stay closed (Prompt 5). |

## Decisions

1. **Python for the tool, TypeScript for the load.** Python stdlib does the
   parsing, cleaning and report with nothing to install; the loader uses
   the Admin SDK the Functions already have, and shares the plan logic
   with the unit tests.
2. **Governorate by nearest town** when no boundaries file is given; the
   report counts these. Exact with HDX's admin-1 boundaries.
3. **Algolia over REST with `fetch`** in Functions and `HttpClient` in the
   app: no new package. The website gets the fake fallback message
   (search returns "unavailable") until its platform work (Stage 2).
4. **Parents' schools stay in `schools`** (the Prompt 4 queue reads them
   there); privacy is kept by the rules (own pending only) and by
   clearing `addedBy` on approval.
5. **Pin as typed coordinates** in "Other" (same input as the admin
   panel); the map picker is Prompt 5.
6. **"Other" is one short form** (three fields, checked as typed), like
   the Prompt 4 forms; no step indicator for three fields.
7. **`AppPickerField`** added to the design system and the gallery.

## Screen states

| Screen | Loading | Empty | Error | Offline |
| --- | --- | --- | --- | --- |
| School picker | skeleton rows | before typing: own pending schools and a hint; no results: empty view | error view + retry | offline view + retry |
| "Other" form | button spinner while saving | n/a (nothing loaded) | inline message above the button | inline "No connection. Try again." |
| About | n/a (static) | n/a | n/a | n/a (copy confirms with a snackbar) |

"Other school" stays the last row of the picker in every state.

## How to test it (the "Done when" check)

On the emulators (Mac):

1. `firebase emulators:start --project demo-school-carpool`, then
   `npm --prefix functions run seed:emulator`.
2. `python3 tools/import_schools/import_schools.py --input data/schools/sample`
   and read `build/schools/report.md` (per governorate, dropped and why,
   likely duplicates). Run it again: same output.
3. `npm --prefix functions run schools:load:emulator`, twice: the second
   run says `new: 0, changed: 0`.
4. On the iPhone (dev build against the emulators, SETUP section 9): sign
   in as a new parent, start verification, add a child, tap **School**:
   type "فيكتوريا" → Victoria College; type "manor" → Manor House School;
   try "Victorya" (typo) and the governorate chip.
5. Type "Zohour", tap **Other school**, choose a governorate, **Add
   school**: it comes back as the child's school ("Awaiting review") and
   the parent carries on.
6. In the admin panel (`flutter run -d chrome -t lib/admin/main_admin_dev.dart`),
   **New schools**: open it, add the city, **Approve**.
7. Sign in as a second parent, add a child, search "Zohour": it is there.
8. Profile > **About**: the OpenStreetMap credit.

With real data: SETUP section 14 (download from HDX, run, load; Algolia
keys before staging).

## Tests

| Test | Status |
| --- | --- |
| `tools/import_schools/test_schools_import.py`: normalization, generic words, similarity, governorate names, nearest town, boundaries, stable IDs, drop reasons, names/city/governorate, merge within 300 m only, list entries without a pin, Arabic-header CSV, OSM CSV in a zip, the sample end to end, identical output twice, CLI | **Run here: 30 pass** (Python 3.13), incl. every review case (stage, gender, person names, containment, no chains) and Excel CSVs |
| `functions/test/schools.test.ts`: normalization cases, import plan (create, second run writes nothing, match by source key, admin edits/merged/pending left alone, never deletes, one write per target), index record has no parent data, sync actions, secured key (HMAC checked), REST calls, "Other" parsing, dedupe, limits, refusals | **Run here: pass** |
| `functions/test/verification_flow.test.ts`: child needs a school; own pending allowed, another parent's refused, merged followed, name kept or replaced | **Run here: pass** |
| `functions/test/admin_panel.test.ts`: approve clears `addedBy` | **Run here: pass** |
| All Functions unit tests | **Run here: 188 pass** (Node 22, `tsc` with stand-in type stubs and small runtime stubs, as in earlier prompts) |
| Sample `schools.json` → loader plan twice | **Run here**: 41 created, then 0 created, 0 changed, 41 unchanged |
| `tests/rules/schools.test.ts` (+ `admin.test.ts`, `deny_all.test.ts` updated) | Written, not run here (CI) |
| CI step: Python tests, sample import, load twice into the emulator, second load writes nothing | Written, not run here |
| `test/schools/schools_logic_test.dart`: normalization, matcher (AR/EN, typos, place, governorate), Algolia request and key refresh, server-selected fallback, name rule, failure mapping | Written, not run here |
| `test/schools/schools_screens_test.dart`: AR and EN search, "Other" last in every state, governorate filter, "Other" form with pin checks, own pending first, error kept on the form, About credit and link copy, one line at 320 dp (AR/EN) | Written, not run here |
| Verification tests updated (picker in the child step, `schoolId` in the payload) | Written, not run here |
| Screenshots `school_picker`, `school_picker_results`, `school_picker_empty`, `school_other`, `about` (AR/EN, light/dark) | Written, not run here (CI artifact) |

## Verified here vs not run

Run here: the Python tool and its 30 tests; Functions type-check (only the
known stub gaps for `initializeApp(options)` and Sentry types remain) and
188 unit tests; the loader plan on the sample output; ARB parity (644 keys
each; every `l10n.*` used exists); import order and bidi-character scan of
the changed Dart files.

Not run: `flutter analyze`, `flutter test`, `flutter gen-l10n`,
screenshots, the rules tests and the CI emulator step. Expect small
analyzer fixes on the first CI run. Checked against sources: Algolia's
secured-key scheme and Build plan terms (1M records, 10,000 searches a
month, evaluation only).

## Fixes after the validator review (docs/reviews/prompt-04b-review.md)

Blocking:

1. **Merging only the same school** (`tools/import_schools/schools_import.py`).
   Stage words (KG, ابتدائي, إعدادي, ثانوي, primary, preparatory,
   secondary...) and gender words (بنين, بنات, boys, girls) are compared
   separately: different stage, gender or kind is never merged; when only
   one name says it, the pair is reported. A one-letter slip counts only in
   words of 6+ letters and never in a person's name (common given names,
   and words after الشهيد / martyr / دكتور...). A merge needs the same
   words (similarity 1.0); one name inside the other and pairs with half
   the words alike go to the report. Groups grow only by single entries
   that also match the group's main entry within 300 m (no chains). Every
   case from the review is a test. Sample: 4 merged groups (El Alsson is
   now reported), 3 likely duplicates.
2. **Per-user search limit.** Secured keys carry `userToken` (a hash of the
   uid, so Algolia never sees our user IDs); the parent key's limit is now
   100 searches an hour, counted per user. `getSchoolSearchKey` gives at
   most 6 keys a day per parent (`searchKeyLimits/{uid}`, functions only,
   closed in the rules): about 600 requests a day for one account at most.
   Tests check the HMAC'd parameters include `userToken`, the daily cap,
   and the next-day reset.

Non-blocking, done: Excel CSVs (UTF-8 BOM, UTF-16, Windows-1256, comma,
semicolon and tab), unreadable files reported instead of crashing; list
rows without an ID get a stable hash of name, governorate and city; OSM
types like `nodes`/`ways_poly` keep their prefix; admin-created schools
carry no uid (`addedBy: null`); the app sends the normalized query, caches
answers for 10 minutes (50 entries), and Enter no longer sends the query
twice (stale answers were already dropped); prod refuses the fake search
on the server (reported to Sentry) and in the app ("unavailable", never
the 200-school fallback). Picker titles stay one line with an ellipsis;
the second line shows the area and governorate (screen readers read the
full name).

Deferred (non-blocking): Dart normalizer has no NFKC (presentation forms;
item 8); state views in the picker have a fixed height (item 10, check at
200 % on the screenshots); `addOtherSchool` check-then-create outside a
transaction (item 11; the same-name dedupe limits it to a rare double
tap); a reject action for junk "Other" schools (item 12, owner question
6); approving with corrected names does not rename linked children.

## Learned from earlier reviews

- No literal bidi marks: the coordinate example uses `ltrIsolate`.
- Every label is one line; new labels are in a one-line test at 320 dp.
- Lazy lists in tests: the governorate sheet uses `scrollUntilVisible`
  with an explicit scrollable; picker tests use a tall view.
- Rules tests use `as const` for `sign_in_provider`.

## Open questions for the owner

1. **Algolia's Build plan is "for evaluation, not production"** (its
   terms). Apply to Algolia's non-profit programme, or budget the paid
   plan before launch? (docs/COSTS.md, open question 3.)
2. **ODbL share-alike** (spec section 7): our list is a derived database of
   OpenStreetMap. Ask the lawyer whether we must publish it (and the
   ministry lists merged in) under the ODbL.
3. **Ministry lists:** which lists can you get, and may we merge them
   with OpenStreetMap data (licence of each list)?
4. **Website search:** the website uses the fake fallback until Stage 2.
   OK?
5. **Pending limit:** 5 "Other" schools per parent waiting at once. OK?
6. **Reject "Other":** should admins be able to reject a junk "Other"
   school (it now stays until approved or merged and counts toward the
   parent's 5)?
7. **Search limits:** 100 searches an hour and 6 keys a day per parent.
   OK, or tighter for the free month?

## Not done / known gaps

- Map picker for the "Other" pin and the school map (Prompt 5).
- Areas per school stay admin-only (Prompt 5).
- Search on the website (Stage 2); the app's `HttpClient` is iPhone and
  Android only.
- Approving with corrected names does not rename children already linked
  to that school (merging does).
- The import does not remove schools that disappear from OpenStreetMap; it
  lists them ("imported earlier, not in this file") for the admin.
- Real data was not downloaded here (no access to HDX from this
  workspace): only the hand-written sample was imported.
