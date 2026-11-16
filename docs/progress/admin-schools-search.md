# Admin panel: Schools search and filters (F14)

Branch `admin-schools-search`. Owner request (via the coordinator, "go"
given): in the admin panel's Schools list, search by name (Arabic and
English, typo tolerant, ة/ه, ى/ي, أ/إ/ا), filter City -> Area -> District
(dependent dropdowns, a new parent clears the children) plus status,
visibility and source, combinable, paged, counted, sorted by name, "Clear
filters", filters in the URL, hidden/sample/unapproved schools for admins.

## Plan (done)

1. Functions: `adminSearchSchools` (admin claim, second factor and fresh
   session through the existing `adminCall` guard), rate limited (120 per
   admin per 10 min), first page audited (`school.search`, kinds of
   filters only, never the text).
2. Data: `schools/{id}.adminSearchGrams` (server only), written by every
   writer (panel save/approve, "Other" schools, importer's
   `importedFields`, seed), repaired by the `syncSchoolAdminGrams` trigger,
   and filled once for existing schools by `schools:admin-grams`.
3. Indexes: 13 new composite indexes on `schools` (each filter field +
   `nameAr`/`nameEn`, and `adminSearchGrams` CONTAINS + name); Firestore
   merges them for any mix of equality filters.
4. Panel: new `SchoolsScreen` (the "Other" queue keeps the old
   `SchoolList`), `SchoolFilters` <-> URL query parameters, new
   `AdminApi.searchSchools`.
5. Docs: spec (admin screens, School data model), COSTS.md (choice and
   cost), SETUP.md 14.7 (indexes + one-time grams fill).

## Design choice: Firestore, not Algolia

The parents' Algolia index has only active, visible schools; admins must
find hidden sample, awaiting-review and merged schools too. A second
Algolia index would double records and sync calls, spend the free 10k
searches/month on staff, need setup-script changes, and dev would still
need a Firestore path (fake search). So:

- grams = first 3 letters of each normalized word and, from 4 letters,
  letters 2-3-4, 1-2-4 and 1-3-4 (validator fix: one typo anywhere in the
  first four letters still shares a gram), also for the word without "ال";
  a query asks `array-contains-any` (<= 30 grams, rare
  words first; "مدرسة", "school", "international"... only when nothing
  else is typed) plus the equality filters, ordered by name;
- every candidate is checked in memory: each query word must start a name
  word, with 1 typo from 4 letters, 2 from 8 (insert, delete, change,
  swap); at most
  600 schools read per page (count is then "at least N");
- without text: equality filters + `count()` (exact; hidden ones
  subtracted when left out);
- a missing index degrades to one Firestore filter, the rest in memory,
  reported to Sentry, and the panel says the count may be low.

Not changed: the Algolia sync/settings (no `placeDistrictId` facet was
needed for this; the parents' search is unchanged), `tools/import_schools`,
`tool/cloud_setup.sh`.

## Screen: Schools (admin, English default; RTL-checked in Arabic)

Layout: app bar "Schools" with "Add school" (the one primary action);
search field (debounced 0.4 s; Enter searches now); a wrapping row of
dropdowns (AppDropdownMenu): City, Area (disabled until a city), District
(disabled until an area), Sort by (Arabic/English name; default by panel
language); switch "Show hidden and unapproved" revealing Status,
Visibility (shown/hidden in parents' search) and Source; "Clear filters"
(enabled when anything is set); count line ("12 schools" / "At least 600
schools"); results: a table from 640 dp (Arabic name in RTL, English name
in LTR, City, Area, District, Source, Status + "Hidden" badge; hairline
row dividers, rows open the school), list rows below 640 dp; "Load more"
(50 a page).

States: loading = skeleton list; empty = "No schools match" + "Clear
filters" (filtered) or "No schools yet" (unfiltered); error and offline =
the shared AdminAsyncView views with "Try again"; degraded = warning line.

URL: `/schools?q=&city=&area=&district=&all=1&status=&vis=&source=&sort=ar|en`
(unknown values and a child without its parent are dropped).

## Tests

| Test | Result |
| --- | --- |
| `functions/test/school_search.test.ts` (21: grams, normalization ة/ه ى/ي أ/إ/ا, typos, query plan, includeAll/status/visibility/source, City->Area->District + text combined, sort, bad input, paging and exact counts, scan cap, audit without text, rate limit, missing-index fallback, grams upkeep, callable refuses signed-out and non-admin callers, index.ts exports) | **Run here: pass**; full Functions suite 819/819 (against the workspace's type stubs; `tsc` prints only the known stub errors) |
| `tools/import_schools` pytest (untouched) | Run here: 72 pass |
| `test/admin/admin_schools_search_test.dart` (SchoolFilters URL round trip and rules; widget: dependent City/Area/District + URL, a new city clears children, bookmark restores filters, debounced typing + count + table + RTL Arabic cell, no match + clear filters, show all + status, offline + retry, Arabic narrow list) | Written, not run here (no Flutter SDK) |
| Existing one-line and screenshot tests cover the new `/schools` screen | Written, not run here |
| Admin goldens | The repo has none for the admin panel (only `test/screenshots`); none added |

## Open questions / notes

1. **Setup (coordinator):** each cloud project needs `firebase deploy
   --only firestore:indexes` and once `schools:admin-grams -- --yes`
   (SETUP.md 14.7). If `tool/cloud_setup.sh` should run the grams fill
   after loading schools (step 12 area), that is for whoever owns step 12;
   not edited here.
2. The importer worktree (`wt-schools-sources`) may touch
   `functions/src/schools/store.ts`; this branch adds one line
   (`adminSearchGrams`) to `importedFields` and the "Other" create. A
   merge conflict there would be trivial.
3. A bookmark opened while signed out lands on Home after sign-in (the
   existing redirect drops the path and query); opening it while signed in
   works. Changing that touches the sign-in redirect for every page; left
   as is.
4. Typo tolerance is not Algolia-grade: a typo in BOTH of the first two
   letter positions of a one-word query is not found. If the owner wants
   more, the next step is an Algolia admin index (cost in COSTS.md).
5. Sources offered in the Source filter: osm, wikidata, admin, parent,
   seed, plus any seen in results or in the URL (list files are
   `list_<name>`).
