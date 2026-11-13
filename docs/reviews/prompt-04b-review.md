# Review: Prompt 4B (Schools list for Egypt, F4)

Branch: `prompt-04b-schools`, head `f514ee7` (includes `main`). Reviewed
13 Nov 2026 by the validator agent.

Scope: `git diff origin/main...HEAD` (67 files, +6762/-50). Checked against
CLAUDE.md (STACK, COST MODE, DESIGN, SECURITY, PRIVACY, LANGUAGES, TESTS),
`docs/DESIGN.md`, `docs/WORKFLOW.md`, `docs/spec.md` (F4, section 3 step 5,
School row in section 9), `docs/build-prompts.md` (Prompt 4B and its "Done
when") and `docs/progress/prompt-04b.md`.

What I ran here: the import tool's Python tests (`python3 -m unittest`,
**18 pass**), and the sample import twice into two folders (byte-identical
`schools.json` and `report.md`). I also probed the matcher and the parsers
with my own inputs (results below). There is no Flutter SDK here, so
`flutter analyze` and `flutter test` were **not run here**. The Dart and
rules results below come from CI.

## Verdict

**CHANGES NEEDED.**

CI is green, and most of the build is sound. The rules show pending "Other"
schools only to the parent who added them. The admin queue reads the real
`schools` collection. Approve clears `addedBy`. Merge moves children's
`schoolId` and `schoolName`. The Algolia record holds school names and
places only. The write key stays in Functions and the admin key stays off
the repository. The app gets a one-hour secured key limited to the index,
and only after sign-in. The dev fake search works with no Algolia account.
The About screen shows the OSM/ODbL credit.

Two problems block approval:

1. The duplicate merge joins schools that are different, such as primary
   and secondary schools of the same name, or schools named after different
   martyrs.
2. Search has no per-user rate limit, so one signed-in user can use up the
   whole free Algolia month.

## CI result

Run `43459827052` (push, head `f514ee7`): **success**.

| Job | Result |
| --- | --- |
| Flutter analyze, tests and screenshots | **passed** |
| Cloud Functions tests and rules tests (emulators) | **passed**: includes `tests/rules/schools.test.ts`, the Python tests, the sample import, and two loads into the emulator where the second load writes nothing |
| Web, admin panel and Android compile (staging) | **passed** (web, admin panel and Android APK) |

## Blocking issues

1. **The duplicate merge joins different schools.**
   - `tools/import_schools/schools_import.py:86-91` treats stage words as
     generic. These are `ابتدائيه`, `اعداديه`, `ثانويه`, `primary`,
     `preparatory` and `secondary`.
   - `:141` allows one spelling slip in any word of 4 letters or more.
   - `:162` gives 0.85 when one name is contained in the other. That is
     above `MERGE_SIMILARITY` 0.8.
   - `:748` merges in a union-find, so A~B and B~C also merge A with C.

   Scores I measured with `token_similarity`:
   - "مدرسة النصر الابتدائية" / "مدرسة النصر الإعدادية": **1.0**
   - "Nasr Primary School" / "Nasr Secondary School": **1.0**
   - "مدرسة الشهيد أحمد" / "مدرسة الشهيد محمد": **1.0**
   - "مدرسة الشهيد محمد علي" / "مدرسة الشهيد محمود علي": **1.0**
   - "مدرسة سعد زغلول الابتدائية" / "مدرسة سعد زغلول الثانوية بنات": **0.85**

   In Egypt, primary, preparatory and secondary schools, and boys' and
   girls' schools, often share one site. They are separate schools with
   their own hours, so merging them silently puts parents in the wrong
   school group. The prompt asks to merge entries that *share a name*.

   Fix:
   - Treat stage and gender words (`ابتدائي/اعدادي/ثانوي/بنين/بنات/primary/
     preparatory/secondary/boys/girls`, KG versus school) as
     distinguishing. If they differ, never merge. If only one side has one,
     report the pair as a likely duplicate instead of merging.
   - Allow the one-slip match only in words of 6 letters or more. Never
     auto-merge on a slip in a personal name; report those pairs instead.
   - Only auto-merge on containment when the names are otherwise equal
     after the stage and gender check.
   - Check each new member against the group's primary before joining it
     (no chains).
   - Add the cases above to `test_schools_import.py` and the TS/Dart
     matcher tests where they share rules.

