# Review: branch places-address (City -> Area -> District, F4 grouping, F46 home address)

Reviewer: validator agent, 16 Nov 2026.
Scope: commits 7c62cc4..8714763 and the merge of main (7cea56e):
- the OSM places import: admin_level 5 to 10 and named neighbourhoods,
  coverage measured at run time, point-in-polygon assignment;
- `placeAreas`, `placeDistricts`, `placeIndex` and `placeRequests`, with
  their rules and the loader;
- the admin Places functions and screen;
- the Algolia area facet, `AppDropdownMenu`, and "By area" in the school
  picker;
- F46: `setHomeAddress`, `geocodeAddress` and `placeForPoint`, the
  3-step address screen, and the step 12 changes.

Owner decision respected: the per-school `areas` (carpools) are unchanged.
The branch touches no carpool code.

## Verdict: PASS (after the fixes below)

CI run 43762573196 (`full=false`) on 89a0054 is green:
- `flutter analyze`;
- `flutter test`;
- Cloud Functions unit tests;
- the emulator tests;
- the Firestore and Storage rules tests, including `places: reading`,
  `places: writing` and `addresses: the owner's only`;
- the schools import.

Screenshots and the web, admin and Android builds run only with
`full=true`. This review did not run them.

## Blockers (fixed on the branch)

- **B1. CI did not compile.** `place_repository.dart` used
  `firestoreProvider` without importing `features/auth/session.dart`.
  `flutter analyze` also flagged 5 infos, which fail CI: redundant
  arguments, parentheses, const literals and import order. Fixed in
  c559cc9 and 578184d.
- **B2. An accepted "district isn't listed" request made the district
  disappear from the parent's address.**
  - What happened: `resolveRequest` set `address.placeDistrictId` and
    cleared `districtText`, but did not copy the district's names. The
    parent's label and the address search use those names whenever the
    district ID is set, so the district was blank in both.
  - The same bug, in a milder form: renaming or merging an area or a
    district left the old names on parents' private addresses. Merges
    also wrote a stray `updatedAtMs` field instead of `updatedAt`.
  - Fix (578184d): `admin_store.ts` now copies the names on accept,
    rename and merge, and writes `updatedAt`.
- **B3. A pin from "Search instead" survived a change of City or Area.**
  After "Search instead", the parent could pick another city or area. The
  pin step still used the old search pin, so the saved pin and the chosen
  area did not match. Fix (578184d): picking a new City or Area drops a pin that
  came from the search, and the pin step searches again. An address the
  parent is editing still searches again whenever it changes, as before.
- **B4. Two widget tests failed, and the place lists hid the offline
  state.**
  - The dropdown test helper tapped menu items that were off screen (27
    cities at 320 dp, Arabic order). It now scrolls the item into view (232b983).
  - Riverpod 3 retries a failing provider by default. The new place
    providers (address, browse and admin Places) therefore stayed in
    "loading" while offline instead of showing the offline or error state
    with Retry. They now use `retry: _noRetry`, the repository's existing
    pattern (`wallet_screens.dart`), in 89a0054.

## Checked and OK

- **Rules.**
  - `placeAreas` and `placeDistricts`: signed-in users get and list them,
    at most 500 per list, and no client writes them.
  - `placeIndex` and `placeRequests`: closed to every client, including
    an admin's.
  - `homes/{uid}`: readable by its owner only, and the address lives
    there. `parentLocations`: closed.
  - Every new collection has emulator tests (`tests/rules/places.test.ts`),
    and they ran green in CI.
  - The app never writes places, addresses or the area of the public
    record. Only Cloud Functions write them, after checking that the area
    is an active area of that city and the district an active district of
    that area.
- **Exact pin and pickup sharing.**
  - `homes/{uid}` keeps the exact point, street and building.
  - `parentLocations` gains only `governorate`, `placeAreaId` and
    `placeDistrictId`, next to the existing rounded point.
  - `setPickupSharing` still copies the home point and label into
    `carpools/{id}/pickupPoints/{uid}`, which only approved members can
    read. The label now holds the building, street, district and area.
    That matches the spec: the exact address goes only inside the carpool,
    and only when the parent chooses.
  - `setHome` keeps its behaviour, so `setHomeLocation` and
    `searchNearbyParents` are unchanged. The map-only home screen is now
    reached only as "Search instead" (`pickOnly`), and it saves nothing.
- **Admin.** Every Places callable goes through `adminCall` (the admin
  claim) and writes an audit entry: create, rename, activate or
  deactivate, merge, move school, and request create, map or dismiss.
- **Logging and Sentry.** The functions log only the function name and
  `error.message`, never the request data. Algolia gets only the area's
  ID and names. The typed district text goes only to `homes/{uid}` and
  `placeRequests/{uid}`, never to Algolia or Sentry.
