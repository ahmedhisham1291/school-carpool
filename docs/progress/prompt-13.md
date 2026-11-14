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

## Scope added while building

- **Owner answers 13:29** (DECISIONS.md): transfer records 5 years (wording);
  closed-carpool trips kept per parent, active + 1 year (built); chat up to
  60 minutes after sign-out accepted (open-items C1).
- **Owner request 13:44** (DECISIONS.md): run recovery on iPhone with our
  own plugin and an optional "Always" step (built, below). This replaces the
  plan's "never ask for Always": the gate still never requires it.

## What was built

### Location on iPhone (F15)

- `lib/features/trips/geolocator_tracker.dart`: free geolocator tracker
  (bestForNavigation, automotiveNavigation, 15 m, no auto pause, background
  updates, blue indicator); on-phone buffer (1 day, 2,000 points, survives a
  restart), batches of 50 to `tripLocation`, 401/410 stop, 60 s heartbeat
  while still, listens again after a loss is fixed. Wired for iPhone and
  Android in `bootstrap.dart`. The paid plugin is removed everywhere
  (pubspec, patch_native, Codemagic, SETUP, COSTS, CLAUDE.md/AGENTS.md);
  DECISIONS says how to bring it back.
- `location_gate.dart`: driving gate (Location Services, While Using,
  Precise Location, notifications), system prompts first when never asked,
  then full-screen steps AR/EN with Open Settings, re-checked on resume and
  on Location Services changes, closes by itself; blocks driving only.
  Home banner "Location is off" (warning tone of `AppAlertBanner`, in the
  gallery) with the same steps, non-blocking. Wording note: the owner's
  one-line banner sentence did not fit 320 dp, so it is split into the title
  "Location is off" and the body "Needed on your driving day."
- Run screen: one-line hint "Keep the app open — you can lock the phone.";
  mid-run loss (service stream, tracker errors, re-check on resume) shows the
  steps at once and calls `reportTrackingLost`; fixed: tracking restarts
  with a fresh token.
- Server: `tripTick` sends parents "location stopped" and the driver the new
  `run-still-on` push after 2 minutes without a point, once per gap;
  `reportTrackingLost` callable; template `cp_run_still_on` (SETUP 20.3).
- **Run recovery** (owner 13:44): `packages/run_recovery` (our Swift plugin,
  path dependency, no third-party code): CLBackgroundActivitySession (iOS
  17+), CLServiceSession (iOS 18+), significant location changes with
  Always, launch-for-location flag; Android/web answer "unsupported" in
  Dart. `lib/features/trips/run_recovery.dart`: local run marker (uid,
  carpool, run, start; no coordinates), `decideRecovery` rule (none,
  signed out, other parent, older than 3 h, run ended, resume), resume on
  launch before the first frame (bootstrap now builds the ProviderContainer
  first and uses `UncontrolledProviderScope`), "Tracking resumed" local
  notification, marker cleared when tracking stops or on sign-out.
  Optional "Resume runs by itself" screen (once per install, iPhone, after
  While Using), analytics `always_location` (granted 0/1).
- Nothing in the app stops tracking on inactive/hidden/paused (audited:
  app lock, capture screen, offline queue, device guard, tracker guard;
  widget test added).
- Info.plist (patch_native): background modes `location` +
  `remote-notification` only; final AR/EN purpose texts for camera, photos,
  location while in use, Always (honest: optional, runs only), Face ID;
  Arabic development region; the paid plugin's keys are removed.

### Prompt 13 proper

- Codemagic `ios-staging` (already signed via `CodemagicASC`, TestFlight,
  main/tags/manual only); header updated; owner steps in
  `docs/testflight.md`.
- `docs/app-store-privacy.md` (moved from docs/privacy/, finalised):
  every Apple data type, who receives it, linked, tracking (no), purposes.
- Permission texts AR/EN in InfoPlist.strings and the gate/Always screens.
  The notification prompt still has no in-app explanation screen
  (open-items D5).
- `docs/app-review-notes.md`: reviewer notes (background location, Always
  optional, demo account, review code), owner recording steps.
- Review sign-in: one allow-listed test phone with a fixed code
  (`config/reviewAccess`, keyed hashes, at most 30 days, off by default,
  every limit still applies, fails closed), script `npm run review-access`.
- Admin panel: user page card "New phone check open" > Compare and decide
  (reference photo and latest selfie, logged reason, outcome approved or
  confirmed another way, confirm dialog); server `adminDecideDeviceCheck`.
- Trips per parent (`trip_retention.ts`), transfer records 5 years.
- `docs/test-iphone.md` (F1 to F44, location gate L1-L8, lock/call/app
  switch/swipe-away with and without Always, Low Power Mode, battery) and
  `docs/open-items.md`.

### Design pass (bounded)

- Scanned every screen under lib/features and lib/admin for hard-coded
  sizes, colours, radii, paddings and non-tokenised text: none found.
- New screens use tokens, one primary action, `AppBarTitle`/`OneLineText`
  for one-line titles, skeleton loading, AR/EN, light/dark.