2. **No per-user rate limit on school search.**
   - `functions/src/schools/algolia.ts:39`: the only limit is the parent
     key's `maxQueriesPerIPPerHour: 2000`, which the owner sets by hand
     (SETUP.md 14.4).
   - `algolia.ts:51-54` and `callables.ts:60-76` (`getSchoolSearchKey`):
     the secured key carries only `restrictIndices` and `validUntil`.

   Egyptian mobile networks put many users behind shared (CGNAT)
   addresses. A per-IP limit is too strict for them and does nothing
   against one abusive account. At 2000 an hour, one signed-in user can use
   the 10,000-search free month (COST MODE) in about 5 hours, and search
   then stops for every parent.

   Fix:
   - Add `userToken=<uid>` to the secured-key parameters. Algolia then
     applies the parent key's rate limit per user token, not per IP.
   - Set the limit to fit the budget, for example 100–200 an hour, and
     update SETUP 14.4 and COSTS.md.
   - Optionally cap `getSchoolSearchKey` calls per uid.
   - Add a unit test that the HMAC'd parameters include `userToken`.

## Non-blocking

1. **CSV parsing is fragile** (`schools_import.py:456`). It decodes only
   UTF-8. A Windows-1256 Arabic Excel export crashes the whole run with a
   `UnicodeDecodeError` traceback (verified). A semicolon-delimited list
   drops every row as "No name" (verified). Fix: detect the BOM, then fall
   back to UTF-16 and cp1256; use `csv.Sniffer` for the delimiter; report a
   bad file as a problem instead of crashing.
2. **List IDs without an ID column use the row number**
   (`schools_import.py:486`). Editing the list shifts the IDs, and the
   loader then matches source keys to the wrong school and updates it. Use
   a hash of normalized name + governorate (+ city) instead.
3. **`osm_type` values** (`schools_import.py:380`). Only
   `node/way/relation/n/w/r` get a prefix. If the HDX/HOT export uses
   values like `nodes` or `ways_poly`, the prefix is lost. Node and way IDs
   can then collide, and the second entry is dropped as "Same source ID
   twice" (verified with a crafted file). Fix: match on the first letter,
   then check against a real HDX file before the first real import.
4. **Admin-created schools keep `addedBy: caller.uid`**
   (`functions/src/admin_panel/schools.ts:121`). Every signed-in parent can
   read active schools, so admin uids are exposed. Fix: set it to `null`
   for active schools (the audit log already keeps the actor).
5. **Algolia cost.**
   - The search field's submit (`school_picker_screen.dart:262`) does not
     cancel the debounce timer, so one query is sent twice.
   - `AlgoliaSchoolSearch` (`school_search.dart:177`) has no result cache.
   Fix: cancel `_timer` on submit, and add a small LRU cache keyed by
   (normalized query, governorate).
6. **Silent fallback in prod.** `SCHOOL_SEARCH_PROVIDER` defaults to
   `"fake"` (`functions/src/config.ts:96`). If staging or prod is
   misconfigured, the app quietly searches only the first 200 active
   Firestore schools. Fix: refuse the fallback outside the emulators, or at
   least report it to Sentry.
7. **The query is not normalized.** The app sends the raw query
   (`school_search.dart:182`). Normalize it in the app so it always matches
   `searchKeys` (taa marbuta, alef forms).
8. **Normalizer parity.** The Dart normalizer
   (`lib/features/schools/text_normalize.dart`) has no NFKC step, while
   Python and TS do. Arabic presentation forms and decomposed hamza then
   match differently.
9. **Picker result titles are one line with an ellipsis**
   (`app_list_row.dart:68`). Long Arabic names that differ only at the end
   (stage or gender) cannot be told apart. School names are data, not
   labels: allow two lines here, or show the stage and gender in the
   subtitle.
10. **State views have a fixed height.** `_stateHeight` is 320
    (`school_picker_screen.dart:66`). The empty, error and offline views
    may overflow at 200 % text size. Let them size to their content.
11. **`addOtherSchool` can create twice.** It checks and then creates
    outside a transaction (`functions/src/schools/other.ts:117-133`), so a
    double tap or a retry can create two pending schools.
12. **No way to reject a pending school.** There is only approve or merge,
    so a junk "Other" entry stays forever and counts toward the parent's
    limit of 5. Ask the owner whether a reject action is wanted.
13. **Known gaps, as listed in the progress note:** approving a school
    with corrected names does not rename children already linked to it;
    real HDX data has not been imported; the map pin comes in Prompt 5.

## Done-when coverage

| Check | Status |
| --- | --- |
| Run the import and read the report | Verified here on the sample: per governorate, dropped with reasons, merged groups, likely duplicates. The output is identical on a second run, and CI's second load writes nothing. Real HDX data was not run. |
| Find a school by part of its name in Arabic and English on iPhone | Widget tests in CI (AR/EN, typo, governorate filter); the owner still has to check on the iPhone |
| "Other" → approve in the panel → a second parent finds it | Covered by Functions tests (approve clears `addedBy`, sync upserts), rules tests and the dev fake's 1-minute refresh; the owner still has to check on the iPhone |
| OSM credit on About | Present (ODbL text and a link to `openstreetmap.org/copyright`), with a widget test |
