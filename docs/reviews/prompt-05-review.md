# Review: Prompt 5 (Home, schools and maps: F4, F21 to F24, F40)

Branch: `prompt-05-maps`, head `6a62d73` (includes `main` with Prompts 1
to 4B). Reviewed 13 Nov 2026 by the validator agent.

Scope: `git diff origin/main...HEAD` (63 files, +7111/-131). Checked against
CLAUDE.md (PRIVACY, SECURITY, COST MODE, DESIGN, TESTS), `docs/DESIGN.md`,
`docs/WORKFLOW.md`, `docs/spec.md` (F4, F21 to F24, F40, section 6 "Home
address" and "Map visibility", section 7 location control),
`docs/build-prompts.md` (Prompt 5 and its "Done when") and
`docs/progress/prompt-05.md`.

What I ran here: nothing that compiles. There is no Flutter SDK here. The
Dart, Functions and rules results below come from CI. The privacy findings
come from reading the code and working through each attack by hand.

## Verdict

**CHANGES NEEDED** (one blocking item, small fix).

The privacy design holds up. The exact home is in `homes/{uid}`, and only
its owner can read it. Only functions write it. `parentLocations` is closed
to every app user, including its owner. The only way to reach other parents
is `searchNearbyParents`, which:

- returns the rounded cell centre plus a fixed offset,
- rounds again before it answers,
- always searches from the caller's own rounded home,
- searches only the caller's own schools,
- needs the verified claim and a verified account,
- is limited per hour on the server.

Pickup points are readable only by approved members of the same carpool.
The rules tests seed the memberships for this, including a forged one and a
member who left. CI is green.

The blocking item: `placeDetails` has no per-user limit. This is the same
class of gap that blocked Prompt 4B for Algolia.

## CI

Run 43513076585 on `6a62d73`: **success**.

| Job | Result |
| --- | --- |
| Flutter analyze, tests and screenshots | success |
| Cloud Functions tests and rules tests (emulators) | success |
| Web, admin panel and Android compile (staging) | success (web, admin, Android APK) |

## Privacy probes (results)

| Attack | Result |
| --- | --- |
| Read `homes/{other}` | Denied by the rules. List is denied too, even for the owner. Admins are denied. The tests cover all of this. |
| Read or query `parentLocations` | Denied for everyone, including a geohash range query. Tested. |
| Callable responses | `searchNearby` returns `{id, firstName, schoolId, point}` only. `setHome` returns the caller's own rounded point. `placeDetails` returns Google's place point and nothing about any parent. None of them return another parent's exact coordinate. |
| Reverse the offset | Yes, it can be reversed. The offset comes from `sha256("map-jitter:"+uid)`, and both the uid and the code are known to the client. Reversing it gives back the cell centre and nothing more. Rounding is the real protection (see Non-blocking 1). |
| Triangulate from several positions, or by shrinking the radius | No. Distance and filtering use the caller's rounded centre against the target's rounded centre. Radii come from a fixed list. Home moves are limited to 4 a day. The most this can learn is the target's cell. |
| Geohash cell id leaks | No. The geohash is never returned, and it is computed from the rounded point. |
| Rounded point made on the client | No. `buildPublicLocation` calls `roundToGrid` on the server. The app sends its exact pin only to `setHomeLocation`. |
| Hide me | Respected in search (`showOnMap` in the query and in the filter) and in the new-parent event. Hidden parents can still search, as spec section 6 says. Tested. |
| Unverified, suspended or banned parents | Left out. The users trigger rebuilds the record when `status`, `banned` or `firstName` changes. When the user doc is deleted, the record is deleted too. |
| Rate limits | On the server, in a transaction, in `mapLimits/{uid}`, which the app cannot reach. Limits: home moves (4 a day; saving the same place again is not counted), searches (30 an hour), driving-school changes (10 a day), autocomplete (60 an hour). `placeDetails` has no limit (Blocking 1). |
| Keys | The Places key is a Secret Manager secret, used only in Functions. The iOS key comes from the environment into a generated `Maps.xcconfig`, with a check that it looks like a key. SETUP 15.2 restricts the iOS key to the bundle id. Nothing is committed. |
| Logs and Sentry | Only `error.message`, never request data. Places errors log the HTTP status only. |

## Blocking

1. **`placeDetails` has no per-user rate limit and does not check the
   account.** `functions/src/maps/callables.ts:115-119` only calls
   `requireUid`. Any signed-in account can call it again and again with
   different place IDs. That includes unverified and suspended accounts.
   Every cache miss is a billed Places Details call. SETUP 15.4 caps Places
   for the whole project at about 300 a day, so one account can use up that
   cap and stop address search for every parent. The brief asks for
   per-user Places limits, and Prompt 4B was blocked for the same gap with
   Algolia.

   Fix: call `takePlaceSearch(deps(), uid)` in `placeDetails`. It checks the
   account and takes from a limit. Use either the shared `placeSearches`
   counter or a new `placeDetails` kind with its own param, for example 20
   an hour. Taking from the limit only on a cache miss is fine. Add a unit
   test like "address searches are limited per hour"
   (`functions/test/maps.test.ts:527`) for details.

## Non-blocking

1. **The offset can be reversed.** `functions/src/maps/geo.ts:144-158`
   derives the offset from the uid with a public salt, and the uid is
   returned. A client can remove the offset and get the exact cell centre.
   That is no more than the rounding already reveals, and the comment says
   so. Rounding is still the only protection: a parent alone in a sparse
   cell (about 0.27 km²) is located to that cell. If you want the marker to
   reveal less than the cell, key the offset with a server secret. Either
   way, record the decision in the progress note.
2. **The radius ring is centred on the exact home, but the server measures
   from the rounded cell centre.** See `lib/features/maps/google_map_view.dart:25`
   and `lib/features/maps/map_view.dart:164` (`_ringCenter = camera.center`).
   A disc near the edge can sit outside the ring but still be listed, or
   the other way round. Centre the ring on the `approximate` point. Also,
   `_ringCenter` (late final) and `_camera ??=`
   (`nearby_parents_screen.dart:232`) do not follow a home change while the
   screen is open.
3. **F40: the nearby map shows the home pin but no school pin.** See
   `lib/features/maps/nearby_parents_screen.dart:331-333`. The acceptance
   says "the parent's map shows their home pin and their children's school
   pins". The school picker map already shows both. Add a
   `MapMarkerKind.school` pin for the selected school when it has a
   location.
4. **Sweep by driving schools.** A verified parent can choose up to 5
   driving schools, change them 10 times a day and move home 4 times a day.
   That lets them look at rounded points for about 50 schools a day within
   10 km of several places. Only rounded points are exposed, and this is
   already owner question 3. If the owner keeps driving schools on the map,
   consider a daily cap on distinct schools searched.
5. **Account deletion keeps `homes/{uid}` (the exact home).** This is noted
   as a gap. Deleting the user doc does remove `parentLocations` through the
   trigger. Make sure the privacy or deletion prompt deletes `homes`,
   `mapLimits` and `newParentEvents`.
6. **What the "never receives exact coordinates" test covers.** It is
   meaningful. It checks every number with 4 or more decimals in the
   response against each other parent's exact home. It checks that every
   public write is a cell centre. It checks the defence-in-depth rounding.
   But it runs the pure flow over an in-memory store. A later emulator test
   that calls `searchNearbyParents` through `FirestoreMapStore` would also
   cover the Firestore mapping (`publicFromDoc`).
7. **The one-line test does not cover the school chip.** In the 320 dp
   test, the nearby school chip (`nearby.schoolChip`, a data-length label)
   is not checked. Add it so a long school name is shown to ellipsize, not
   wrap.
8. **`LocationPermission.denied` reads as "not asked".** In
   `location_service.dart:56`, a parent who refused once sees the
   explanation screen again. That is acceptable on iOS, where a second
   refusal becomes `deniedForever`. Just noting it.

## Done-when coverage

| Item | Status |
| --- | --- |
| Set the home on the map (pin, Places search, "use my current location") | Built. The explanation screen comes first. geolocator gets one position while the app is in use. Widget-tested in CI. Not tried on an iPhone. |
| Child's school on the map | Built. The school picker has nearest first and a map with home and school pins. |
| Fake nearby parents as blurred markers | Built. The seed adds 8 fake parents, one of them hidden. The map draws two soft circles per parent, never pins. |
| Hide myself | Built. The switch is in Profile. The server filters hidden parents out. Tested. |
| Test: the app never receives exact coordinates | Present and meaningful (Functions), plus the rules tests. Green in CI. |
| Light and dark map | Built. `mapStyleJson` comes from tokens, and a test checks that light differs from dark. |
| New-parent event; limits on home moves and searches | Built and tested. The event holds the rounded point only. |

Owner check still to do: the iPhone run in the progress note, with a real
iOS maps key (SETUP 15). The iOS build with the GoogleMaps pod has not run
on Codemagic yet.

## Re-review (14 Nov 2026)

Head `3ca83cf`: fix commit `dfa3f33`, plus main docs merged in.

**Verdict: PASS.**

**CI:** run 43515712771 on `3ca83cf` passed all three jobs: Flutter analyze, tests and screenshots; Functions and rules tests; and the web, admin and Android builds.

**Blocking 1 is fixed.** `placeDetails` now calls `checkPlaceAccount`, which refuses missing, suspended and banned accounts. Unverified accounts are still allowed, so a parent can pick an address while registering. Before every cache miss it calls `takePlaceDetails`, which gives each parent 20 billed lookups an hour (`MAP_PLACE_DETAILS_PER_HOUR`). Unknown or made-up place IDs also count, because the limit is taken before Google is called. Cached places are free and are not counted. The new unit test (`functions/test/maps.test.ts`) covers:

- refused accounts,
- that cache hits are not counted,
- that misses are counted,
- that one parent's limit does not affect another parent.

**Non-blocking items:**

- **Item 1, the offset can be removed (accepted).** The decision is recorded in the progress note. Rounding stays the protection.
- **Item 2, the ring (fixed).** The ring is now centred on `Geo.roundToGrid(home)`. This matches the server's 0.005° grid and is used only for drawing. The map also follows a home saved while it is open.
- **Item 3, the school pin (fixed).** The nearby map shows the selected school's pin through `schoolPin`, which reads the `schools` collection under its existing rules.
- **Item 4, sweeping by driving schools (narrowed).** Changes are now 3 a day, with at most 5 schools. A cap on distinct schools searched waits for the owner's answer to question 3.
- **Item 5, deleting the exact home (deferred).** This moves to Prompt 12. The progress note lists `homes`, `mapLimits` and `newParentEvents` as records to delete.
- **Item 7, the school chip (fixed).** The one-line test now covers it.
- **Items 6 and 8:** unchanged and still non-blocking.

**Still to do:** the owner's iPhone check with a real iOS maps key (SETUP 15).
