# Review: admin-schools-search (F14 admin Schools search and filters)

Validator review of branch `admin-schools-search` (builder head 04037ff on
main f8bcd60; main d1198d8 merged in afterwards).

**Verdict: PASS** (after the fixes below; full CI run green on the merged head).

## Checked

- Admin claim, second factor and fresh session: `adminSearchSchools` uses
  the same `adminCall` wrapper and `options` (App Check setting) as every
  other admin callable. Callable tests: signed out -> unauthenticated,
  parent without the claim -> permission-denied.
- Rate limit (120 per admin per 10 min, own counter doc), 600-read cap per
  page, audit on first page with kinds of filters only (test asserts the
  typed text is not in the entry or in the missing-index report).
- Algolia: `searchRecordFrom` builds the record from an allowlist, so
  `adminSearchGrams` is never sent, and a grams-only write is a no-op for
  `syncSchoolToSearch`.
- Trigger `syncSchoolAdminGrams` cannot loop: it writes only when the
  sorted grams differ from what the names give; its own write compares
  equal next time. A stale write racing a newer name change is repaired by
  the trigger run of that write itself (converges).
- Index list: 13 new composite indexes (each filter field + nameAr/nameEn,
  and `adminSearchGrams` CONTAINS + name). Every one-filter query the code
  can send (including every fallback) has its own index; multi-filter
  queries rely on Firestore index merging; `count()` uses equality filters
  only (no composite index needed). Fallback order is correct.
- Arabic normalization: shared `normalizeText` (ة/ه, ى/ي, أ/إ/آ/ا,
  diacritics, tatweel, Arabic-Indic digits); "ال" and "وال" forms.
- Dependent dropdowns: `withCity` clears area and district, `withArea`
  clears district; the child dropdowns are re-keyed on the parent; widget
  test covers it.
- URL params: unknown city/status/visibility/sort dropped, bad IDs
  dropped, child without parent dropped, text cut to 80, the "show all"
  filters only with `all=1`; the server validates the same rules again.
- No regression: `adminListSchools` and the "Other" queue (`SchoolList`)
  unchanged; parents' Algolia sync unchanged; rules unchanged (no rules
  tests needed).

## Blocking (fixed by the validator)

- **B1 Typo tolerance missed typos in letters 2 and 3.** Grams were only
  letters 1-3 and 2-4, so one wrong letter at position 2 or 3 broke both
  (for example "Fqtima", "زحراء" found nothing). Now from 4 letters also
  the picks 1-2-4 and 1-3-4: any single change, missing, extra or swapped
  letter among the first four keeps a shared gram. Tests added (English
  and Arabic). Existing schools get the new grams from
  `schools:admin-grams` / the trigger (nothing deployed yet).
- **B2 CI red:** callable tests called the wrapped function (fails with
  real firebase-functions; now `.run` as in features.test.ts);
  `flutter analyze` (missing import of `OfflineStateView`, redundant
  arguments, const maps, doc comment); two widget tests tapped a "Cairo" /
  "Awaiting review" table cell instead of the menu item (shared helper
  `pickFromDropdown` now taps inside `MenuItemButton`).
- **B3 Count disagreed with rows for a hand-edited URL** (an area of
  another city): only the most specific place went to Firestore, so
  `count()` counted the area's schools while the rows were filtered out
  in memory. All place levels now go to Firestore; test added.

## Non-blocking

- **N1 (fixed)** An empty first page with a next cursor (scan cap reached
  before a match) showed "No schools match" without "Load more"; now it
  shows "Load more".
- **N2 (fixed)** With no composite index built yet (just after a deploy)
  the one-filter fallback itself failed; it now falls back to name order
  only. SETUP.md's "works meanwhile in a slower mode" is now true.
- **N3 (fixed)** Docs said 14 new indexes; it is 13.
- **N4 (open, accepted)** `adminSearchGrams` is not hidden from clients:
  Firestore rules cannot hide one field, and signed-in parents can read
  active school documents. The grams are a pure function of the public
  names (no new information); spec wording corrected ("written only by
  Cloud Functions ... read with the school document"). Moving them to a
  server-only mirror collection would need its own copy of every filter
  field; not worth it now.
- **N5 (open)** Index merging with `array-contains-any` plus equality
  filters is not checked by the emulator (it does not enforce indexes).
  Google's docs allow merging for array-contains but recommend a dedicated
  index if it is slow. Smoke-test on staging after deploy (text + city +
  status); a missing index shows the "slower way" line and a Sentry event.
- **N6 (open)** A first text page reads up to 600 schools to count
  matches; broad queries (one common word) always hit the cap. Cost stays
  small (COSTS.md), but if the audit log shows heavy use, count only the
  first 200 or move to an Algolia admin index.
- **N7 (open)** Words of the new "university" kind (جامعه, university) are
  not in the common-words list; harmless (only more candidates).

## CI

Full run (full=true) on the merged head: see the report message; screenshots
artifact `screenshots` holds `admin_schools_{ar,en}_{light,dark}.png`.
