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

## Notes (not blocking)

- **N1. Spec deviation: outlines can be read by the app.** The spec's data
  model says an area outline is "simplified, server only". The `rings` are
  stored on the `placeAreas` and `placeDistricts` documents themselves,
  which any signed-in user can list.
  - This is public OpenStreetMap geometry, so it is not a privacy issue.
  - But each City -> Area menu downloads every area's outline: perhaps
    5 to 15 KB per area after the 30 m simplification, so several hundred
    KB for Cairo. That costs time on mobile data and Firestore network
    traffic.
  - Recommended follow-up: move `rings` to a server-only collection
    (`placeShapes/{id}`, closed in the rules), read by
    `FirestorePlaceLocator` and the loader. Otherwise, the owner can amend
    the spec.
- **N2. `addressCount` drifts and is visible.**
  - Deleting an account does not decrement the counts of its area and
    district.
  - The count can be read by every signed-in user. A district showing 1
    tells others that one parent lives there.
  - Possible fixes: decrement the counts in `account_deletion`, and keep
    the counts in an admin-only field or collection.
- **N3. The server does not check that the pin is inside the chosen
  area.** `setHomeAddress` accepts any pin in Egypt with any valid area.
  OSM boundaries are imperfect, so a strict check could refuse real
  homes. A loose check (within a few km of the area) would keep
  `parentLocations.placeAreaId` honest for carpool matching.
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
