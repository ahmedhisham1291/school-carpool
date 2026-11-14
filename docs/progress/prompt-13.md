# Prompt 13: iPhone test release

Branch `prompt-13-testflight` (from main at `8016da5`, Prompt 12 merged).
The coordinator said "go" for the owner; plan and open questions are
recorded here first, then built. Inputs: docs/build-prompts.md "Prompt 13",
spec section 12 Phase 5, docs/DECISIONS.md "Location tracking on iPhone"
(14 Nov 13:05), docs/progress/prompt-13-inputs.md, the Prompt 12 progress
note and review (open items).

## Plan

### A. Free location tracking on iPhone (owner decision)

| # | Task | Files |
| --- | --- | --- |
| A1 | `GeolocatorTracker` behind `LocationTracker`: geolocator position stream with `AppleSettings` (bestForNavigation, automotiveNavigation, distanceFilter 15, pauseLocationUpdatesAutomatically false, allowBackgroundLocationUpdates true, showBackgroundLocationIndicator true). The plugin used to upload by itself; now the tracker keeps an on-phone buffer (shared_preferences, at most 1 day and 2,000 points) and posts batches to the same `tripLocation` function with the run's token (same body shape the server already parses). 401/410 stop tracking. A 60 s heartbeat fix while the car stands still (distanceFilter sends nothing then). Wired for iPhone and Android in `bootstrap.dart`. `requestAlways` removed from the interface: "While Using" is enough now. | `lib/features/trips/geolocator_tracker.dart` (new), `location_tracker.dart`, `bootstrap.dart`; `background_location_tracker.dart` removed |
| A1 | Remove flutter_background_geolocation: pubspec, `patch_native.py` (licence, BGTask id, static linkage, Android manifest), Codemagic comments, SETUP 20.5, COSTS, CLAUDE.md STACK and COST MODE lines; DECISIONS note how to bring it back. | as listed |
| A2 | Driver location gate: `DrivingReadiness` interface (service, permission, precise, notifications; request when not asked; open Settings; service stream) with a geolocator + FCM implementation and a fake. Full-screen blocking sheet `LocationGateSheet` listing only the missing items with numbered steps, one primary "Open Settings", re-check on resume, closes by itself when all pass. Shown when the driver taps Start run (the old "Always" step is gone). Never asks for "Always". | `lib/features/trips/location_gate.dart` (new), `driver_trip_screen.dart` |
| A3 | Home banner for every parent when location is off, refused or approximate: one line "Location is off — needed on your driving day", opens the same steps (non-blocking). | `home_screen.dart`, `location_gate.dart` |
| A4 | Mid-run monitoring on the run screen: service status stream and a re-check on resume; on loss, the blocking steps at once and `reportTrackingLost` to the server (parents get "location stopped", once per gap). | `driver_trip_screen.dart`, `trip_repository.dart`, `functions/src/trips/flow.ts`, `callables.ts` |
| A5 | Server: during an active run, no point for 2 minutes: the existing "location stopped" goes to the parents and a new `run-still-on` push goes to the driver ("Run still on — open the app to continue"), once per gap (`staleAlertedAtMs`, cleared by the next point). Same 1-minute `tripTick` (minInstances 0). Functions tests. | `functions/src/trips/flow.ts`, `notifications/catalog.ts`, `texts.ts`, app `notification_models.dart`, labels, ARB |
| A6 | Run screen hint (one line): "Keep the app open — you can lock the phone." | `driver_trip_screen.dart`, ARB |
| A7 | iOS native via `patch_native.py`: UIBackgroundModes location + remote-notification (fetch/processing and the Transistor BGTask id removed), all purpose strings (camera, photos, location when in use, always-and-when-in-use (required key, never requested), Face ID), localized `ar.lproj`/`en.lproj` `InfoPlist.strings`, Arabic development region (already set). `NSMotionUsageDescription` removed (only the paid plugin used motion). | `tool/patch_native.py`, `tool/ios/*.lproj` |
| A | Tests: tracker unit tests with a fake geolocator source (settings, buffer, upload, 410, heartbeat, offline); gate logic; widget tests and goldens (AR/EN, light/dark) for the gate sheet and the banner; driver-screen tests rewritten for the gate. | `test/trips/*` |

