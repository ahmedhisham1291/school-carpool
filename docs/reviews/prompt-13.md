# Review: Prompt 13 (iPhone test release)

Branch `prompt-13-testflight`, head `28dfc15` (26 commits on top of main).
Compared with `git diff main...HEAD` (84 files, +5,511 / -622). Read
against CLAUDE.md, docs/build-prompts.md Prompt 13, docs/DECISIONS.md
(13:05, 13:29, 13:44), docs/progress/prompt-13.md and prompt-13-inputs.md.

CI could not run (GitHub Actions minutes are used up) and this workspace has
no Flutter SDK. So the Dart, Swift and native work was reviewed **by
reading the code**. Upstream sources were checked where it mattered:
geolocator 14.1.2 / geolocator_apple 2.4.3, FlutterFire firebase_messaging
17.0.x, Riverpod 3.5, and the Flutter master app template and iOS engine
(14 Nov 2026).

## Verdict: FAIL

There are 2 blockers. Blocker 1 is a compile error, so no build can pass:
not iOS, Android, web or `flutter test`. Blocker 2 means the owner's
13:44 run-recovery request does not work as built and documented on the
iOS app template that `flutter create` now generates. The rest of the
branch is in good shape: the Functions tests pass, the security design of
the review code and the admin decision is sound, and no paid plugin is
left.

## Blockers

1. **`lib/features/trips/location_gate.dart:164-168`: the switch is not
   exhaustive, so the app does not compile.**
   - `FcmNotificationStatus.status()` switches over
     `fcm.AuthorizationStatus` with only these cases: `authorized`,
     `provisional`, `notDetermined` and `denied`.
   - Since FlutterFire #18101 (19 Aug 2026), the enum also has
     `deniedPermanently`. firebase_messaging 17.0.0 (BoM 5.0.0,
     15 Oct 2026) already ships it, and the pubspec pins `^17.0.0`.
   - A switch *expression* that misses a case is a compile error. This file
     is imported by `bootstrap.dart`, `home_screen.dart`,
     `driver_trip_screen.dart` and many tests, so every build and test run
     fails.
   - Fix:
     `fcm.AuthorizationStatus.denied || fcm.AuthorizationStatus.deniedPermanently => NotificationAccess.denied`.
   - Add a unit test of the mapping. For example, move the switch into a
     pure `static NotificationAccess fromFcm(fcm.AuthorizationStatus)` and
     test every enum value.

