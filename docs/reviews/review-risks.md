# Review: branch review-risks (validator, 16 Nov 2026)

Base main 495b1e8, reviewed head ed8b254 (12 commits, items 1 to 11; item
9 is on branch `chat-review-safe`, not reviewed here), plus the validator
commits on top of it.

**Verdict: PASS after fixes.** Two blockers, both in Flutter tests written
without a Flutter SDK, found by CI and fixed here (B1, B2). No problem was
found in the app, Functions, rules or native scripts. Item 8 (UIScene) was
checked against the real Flutter 3.50.0 template and engine sources and is
right; it still needs the first device build (N1).

What was run here: `python3 -m unittest discover -s tool -p 'test_*.py'`
(66 pass); `tool/patch_native.py` against the iOS files of Flutter's own
3.50.0 `flutter create` template (tag 3.50.0, ab29120, cloned from
github.com/flutter/flutter), twice (idempotent). CI: see the end.

## Blockers (fixed)

**B1. `flutter analyze` failed** (first full run 43848763670):
`test/auth/demo_refusal_test.dart` used `Locale` without importing it.
Fix: `import 'dart:ui' show Locale;`.

**B2. `flutter test` failed** (run 43849294181):
`signup_screens_test.dart` "verify-account screen explains the next steps"
looked for "National ID" without scrolling. The new "why we check" card
(item 5) pushes the steps below the lazy `ListView`, so they are not built.
Fix: the test scrolls to the steps and to "Later"; the "opened from a closed
place" test scrolls to "Later" before tapping it. The screen is unchanged.

## Item checks

**8. UIScene life cycle: PASS (highest risk, checked line by line).**
- Flutter 3.50.0 template (`packages/flutter_tools/templates/app/ios.tmpl`)
  ships `AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate`
  with `GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)`
  in `didInitializeImplicitFlutterEngine`, `SceneDelegate: FlutterSceneDelegate`
  (in the pbxproj Sources), and `UIApplicationSceneManifest` with
  `UIApplicationSupportsMultipleScenes` false, `UISceneClassName`
  UIWindowScene, `UISceneConfigurationName` flutter,
  `UISceneDelegateClassName` `$(PRODUCT_MODULE_NAME).SceneDelegate`,
  `UISceneStoryboardFile` Main. `SCENE_APP_DELEGATE` is that file plus a
  comment; `scene_info` keeps the template manifest unchanged. Same as the
  docs.flutter.dev "UIScene adoption" guide.
- Simulated: the template files patched for staging give exactly the
  template delegate + the alerts line + the Maps key block inside
  `didFinishLaunching`, background modes `remote-notification, location`,
  `FlutterDeepLinkingEnabled` true; a second run changes nothing. CI's real
  `flutter create` (Linux, 3.50.0) logs the same updates.
- Code that must run before launch ends stays in `didFinishLaunching`:
  `UNUserNotificationCenter.current().delegate = self` (as the
  flutter_local_notifications README asks, also for UIScene apps) and
  `GMSServices.provideAPIKey`. `FlutterAppDelegate` conforms to
  `FlutterAppLifeCycleProvider`, so firebase_messaging 17.0.1
  (`configureNotificationCenterDelegate`) keeps it and gets the callbacks
  forwarded; calling `FLTFirebaseMessagingPlugin.configureNotificationCenterDelegate()`
  as in its example would be a no-op here.
- Late plugin registration: the engine (`FlutterSceneLifeCycle.mm`) replays
  `scene:willConnectToSession:options:` to plugins registered after the
  scene connected, and firebase_messaging reads
  `connectionOptions.notificationResponse` there (getInitialMessage after
  a cold-start tap). Universal and custom-scheme links go through
  `FlutterSceneDelegate` (`continueUserActivity`, `openURLContexts`, and
  connection options at launch) to the router (`FlutterDeepLinkingEnabled`).
- App Check and Maps need nothing at launch beyond the Maps key above.
  run_recovery needs no launch callback any more (item 2).
  screen_protector 1.5.3 finds the window through connected scenes.
  App-delegate lifecycle callbacks reach plugins through UIApplication
  notifications, which the engine observes.

