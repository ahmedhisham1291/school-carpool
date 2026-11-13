# Prompt 5: Home, schools and maps (F4, F21 to F24, F40) — progress note

Branch: `prompt-05-maps` (from `prompt-04b-schools`, which includes `main`
with Prompts 1 to 4 and the design refresh). Date: 13 Nov 2026. The
coordinator gave "go" on the owner's behalf.

**Status: code complete. The Functions unit tests were run here (222
pass); the Flutter code, the widget tests and the rules tests were not
compiled or run** (no Flutter SDK or package registry in this workspace).
Expect small analyzer fixes on the first CI run.

## Plan that was followed

1. Functions (pure flows + Firestore store + callables): home rounded to
   about 500 m, private exact home, public rounded record, nearby search,
   settings, driving schools, Places proxy with cache, rate limits,
   "new parent nearby" event, triggers on users and children.
2. Rules for homes, parentLocations, events, limits, cache, memberships
   and carpool pickup points, with emulator tests.
3. App: map view (Google Maps styled from tokens; a sketch for tests and
   keyless dev builds), home picker, location explanation screen, nearby
   parents map and parent card, driving schools, map settings, Home tab,
   school picker nearest first and on a map. AR/EN strings, gallery.
4. Native key handling (bootstrap/patch_native, Codemagic), seed data,
   SETUP section 15, COSTS, DESIGN, tests and screenshots.

## Privacy design (the "Done when" test)

| Record | Holds | Who reads it |
| --- | --- | --- |
| `homes/{uid}` | EXACT home, address text, map settings, driving schools | The owner only (rules). Written only by functions |
| `parentLocations/{uid}` | Centre of the 0.005° grid cell (about 555 m north-south, 480 m east-west in Cairo), geohash of that rounded point, first name, verified, schools, settings | Cloud Functions only. The app never reads it, not even the owner's |
| `carpools/{id}/pickupPoints/{uid}` | EXACT pickup point a parent chooses to share with one carpool (written in Prompt 6) | The owner, and verified parents who are approved members of that carpool while the owner is too (`memberships/{carpoolId}_{uid}`, status `approved`, fields checked against the ID) |
| `newParentEvents/{uid}`, `mapLimits/{uid}`, `placeCache/{id}`, `memberships/{id}` | Event (rounded point), counters, cached addresses, memberships | Cloud Functions only |

- Other parents reach the app only through `searchNearbyParents`, which
  returns `{id, firstName, schoolId, point}` where `point` is the rounded
  cell centre plus a fixed offset of at most 150 m that stays inside the
  cell. It rounds again before answering (defence in depth).
- The search centre is always the caller's own home (no centre in the
  request), the school must be one of the caller's (approved children or
  driving schools), searches are limited to 30 an hour, home moves to 4 a
  day and driving-school changes to 3 a day (at most 5 driving schools):
  nobody can sweep the map.
- Hidden, unverified and suspended parents never appear; hidden parents can
  still search (spec section 6).
- On the map other parents are two soft discs, never pins; the card shows
  first name, Verified badge and school only.
- Logs and Sentry never get coordinates, addresses or search text.

Proof: `functions/test/maps.test.ts` ("the app never receives another
parent's exact coordinates": no exact number of any other parent appears in
the answer; every public record ever written is a cell centre; rounding
again if a record held an exact point) and `tests/rules/maps.test.ts`
(homes owner-only, parentLocations closed to everyone, pickup points only
for approved members of the same carpool, with seeded memberships).

## Decisions

1. **Nearby search through a function, not direct Firestore reads.**
   Server-side rate limits and the "own home is the centre" rule need it,
   and the rounded records stay closed to the app.
2. **Rounding: snap to a 0.005° grid**, store the cell centre and a
   precision-7 geohash of it. Range queries cover the circle with at most
   9 geohash prefixes (finest precision that fits), then a distance check.