### B. Prompt 13 proper

| Task | Files |
| --- | --- |
| Codemagic `ios-staging`: signed IPA to TestFlight via the App Store Connect key integration; push to main, tags and manual only; no BG_GEO_LICENSE. Owner steps in docs/testflight.md (where each secret goes, in Codemagic's UI only). | `codemagic.yaml`, `docs/testflight.md` |
| App Store privacy answers from the code (analytics events, location, chat, photos, Sentry, Stream, Algolia, Valify, wallet partner). | `docs/app-store-privacy.md` |
| Permission texts AR/EN (location, camera, photos, notifications, Face ID): InfoPlist.strings and the in-app explanation screens that exist. | `tool/ios/*.lproj`, ARB |
| Reviewer notes + review-only sign-in code: one allow-listed test phone and a fixed code, from server settings (`reviewAccess`), off by default, never in dev logs; hashed phone in settings; tests. Owner recording steps. | `docs/app-review-notes.md`, `functions/src/auth/*`, tests |
| Admin panel: clear or approve a pending new-phone selfie check with a logged reason (flow function + tests; button on the user page). | `functions/src/privacy/devices.ts`, `callables.ts`, `admin_panel/users.ts`, `lib/admin/...`, tests |
| Design pass (bounded): every screen against DESIGN.md and the one-line rule; fix what is found, list the rest. | various |
| `docs/test-iphone.md`: F1 to F44 test script for two accounts, incl. location gate, lock screen, Low Power Mode, swipe-away. | new |
| `docs/open-items.md`: every open item, known bug and missing account. | new |

## Data model changes

- `trips/{id}`: no new fields. `staleAlertedAtMs` also marks a reported
  tracking loss (once per gap).
- Notification type `run-still-on` (driver only, push, WhatsApp group
  `tripAlerts`, template `cp_run_still_on`, push-only by COST MODE unless the
  parent switches WhatsApp on), same position in the app and server lists.
- `settings/auth` (server settings): `reviewAccess { enabled, phoneHash,
  codeHash, expiresAt }`, off when missing.
- On the phone: shared_preferences keys for the live session and the point
  buffer (trip id, upload URL, token, points; cleared at the end of a run).

## New screens (states)

- **Location gate sheet** (full screen, blocking for driving only): title,
  one line per missing item with an icon and numbered steps; one primary
  "Open Settings"; a close button returns to the run screen without
  starting. Loading: skeleton rows while the first check runs. Empty: never
  shown (it closes when nothing is missing). Error: a check that throws counts
  as "missing" with the generic steps. Offline: not relevant (local checks
  only); the run start itself has its own offline state.
- **Home banner**: one-line title, short body, "Show steps"; hidden while
  loading, when ready, on error and offline (never blocks).

## Open questions (built with the stated default; owner may change)

1. geolocator's iOS `requestPermission` must show "While Using the App"; the
   always key is in Info.plist because Apple requires it when the code
   links the "Always" API. We only call it when the status is not
   determined. Check in the test script (step L2) that the prompt shows
   "Allow While Using App"; if iOS shows an "Always" upgrade prompt, tell me.
2. Without the paid plugin, iOS stops location if the driver swipes the
   app away. The server then pushes "Run still on" after 2 minutes. Accepted
   by the owner's decision; the test script measures it.
3. Review-only sign-in code: on in staging for App Review, off in prod
   until submission. Default: off everywhere; the owner switches it on with
   a script.
4. Android: the geolocator tracker runs on Android too, but background
   tracking there needs a foreground-service notification (Stage 3).

## Status

Building. This section is replaced at the end with what was built.