**2. No "Always": PASS.** geolocator_apple 2.4.3 uses
`BYPASS_PERMISSION_LOCATION_ALWAYS` only in `PermissionHandler.m` (the
Always request); background updates are
`allowsBackgroundLocationUpdates = allowBackgroundLocationUpdates &&
UIBackgroundModes contains location`, so While-Using + the `location` mode
+ `AppleSettings(allowBackgroundLocationUpdates, showBackgroundLocationIndicator,
pauseLocationUpdatesAutomatically: false)` keep tracking with the phone
locked. The switch is set for CocoaPods (Podfile block) and Swift Package
Manager (environment in codemagic.yaml). run_recovery keeps a
`CLBackgroundActivitySession` (iOS 17+) and a `CLServiceSession(.whenInUse)`
(iOS 18+) while a run is on. After iOS ends the app, recovery relies on the
driver opening it again: the server's "Run still on" push after 2 minutes,
then the local `RunMarker` checked against the server at start. No
background relaunch.

**3. Deletion: PASS.** In the same `deleteMyAccount` call: the immediate
targets (homes, pushTokens, devices, logins, notifications, children,
vehicle, emergency contact, ...), the chat step (Stream user hard-deleted
with `mark_messages_deleted=true&hard_delete=true`, 404/400 treated as
done, so it is idempotent) and, without a hold, the evidence (verification,
faceRefs, driverPhotos, selfieArchive, thumbs prefixes, verifications docs,
route archives and their files). The closed record is written first; a
failed step stays in `failed` and `retentionDaily` retries it; evidence
under a safety hold (open report or rating flag) runs at
`evidenceAt` = closure + 30 days. Reports keep their own context copy;
reports, audit log, transfers, consents and anonymised trips stay.
Functions tests: CI green.

**5. Look around before verification: PASS.** No rule or callable changed;
Firestore rules give other parents' data (carpools, members, pickup points,
trips, chat records, homes) only with the `verified` claim, so an
unverified account sees no other family. `verification_scope.test.ts` pins
both sides. The router closes the same places (`needsVerification`, closed
by default for unknown paths).

**7. Demo refresh: PASS.** `reviewDemoDaily` reads one document and stops
unless review access is open and every listed account is a demo account
in its window; touches only `review-demo-carpool` at the demo school;
at most 2 `planWeek` and 20 `confirmRun` calls; retryCount 1, 120 s.

**1, 4, 6, 10, 11: PASS** (read; tests in CI).

## Notes (not blockers)

- **N1.** No iOS build has run. The first Codemagic staging build and
  docs/test-iphone.md on a real iPhone remain the real test: launch, push
  tap from a killed app (FCM and a local alarm), universal link from a
  killed app, a run with the phone locked, resume after a swipe-away,
  document-screen screenshot blocking.
- **N2.** Accounts closed before this change have `purgeAt` 1 year out and
  are found by `retentionDaily` only after `deletions:reapply` (in
  DECISIONS.md). Nothing to migrate before launch; keep it in the deploy
  checklist.
- **N3.** Stream's synchronous user delete can be slow for a parent with
  many messages (300 s timeout); a failure is retried daily. If it ever
  times out, move to Stream's asynchronous delete.
- **N4.** CLAUDE.md (PRIVACY) still says photos are deleted 1 year after
  the account closes, and the STACK section describes Firestore chat while
  main still uses Stream. The owner should update CLAUDE.md to the 16 Nov
  decision; the validator does not edit it.
- **N5.** Comment in `functions/src/chat/server.ts` (`deleteUser`) still
  says "1 year after the account closed".

## CI

Full run (full=true) 43850061841 on 30fb315: green. Flutter analyze,
flutter test, screenshots (AR/EN, light/dark), web, admin and Android
builds, Functions unit and emulator tests, rules tests and tool tests all
pass. Earlier runs on this branch: 43848763670 (B1) and 43849294181 (B2).
This review document is docs-only and did not start another run.