- **Maps cost.**
  - `geocodeAddress` runs once per address, when the parent reaches step
    3, not on every keystroke.
  - It makes one Autocomplete request and one Place Details request with
    the same session token. Place Details are cached (`placeCache`).
  - Both calls count against the existing per-parent limits.
  - `placeForPoint` counts against the address-search limit.
  - `docs/COSTS.md` is updated.
- **Account deletion and export.**
  - `placeRequests` is deleted with the account (by `uid`).
  - The address is inside `homes/{uid}`, which was already deleted and
    exported.
  - The export adds `placeRequests/{uid}`.
  - `placeAreas`, `placeDistricts` and `placeIndex` are listed as not
    personal.
- **UI.**
  - Dependent dropdowns: a new City clears the Area and District, and a
    new Area clears the District. Widget tests cover both.
  - The steps have a progress bar, and the fields are checked as the
    parent types, with how to fix the error. The client rules match the
    server regexes.
  - The pin step has loading (skeleton), error and offline states. The
    lists show loading, empty, error and offline.
  - Every new string exists in both ARB files (the key sets match).
    Labels are short, `AppDropdownMenu` items are `OneLineText`, and there
    are 320 dp one-line tests in Arabic and English.
  - The gallery has the new component.
- **No regression to carpool search.** Carpools, carpool search and the
  per-school `areas` are untouched. The Algolia `search` keeps its
  signature, plus an optional `areaId`.

## Coordinator follow-ups (resolved on the branch, commits fa10407, 416daa8 and 6362415)

- **N1. Outlines are server only (spec section 9).** Outlines, boxes, OSM
  level, source, address counts and admin fields moved from `placeAreas`
  and `placeDistricts` to a new collection, `placeInternal`, with document
  IDs `area_<id>` and `district_<id>`.
  - The rules deny every client read and write of it, including an
    admin's. `tests/rules/places.test.ts` covers this.
  - The app's documents now hold only names, IDs, parent IDs, centre,
    school count, `active` and `mergedInto` (the menus filter on the last
    two).
  - Point-in-polygon stays on the server. `FirestorePlaceLocator`,
    `rebuildIndex` and the loader read both documents.
  - Older documents still read: when `placeInternal` lacks a field, it is
    taken from the place document. The loader moves leftover fields to
    `placeInternal` once and deletes them from the place document. A
    unit test covers the merge and the fallback.
  - The loader's place batches are halved, because each write now
    touches two documents.
  - Spec section 9 and COSTS.md are updated. Lookups read about twice the
    documents (usually under 100).
- **N2. Address counts are admin only.**
  - `addressCount` is now only in `placeInternal`. The app sees only
    `schoolCount`, and the admin panel gets address counts through its
    functions.
  - These all update the internal count: an address change
    (`setHomeAddress`), an accepted "district isn't listed" request, and
    a merge (it moves the count and zeroes the merged place).
  - Account deletion has a new flow step, `places`, before the records
    step. In one transaction it takes the address out of its area's and
    district's counts and removes the address from the home, so a retry
    never counts twice. `NOT_DELETED` lists `placeInternal`.
- **N3. The pin must be in the chosen area.** `setHomeAddress` refuses a
  pin that is more than 300 m outside the chosen area's outline.
  - The check is `checkPinInArea`, using point-in-polygon and then the
    distance to the nearest edge.
  - An area without an outline accepts any pin. A pin outside Egypt still
    gets `outside-egypt`.
  - The error is `pin-outside-area`, with the area's Arabic and English
    names in the details.
  - The app keeps the parent on the pin step and says "The pin is outside
    {area}. Move it or change the area." (Arabic: «الدبوس خارج {area}.
    حرّكه أو غيّر المنطقة.»). It shows a "Change area" button that goes
    back to step 1. Moving the map clears the error.
  - Tests: functions tests (190 m outside is accepted, 480 m and another
    area are refused, no outline is accepted, distance), and a widget
    test for the message and "Change area".

## Notes (not blocking)

- **N4. Areas and districts that admins add have no centre, box or
  outline.** `placeForPoint` never finds them. For `geocodeAddress` the
  pin starts at the district's centre or Cairo, and it is marked
  "approximate". This works, but the admin form could take a pin.
- **N5. A shared pickup point is a copy.** If the parent changes the
  address, members keep the old pickup point and label until the parent
  shares it again. This is how it worked before this branch.
- **N6.** Screenshots, and with them the goldens of the new screens in
  Arabic and English, light and dark, are not generated by `full=false`.
  Run `gh workflow run checks.yml --ref places-address -f full=true`, or
  merge to main, to get them and the web, admin and Android compile.