3. **Places through Cloud Functions** (`placesAutocomplete`,
   `placeDetails`): the Places key stays in Secret Manager, searches are
   rate limited per parent, details are cached 30 days in `placeCache`
   (TTL). Places API (New) with a session token per search, 3 letters,
   400 ms pause, field mask `id,formattedAddress,location`. Fake provider
   (`PLACES_PROVIDER=fake`) in dev and CI.
4. **New dependency `google_maps_flutter` (^2.17.0)**, the official Flutter
   plugin (Google Maps SDK on iPhone via CocoaPods, Android, and Maps
   JavaScript through the endorsed web package, so the website keeps
   compiling). The iPhone key is written by `tool/patch_native.py` from
   `MAPS_API_KEY_IOS` into `ios/Flutter/Maps.xcconfig` (generated, not
   committed), read through `Info.plist` `GMSApiKey` by `AppDelegate`.
   `MAPS_ENABLED=true` tells the app a key exists; without it dev shows a
   sketch map ("Preview") and staging/prod "Map unavailable". Nothing
   crashes without a key.
5. **New dependency `geolocator` (^14.0.2)** for "use my current location":
   one position, "while using the app" only, no background mode. The
   stack's flutter_background_geolocation is a paid, background tracking
   engine reserved for live runs (Prompt 13, "running only while a run is
   on"); using it for one tap would start its service and tie the home
   picker to its license. geolocator is free (MIT), Java/Swift (no Kotlin
   fix needed), and needs only the location permission text that is
   already in Info.plist. Our explanation screen comes before the system
   prompt; "refused for good" opens Settings.
6. **Map style from tokens** (`mapStyleJson`): land on the page color,
   roads on the raised surface, water in the accent wash, businesses and
   transit hidden. Follows light and dark.
7. **Driving schools (F24) feed search and alerts:** a parent's map
   schools are their approved children's schools plus their driving
   schools; parents with a driving school appear on that school's map too.
8. **New-parent event (F23):** `newParentEvents/{uid}`, created once when a
   parent is verified, has a home and a school and is shown on the map
   (rounded point, first name, schools, `status: pending`). Created from
   the users/children triggers and from every map call. Prompt 8 sends it
   and must re-check verified, shown and each receiver's radius and
   alerts setting.
9. **Home tab** now leads to Parents nearby, Home location and Driving
   schools (trips come later). Profile has Home location and Driving
   schools rows and the Map settings switches.
10. **`AppSwitchRow`** added to the design system and the gallery (with a
    sketch map sample).

## Screens and states

| Screen | Layout | Loading | Empty | Error | Offline |
| --- | --- | --- | --- | --- | --- |
| Home location | Address field; map with a fixed centre pin and a "my location" button; privacy note; "Save home" | Skeleton field, map and card | No home: Cairo, "Move the map..." hint | Error view + retry; save errors inline above the button | Offline view + retry; inline on save |
| Your location (explanation) | Icon, heading, why, "Continue"/"Open Settings", "Not now" | n/a (static) | n/a | n/a | n/a |
| Parents nearby | School and distance chips; map with home pin, radius ring and blurred discs; count; list toggle; card sheet | Skeleton; progress bar while searching | No home (set home), no school (add school), nobody nearby (widen distance) | Error view + retry; "too many tries" note | Offline view + retry |
| Driving schools | Intro; children's schools; other schools with remove; "Add school" (picker) | Skeleton rows | "No other schools yet." | Error view + retry; snackbar on save | Offline view + retry; snackbar |
| Map settings (Profile) | "Show me on the map", "New parent alerts" switches | Switches disabled | n/a | Switch goes back + snackbar | Same |
| School picker (changed) | "Nearest to your home" before typing; map toggle with school pins and "Choose school" | as before | as before | as before | as before |

## Data model and functions

| Where | Change |
| --- | --- |
| `homes/{uid}` | New (owner-readable): `location` (exact GeoPoint or null), `label`, `showOnMap`, `notifyNewParents`, `radiusKm`, `drivingSchools[{id,nameAr,nameEn}]`, `updatedAt` |
| `parentLocations/{uid}` | Reshaped (functions only): `point` (rounded), `geohash`, `firstName`, `verified`, `showOnMap`, `notifyNewParents`, `radiusKm`, `schoolIds`, `childSchoolIds`, `drivingSchoolIds`, `announced`, `updatedAt`. Index: `schoolIds` CONTAINS, `showOnMap`, `verified`, `geohash` |
| `newParentEvents/{uid}`, `mapLimits/{uid}`, `placeCache/{lang_placeId}` | New, functions only (`placeCache.expiresAt` is a TTL field) |
| `memberships/{carpoolId}_{uid}`, `carpools/{id}/pickupPoints/{uid}` | Rule shape now; written in Prompt 6 |
| Functions | `setHomeLocation`, `updateMapSettings`, `setDrivingSchools`, `searchNearbyParents`, `placesAutocomplete`, `placeDetails`, triggers `syncMapOnUserWrite`, `syncMapOnChildWrite`; params `PLACES_PROVIDER`, `MAP_*` limits; secret `MAPS_SERVER_KEY` |
| `schools` | The app now reads `location` (Firestore) / `_geoloc` (Algolia) for nearest first and the school map |

## How to test it on the iPhone (the "Done when" check)

1. Owner setup: SETUP section 15 (iOS maps key for the dev project in
   Codemagic `dev_defines` as `MAPS_API_KEY_IOS`, or locally
   `MAPS_API_KEY_IOS=<key> FLAVOR=dev tool/bootstrap.sh` and
   `flutter run -t lib/main_dev.dart --dart-define=MAPS_ENABLED=true --dart-define=EMULATOR_HOST=<Mac IP>`).
2. `firebase emulators:start --project demo-school-carpool`, then
   `npm --prefix functions run seed:emulator` (adds 8 fake verified parents
   around Maadi at "Nile International School (test)").
3. Sign up, add a child at "Nile International School (test)", submit, and
   approve the case (admin panel or `npm --prefix functions run
   review:emulator`).
4. Profile > **Home location**: search "Maadi" (fake places) or tap the
   location button (explanation first, then the iPhone prompt), or move the
   map; **Save home**.
5. Profile > Children: the child's school; Profile > **Driving schools**:
   add another school (search, or the map toggle with "Nearest to your
   home").
6. Home > **Parents nearby**: blurred discs around you (most of the 8 fake
   parents are within 3 km; one hides; try 5 km). Tap a disc: first name, Verified,
   school, Join and Message ("coming soon"). Change the distance with the
   slider; switch to the list.
7. Profile > Settings > **Show me on the map** off: the screen says you are
   hidden; a second fake parent no longer sees you.
8. Switch the iPhone to dark mode: the map follows.

## Tests

| Test | Status |
| --- | --- |
| `functions/test/maps.test.ts`: rounding (same cell, within one cell, cell size ~500 m), geohash reference values and cell sizes, cover prefixes (≤ 9, random points covered for every radius), offsets (fixed, ≤ 150 m, inside the cell), limits, home (exact private, rounded public, outside Egypt, moves limited, suspended), **nearby never returns an exact coordinate**, defence-in-depth rounding, filters (hidden, unverified, other school, far, self), order and fields, verified claim, own home and own schools only, radius list and hourly limit, ≤ 9 queries, settings, hidden parents still search, driving schools (active only, max 5, open that school's map, daily limit), new-parent event (once, rounded, not when hidden or without school), suspended leave the map, trigger filters, Places (input, fake AR/EN, cache and 30-day expiry, outside Egypt, Places API New request shape), address search limit | **Run here: pass** (36 tests) |
| All Functions unit tests | **Run here: 222 pass** (Node 22, `tsc` against stand-in type stubs as in earlier prompts) |
| `tests/rules/maps.test.ts` + `deny_all.test.ts` paths | Written, not run here (CI); type-checked against a stub |
| `test/maps/maps_logic_test.dart`: map style JSON from tokens (light ≠ dark), home parsing, failures, session tokens, distance, my schools, school pins from Firestore/Algolia, nearest first, Algolia geo query | Written, not run here |
| `test/maps/maps_screens_test.dart`: home picker (pan and save, debounced search with one session token, location explanation before the prompt, "Not now", Settings when refused, rate limit, error and offline), nearby (discs only, card, Join/Message, list, radius slider saved, approved schools only, no home, empty, limited, offline, hidden note), settings switches (save, revert on failure), driving schools (add from picker, remove), picker nearest first and map pick, **one line at 320 dp AR/EN** for every new label | Written, not run here (sketch map, fake repositories) |
| Router test updated (Home tab is HomeScreen) | Written, not run here |
| Screenshots `maps_nearby`, `maps_home_location`, `maps_driving_schools` (AR/EN, light/dark) | Written, not run here (CI artifact) |
| `tool/patch_native.py` on a fake generated tree (AppDelegate template, xcconfig, manifest, index.html, run twice) | **Run here: correct output** |

## Learned from earlier reviews

- No literal bidi marks; one-line test for every new label at 320 dp.
- Private named initializing formals (`MapCameraController({required this._center})`).
- Fakes plugged into `authOverrides`, so every test has the same override
  count; fresh `ProviderScope` (pump a `SizedBox`) before a different set.
- Rules tests use `as const` for literal claims.
- No new Kotlin-only plugin (google_maps_flutter_android and
  geolocator_android are Java): `KOTLIN_FIX_PLUGINS` unchanged.

## Review fixes (docs/reviews/prompt-05-review.md)

- **Blocking 1 fixed:** `placeDetails` refuses missing, suspended and
  banned accounts (unverified parents may still pick an address while
  registering) and takes from its own hourly limit, 20 per parent
  (`MAP_PLACE_DETAILS_PER_HOUR`), only on a cache miss (the billed call),
  on top of the project's daily Places cap. Unit test added.
- The radius ring is centred on the rounded home (the client rounds with
  the server's grid, `Geo.roundToGrid`), where the server measures from;
  the map follows a home saved while it is open.
- F40: the nearby map shows the selected school's pin
  (`MapRepository.schoolPin`).
- Driving-school changes lowered from 10 to 3 a day (still at most 5
  schools); a daily cap on distinct schools searched is left for the
  owner's answer to question 3.
- The marker offset is derived from the uid and can be removed by a
  client; it reveals nothing beyond the rounded cell, and rounding stays
  the protection (decision recorded; a secret-keyed offset can come later
  if the owner wants markers to reveal less than the cell).
- One-line test covers the school chip (ellipsis allowed for a long
  school name, never a wrap).
- **Account deletion (Prompt 12, retention/privacy):** must delete
  `homes/{uid}` (exact home), `mapLimits/{uid}` and `newParentEvents/{uid}`;
  `parentLocations/{uid}` already goes when the user record is deleted
  (trigger).

## Open questions for the owner

1. **Keys:** create the iOS maps key and the server Places key per project
   (SETUP 15.2). Until then dev shows the sketch map and fake places.
2. **Limits:** 4 home moves a day, 30 nearby searches an hour, 60 address
   searches and 20 new address picks an hour, 3 driving-school changes a
   day. OK?
3. **Driving schools on the map:** parents appear on the map of each school
   they can drive to (not only their children's). OK, or children's
   schools only?
4. **Radius list** 1, 2, 3, 5, 10 km (default 3). OK?
5. **Alerts for hidden parents:** a parent hidden from the map is not
   announced to others when verified. OK?

## Not done / known gaps

- Sending the "new parent nearby" alerts (Prompt 8).
- Writing pickup points and memberships (Prompt 6); Join and Message are
  placeholders (Prompts 6 and 9).
- Website and Android maps platform work (Stage 2 and 3): the web build
  compiles but has no key; Android has the manifest key slot and location
  permissions.
- Areas per school stay admin-only (used by carpools in Prompt 6).
- The admin panel still takes typed pins (map there is an owner decision).
- Account deletion does not yet remove `homes` / `parentLocations` (comes
  with the privacy screen).
- Not verified here: `flutter analyze`, `flutter test`, the iOS build with
  the GoogleMaps pod next to the Swift Package Manager plugins, the rules
  tests.