- Fixed: Home's stale "Today's trips will appear here" placeholder is now a
  "Today's runs" row to the carpools; the location banner's wording split
  so it fits 320 dp.
- Not done (needs the rendered screenshots, which CI produces): a visual
  check of every screen in AR/EN light/dark at 320 dp and 200 % text;
  a pre-permission screen for notifications (D5).

## Tests

- Functions: **run here: 632 pass, 0 fail** (after the review round) (`node --test` with the
  workspace's type stubs; `tsc` shows only the known stub noise, no new
  errors). New: run-still-on and reportTrackingLost (trips), review
  sign-in (otp_flow), trip retention and the admin device decision
  (privacy).
- Flutter: **written, not run here** (no Flutter SDK):
  `test/trips/geolocator_tracker_test.dart` (fake geolocator source),
  `location_gate_test.dart`, `run_recovery_test.dart` (rule, service,
  launcher, plugin channel with a fake platform), `always_location_test.dart`,
  driver screen tests rewritten for the gate, mid-run loss and lifecycle,
  admin device check test, notification kinds and routes; goldens
  `trips_gate_*`, `trips_always_*`, `home_location_banner_*`,
  `home_location_steps_*` (AR/EN, light/dark; rendered only with
  `--update-goldens` in CI). `flutter analyze` not run here.
- Rules: no rules change in Prompt 13 (`config/` is already deny-all).
- Swift (`packages/run_recovery`, the patched AppDelegate): **not compiled
  here**; compiles in the Codemagic iOS build only.
- Python: `python3 -m unittest discover -s tool -p 'test_*.py'`: **9 pass**
  (run here).

## Only verifiable on a real iPhone

- Tracking with the phone locked, other apps and calls (T1-T4).
- That iOS relaunches the app after a swipe away with Always, how soon
  (iOS decides; usually after about 500 m of movement), and that a
  background-relaunched app gets enough time to sign in, call the server
  and restart tracking (T6). Apple documents that significant-change
  relaunch can be suppressed after a user force-quit on some iOS versions,
  and never happens with Location Services or Background App Refresh off;
  the 2-minute server push stays the fallback (T5).
- The first location prompt shows "While Using" (L2); the Always upgrade
  prompt appears once from the optional screen.
- Low Power Mode and battery (T8, T10).

## Review round (docs/reviews/prompt-13.md, FAIL with 2 blockers)

| Finding | Fix |
| --- | --- |
| Blocker 1: `AuthorizationStatus.deniedPermanently` missing (compile error) | `FcmNotificationStatus.fromFcm` lists every value of firebase_messaging 17; unit test over all values. The other switches over package enums (`LocationPermission`) were already exhaustive. |
| Blocker 2: UIScene template, no Dart on a background relaunch | `tool/patch_native.py` `patch_ios_launch`: classic AppDelegate (FlutterAppDelegate) that starts its FlutterEngine (Dart `main`) and registers the plugins in `didFinishLaunchingWithOptions`, builds the window; no scene manifest, no main storyboard key, SceneDelegate.swift emptied; idempotent, runs before the Maps/alerts patches. Python tests: scene template -> classic, old classic -> explicit engine, already patched -> unchanged, later patches still apply (9 pass). The run_recovery plugin (FlutterApplicationLifeCycleDelegate) reads the real launch options and exposes `launchedForLocation`. **Must be verified on a real iPhone (T6)**; revisit when Apple requires UIScene (DECISIONS). |
| 1 Mid-run steps required notifications | Location-only blocking steps during a run; closing them after fixing location restarts tracking. Tests. |
| 2, 3 Trip retention too early; orphan starvation | `keptUntilMs` (closure + 1 year) stored when a parent is anonymised; trips kept until then; the orphan query reads only due trips (new index); passed values cleared. Tests (632 functions tests pass). |
| 4 Always prompt could spin 30 s | Answered when the app becomes active after the prompt ("Keep Only While Using"), 10 s fallback, per-request timers. |
| 5 Admin photos opened with a default reason | Reason first, then "Show photos" (one logged access); reason locked afterwards. |
| 6 Stream receives the account ID | docs/app-store-privacy.md fixed. |
| 7 No driver push after a reported loss | Recorded (open-items D9). |
| 8 Stale text | SETUP 20.4/20.6 and the listed comments fixed. |
| 9 Buffer | Trim-during-flush bug fixed (points removed by identity); storage location recorded (D9b). |
| 10 Review code window | Docs keep 14 days. |
| 11 No Package.swift | Recorded (D9c). |
| 12 Rules tests | `config/reviewAccess` added to the server-only list (written, not run here). |
| 13 tsc stub noise | 157 lines here, same as the branch start; real types in CI. |

Wording is honest everywhere: with "Always" the run **usually resumes within
a few minutes after the car moves; to be confirmed on the device** (Always
screen, purpose strings, App Review notes, T6, SETUP).

## Not done

- Everything in docs/open-items.md section D (D3b: recovery reliability).
- Android background tracking (foreground service) and recovery: Stage 3.
- Screenshots of the new screens: next full CI screenshots run.