2. **Run recovery after iOS closes the app cannot work with the current
   Flutter app template (UIScene).**
   - Files: `packages/run_recovery/ios/Classes/RunRecoveryPlugin.swift:42-50`
     and `lib/bootstrap.dart:64-66`. The docs promise the behaviour:
     `docs/app-review-notes.md` section 1 "Always is optional", the
     `NSLocationAlwaysAndWhenInUseUsageDescription` texts in
     `tool/patch_native.py` and `tool/ios/*.lproj`, DECISIONS 13:44, and
     test-iphone T6.
   - `flutter create` (run by `tool/bootstrap.sh` in CI) now generates a
     scene-based app.
     - Template: `AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate`,
       plus `SceneDelegate: FlutterSceneDelegate`.
     - Plugins are registered in `didInitializeImplicitFlutterEngine`. That
       runs only when the storyboard's `FlutterViewController` is created,
       which happens when a scene connects.
   - When iOS relaunches the app in the background for a significant
     location change, **no scene connects**. So:
     - No engine is created, Dart `main()` never runs, and
       `runRecoveryLauncherProvider` never runs either.
     - The plugin is not registered, so its `didFinishLaunchingWithOptions`
       never sees the launch.
   - Even in the foreground, the engine forwards `@{}` as launch options to
     plugins in scene apps (`FlutterPluginAppLifeCycleDelegate.mm`
     `sceneFallbackDidFinishLaunchingApplication`, "Send nil launchOptions
     since UIKit sends nil when UIScene is enabled"). So
     `launchedForLocation` is always false and the native relaunch branch
     is dead code.
   - Effect:
     - The run resumes only when the driver opens the app again. That is
       the same as without "Always".
     - The "Tracking resumed by itself" promise in the App Review notes, the
       Always purpose string and the optional Always screen is not true.
     - T6 will fail, and Apple may reject an "Always" justification that the
       app does not deliver.
   - Fix: pick one, and confirm it on a real iPhone (T6).
     - (a) In `patch_native.py`, opt the Runner out of UIScene for now.
       - Drop `UIApplicationSceneManifest`.
       - Use the classic AppDelegate that registers plugins on `self` in
         `didFinishLaunchingWithOptions`.
       - With that, the main storyboard and engine load on a background
         launch, and plugins get the real launch options.
       - Record in DECISIONS when Apple's scene requirement will force a
         change.
     - (b) Keep UIScene. In the AppDelegate (a patch), when
       `launchOptions?[.location] != nil` and the run flag is set, start a
       headless `FlutterEngine`, register the plugins on it and run `main`.
       Make sure a later foreground scene does not start a second tracker.
     - (c) If neither is wanted now, take out the relaunch claims:
       - remove the Always screen and the Always purpose text,
       - rewrite the App Review notes and the DECISIONS / open-items lines,
       - keep the 2-minute "Run still on" fallback, which works.

## Non-blocking findings

1. **Mid-run loss: the steps also require notifications.** In
   `driver_trip_screen.dart:148`, `_lost` opens
   `showLocationSteps(context, blocking: true)`, which closes only when
   `isReady` (location **and** notifications). Suppose a driver resumed with
   notifications off (`_load` resumes on `locationReady`), or turned them off
   mid-run, then fixes location. The screen stays open. If they close it,
   `back` is false, so tracking is not restarted, and `_recheckRunning` sees
   `locationReady` and does nothing. Use a location-only blocking mode
   here, or restart when `locationReady`.
2. **Trip retention deletes earlier than the owner rule (13:29).**
   `anonymiseTrip` sets a deleted parent's `parentUid` to `"deleted"` at
   account deletion. After that, `participantsOf` no longer counts them.
   So:
   - At the driver's purge step (`firestore_store.ts:513`), a trip whose
     other parents all closed their accounts recently is deleted at once.
   - `deleteOrphanTrips` (`firestore_store.ts:636`) deletes a trip the day
     after its last parent closes their account.

   The rule says "deleted only when every participant's account has been
   closed for more than 1 year". Deleting earlier is not a privacy risk,
   but it contradicts the decision. Fix: keep the closure time of
   anonymised participants on the trip (for example `keptUntilMs` = max
   over closed participants of `closedAt` + 1 year), and test it.
3. **`orphanTrips` can starve** (already in open-items D9). The same first
   200 `driverUid == "deleted"` trips are read every day.
4. **Optional Always prompt can hang for up to 30 s.** In
   `RunRecoveryPlugin.swift:92-112`, if the driver taps "Keep Only While
   Using", the authorization does not change, so no delegate callback
   arrives and the button spins until the timeout. Answer on
   `applicationDidBecomeActive` too. Also, each request's 30 s timer can
   answer a later request early.
5. **The admin device-check sheet opens the photos before a reason is
   chosen.** `user_screen.dart:391` calls `userPhotos(uid, review)` in
   `initState`, so a logged photo access with the default reason "review"
   happens on open. Every reason change logs another access (line 412).
   Let the admin pick the reason first, then show the photos.
6. **App Store privacy answers: Stream also receives the account ID.**
   `functions/src/chat/sync.ts:249` upserts `{ id: uid, name, parentId,
   language }`, so the Firebase uid is the Stream user ID. The Identifiers
   row and the partner table in `docs/app-store-privacy.md` mention only the
   parent ID.
7. **"Run still on" is skipped after a reported loss.** `reportTrackingLost`
   sets `staleAlertedAtMs`, so the tick sends no driver push in that gap.
   This is acceptable because the driver was in the app, but if they then
   swipe the app away, nobody reminds them. Consider a separate driver flag.
8. **Stale text** (says "Always is never asked/requested" or describes the
   removed flow):
   - `SETUP.md:1158-1166` and `SETUP.md:1192-1196`. These test steps still
     say to choose Always.
   - `lib/features/trips/location_tracker.dart:17`
   - `driver_trip_screen.dart:53`
   - `test/helpers/trip_fakes.dart` ("three overrides"; there are now five)
   - `functions/src/trips/callables.ts:204`: the F34 doc comment now sits
     above `reportTrackingLost`.
   - `functions/src/auth/otp_flow.ts:200`: the `codeHash` doc comment now
     sits above `reviewAccessFor`.
9. **On-phone buffer.** Coordinates and the run token sit in
   shared_preferences (NSUserDefaults) for up to a day. They are cleared at
   the end of the run. This is acceptable, but Data Protection "complete
   until first unlock" or a file in Application Support with
   `NSFileProtectionComplete` would be stronger. Separately, trimming the
   buffer at 2,000 points while a flush is in flight can drop the wrong
   points (`geolocator_tracker.dart:366-367` vs `:425`). This only happens
   at the cap.
10. **Review code.** The fixed code keeps the same hash across reissues, so
    guesses add up over the window. They are bounded by the send and
    attempt limits, which is fine. Keep the window short (the docs use 14
    days; the cap is 30).
11. **`packages/run_recovery` has no `Package.swift`.** Flutter falls back to
    CocoaPods for it (fine while a Podfile is generated). Add SPM support
    later. An iOS-only plugin with no Android entry is valid: Android and
    web skip it, and the Dart side guards with `isIos`.
12. **Rules tests.** `config/reviewAccess` is covered by the deny-all
    `config/{name}` rule. Add it to the explicit deny lists in
    `tests/rules/*` for documentation.
13. **TypeScript with the workspace stubs.** I counted 157 errors against
    156 on main, all `TS7006` stub noise. The extra one is an
    implicit-any `d` in `privacy/firestore_store.ts`. It should disappear
    with the real firebase-admin types in CI. Confirm there.

## Checked and found correct (statically)

- **geolocator APIs** (14.1.2 / apple 2.4.3):
  - `AppleSettings` has `accuracy`, `activityType`, `distanceFilter`,
    `pauseLocationUpdatesAutomatically`, `allowBackgroundLocationUpdates`,
    `showBackgroundLocationIndicator` and `timeLimit`.
  - `Geolocator.getLocationAccuracy`, `getServiceStatusStream`,
    `openAppSettings`, `openLocationSettings`, `getCurrentPosition` and
    `getPositionStream` all exist, as do `ActivityType` and
    `LocationAccuracyStatus.reduced`.
  - The `LocationPermission` switch is exhaustive.
  - `requestPermission` on iOS asks for When In Use first whenever
    `NSLocationWhenInUseUsageDescription` exists. It does, so D3/L2 are
    fine.
- **Analyzer rules** in changed Dart files (no issues found by reading):
  - const used only on the outermost literal; no redundant default
    arguments (driver options are passed as variables on purpose);
    private named initializing formals, a pattern main already uses;
  - imports ordered and all used; no literal bidi characters;
  - `Override` comes from `flutter_riverpod/misc.dart`;
  - every unawaited future is wrapped; `mounted` / `context.mounted` is
    checked after each await.
- **Riverpod 3:** `runRecoveryLauncherProvider` read through
  `container.read` is not paused. Pausing only happens on an
  active-to-inactive change (checked against riverpod 3.5 `element.dart`).
- **Driver gate:**
  - blocks only Start run (`ensureReadyToDrive` is skipped on resume);
  - checks Location Services, When In Use or Always, Precise and
    notifications;
  - shows the system prompts once when never asked, then the full-screen
    steps with Open Settings;
  - re-checks on resume and when Location Services change, and closes
    itself;
  - Home banner covers location only, never blocks, and is hidden while
    loading or on error.
- **Server push:**
  - "Run still on" goes to the driver and "location stopped" to the
    parents, after 2 minutes, once per gap (`staleAlertedAtMs`);
  - `reportTrackingLost` accepts only a reason, checks driver and active
    run, and logs no coordinates or uid;
  - no coordinates in app logs or Sentry (`debugPrint` of `runtimeType`
    only).
- **Run marker:**
  - holds only uid, carpool, run and start;
  - expires after 3 hours, belongs to the same user only, and is cleared on
    tracker idle (run end, 401/410) and on sign-out;
  - offline keeps the marker; a missing permission does not resume.
- **App Review sign-in code:**
  - off by default (no doc or malformed doc counts as off, and a read
    error fails closed);
  - one phone, matched as a keyed HMAC phone key with an HMAC code hash;
    expires after at most 30 days (checked on the server too);
  - every limit and lock still applies, no WhatsApp is sent, and it is
    turned on only by a super-admin script with an audit entry;
  - `config/` is deny-all in the rules; tests in `otp_flow.test.ts`.
- **Admin new-phone decision:**
  - `requireAdminCaller`, a validated access reason, an outcome
    allow-list, and no self-decision;
  - audit written before the change; refused when no check is open;
  - Functions and widget tests.
- **Retention:**
  - transfer records stay 5 years (append-only, nothing deletes them);
  - closed-carpool purge no longer deletes trips wholesale;
  - driver purge step anonymises or deletes (see finding 2).
- **Info.plist:**
  - `UIBackgroundModes` = `location` and `remote-notification` only;
  - When In Use, Always-and-When-In-Use, camera, photos and Face ID texts
    in AR/EN `InfoPlist.strings`;
  - the paid plugin's keys and BGTask id are removed.
  - `tool/test_*.py` pass.
- **Swift:**
  - `CLBackgroundActivitySession` only behind `#available(iOS 17)`;
    `CLServiceSession(authorization:)` only behind `#available(iOS 18)`;
  - significant-change monitoring only with `.authorizedAlways`;
  - `startRun` / `stopRun` begin and end both sessions;
  - podspec iOS 15 matches `MIN_IOS` and the Podfile patch;
  - `bootstrap.sh` runs `pub get` inside `packages/run_recovery`, so
    `flutter analyze` at the root resolves it.
- **Codemagic:**
  - `ios-staging` triggers only on push to `main`, tags `v*` and manual
    starts;
  - no secret in the repository (the diff was grepped);
  - `BG_GEO_LICENSE` is gone.
- **No paid plugin left:** no `flutter_background_geolocation` or
  Transistor references in `lib/`, `test/`, `packages/`, the pubspec,
  `codemagic.yaml` or `patch_native.py` (only history/how-to-restore notes
  in docs).
- **Tests:**
  - lazy lists: taps use `ensureVisible`, and the views are 2400 dp tall;
  - pump before tap;
  - a constant override count per test (`tripOverrides` always adds the
    same five);
  - one-line checks at 320 dp and 200 % text for the gate, banner and
    Always screen.
- **Docs:** testflight.md, app-review-notes.md, test-iphone.md (F1-F44 all
  present, plus L1-L8 and T0-T10) and open-items.md match the code, apart
  from blocker 2 and findings 6 and 8.

## Tests run here

- **Functions:** `tsc` (stub noise only, see finding 13), then
  `node --test lib/test/*.test.js`: **630 tests, 630 pass, 0 fail**.
  `npm test` itself stops at the `tsc` step because of the known stub
  errors, as on main.
- **Python:** `python3 -m unittest discover -s tool -p 'test_*.py'`:
  4 pass.
- **Flutter, rules and Swift:** not run (no SDK and no emulators).

## Not verifiable without CI or a real iPhone

- `flutter analyze` (zero infos), `flutter test`, the goldens and
  screenshots (`trips_gate_*`, `trips_always_*`, `home_location_*`), and
  the web and Android compile. Blocker 1 must be fixed first.
- Rules tests on the emulators (no rules change in this prompt).
- That the Swift plugin compiles with the Codemagic Xcode, and that
  CocoaPods/SPM mixed mode resolves `run_recovery`.
- Real-iPhone behaviour:
  - first prompt shows "While Using" (L2);
  - blue indicator, lock screen, calls, app switch (T1-T4);
  - "Run still on" timing (T5);
  - relaunch and resume with Always (T6, which blocker 2 predicts will
    fail);
  - Low Power Mode and battery (T8, T10).
- That a TestFlight build signs and uploads (needs the owner's App Store
  Connect, Codemagic and Firebase staging setup, open-items A1-A3).
- App Review's acceptance of the Always justification and the review
  sign-in.
