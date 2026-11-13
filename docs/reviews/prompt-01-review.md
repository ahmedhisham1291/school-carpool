# Review: Prompt 1 (Foundation)

Branch: `prompt-01-foundation` (16 commits on top of `4d9e6b9`). Reviewed
13 Nov 2026 by the validator agent.

Scope: `git diff 4d9e6b9..HEAD` (98 files), every Dart, TypeScript, YAML,
shell, Python and Ruby file, against CLAUDE.md (incl. COST MODE and
ENVIRONMENT NOTE), `docs/WORKFLOW.md` (main), `docs/spec.md` (sections 8, 10,
12), `docs/build-prompts.md` (Prompt 1 and "Done when") and
`docs/progress/prompt-01.md`.

No Flutter/Dart SDK here, so `flutter analyze` and `flutter test` were **not
run**. Findings on Dart code come from reading it against the real package
sources (cloned from GitHub at the released tags) and the Dart language spec.

## Verdict

**CHANGES NEEDED.** Two blocking issues: a Dart compile error and a rules
test that cannot pass. Both are small to fix. The rest of the foundation is
solid. The dependency claims hold up (one is partly wrong, see below), and
the security, privacy, cost and language rules are followed.

## Blocking issues

1. **Compile error: a final local is assigned in both `try` and `catch`.**
   `lib/features/settings/settings_section.dart:158-166`
   ```dart
   final String feedback;
   try {
     await functionsClient().httpsCallable('debugTestError').call<void>();
     feedback = l10n.devFunctionTestErrorDone;      // assigned in try
   } on FirebaseFunctionsException {
     feedback = l10n.devFunctionTestErrorDone;      // error
   } on Exception {
     feedback = l10n.stateErrorBody;                // error
   }
   ```
   Why: Dart flow analysis builds the state at the start of a `catch` with
   `conservativeJoin(before(try), assignedIn(tryBlock))`
   (dart-lang/language `resources/type-system/flow-analysis.md`, "try
   catch"). That makes `feedback` "not definitely unassigned" in the catch
   clauses, and assigning a final local that is not definitely unassigned is
   a compile-time error ("The final variable 'feedback' can only be set
   once"). The flow analysis ignores that the only throw comes before the
   assignment. So `flutter analyze`, `flutter test` and every build fail.
   Fix: drop `final` (`String feedback;`), or move the call into a helper
   that returns the message, e.g.
   `Future<String> _callTestError(AppLocalizations l10n) async { try { ...; return a; } on FirebaseFunctionsException { return a; } on Exception { return b; } }`.

2. **Rules tests crash before they run: `env` is used before `before()` sets it.**
   `tests/rules/deny_all.test.ts:59-66, 69, 86`. `contexts()` calls
   `env.unauthenticatedContext()` / `env.authenticatedContext()`. It is called
   inside the `describe` callbacks, and node:test runs those callbacks
   while it registers the tests, before the async top-level `before()` hook
   finishes. `env` is still `undefined`, so the result is
   `TypeError: Cannot read properties of undefined`. The rules-test step in
   Codemagic fails, so "CI is green" cannot be met and the SECURITY rule "no
   failing rules test" is broken.
   I reproduced this on Node 22.23 with a stub: a `before()` hook that
   awaits a 300 ms timer runs after the `describe` body ("contexts called"
   is logged before "before done", then a TypeError).
   Fix: register tests over static descriptors and build the context inside
   each `it`, for example
   ```ts
   const users = [
     { who: "signed out", make: () => env.unauthenticatedContext() },
     { who: "signed in", make: () => env.authenticatedContext("alice") },
     ...
   ];
   for (const u of users) for (const path of paths)
     it(`${u.who}: ... ${path}`, async () => { const d = u.make().firestore().doc(path); ... });
   ```

## Non-blocking issues

Correctness and robustness

3. `pubspec.yaml:13` says `flutter: ">=3.47.0"`, but `sdk: ^3.13.0` (and
   `material_ui` 1.10's `sdk: ^3.13.0`) needs Dart 3.13. That means Flutter
   3.50 in practice: Flutter 3.47.9's own pubspec has `sdk: ^3.11.0-0`.
   Set `flutter: ">=3.50.0"` and correct README "3.47 or newer".
4. Docs overstate the claims: Flutter 3.47 did not deprecate
   `package:flutter/material.dart`, and Sentry 10 does not use
   `material_ui`. Correct `docs/progress/prompt-01.md` decision 1 and the
   comment at `pubspec.yaml:10-12`. Details are under "Verified claims"
   below. No code change is needed.
5. No lockfiles: neither `pubspec.lock` nor `functions/package-lock.json` /
   `tests/rules/package-lock.json` is committed, so CI resolves the newest
   versions on every run. Commit the lockfiles from the first green CI run
   (for an app, `pubspec.lock` belongs in git).
6. `tool/__pycache__/patch_native.cpython-313.pyc` is committed (in
   `4d0a288`). Remove it and add `__pycache__/` to `.gitignore`.
7. `codemagic.yaml:101,156`: `APP_STORE_APPLE_ID: 0000000000` parses as
   the integer `0`. Quote the real value (`"1234567890"`) when you replace
   it.
8. `codemagic.yaml:62-69`: `checks` runs on both `push` and `pull_request`.
   A branch with an open PR is built twice for each push, and Linux minutes
   are billed. Keep only `push`, or only `pull_request` plus pushes to main.
9. `ios-staging` runs on every push to `main`. Until the staging Firebase
   options and Apple signing exist, each merge spends about 20 macOS
   minutes and gives a failed or error-screen build. Consider starting it
   by hand until SETUP.md steps 1 to 3 are done for staging.
10. `lib/bootstrap.dart:57-64` `StartupErrorApp` sets no `locale`, so on an
    English phone it shows English. The rule is Arabic by default. Pass
    `locale: AppLocales.arabic` (no saved setting can be read there).
11. Small gaps in the Dart Sentry scrubber
    (`lib/observability/sentry_scrubber.dart`): `event.contexts` and
    `exception.mechanism.data` are not scrubbed (the TypeScript version does
    scrub `contexts`). Native iOS/Android crash events from sentry-cocoa and
    sentry-android do not pass through the Dart `beforeSend`. SETUP.md step
    6.3 (server-side scrubbing, no IP storage) covers this as a second
    layer. Consider scrubbing `contexts` in Dart too, so the two scrubbers
    match.
12. `lib/features/gallery/gallery_screen.dart:281` is one 150-character
    line. It does not affect analyze, but run `dart format` before the next
    commit.

DESIGN and LANGUAGES

13. Some text is below 16: input helper and error text use `bodySmall` (14)
    (`app_theme.dart` inputDecorationTheme), NavigationBar labels use
    `labelMedium` (14), and the gallery type labels use `labelSmall` (13).
    The error text tells the parent how to fix the problem, so it should be
    at least 16. Captions and nav labels are a judgment call for the owner.
14. Reduce motion is only partly followed. `AppMotion.resolve` exists, and
    `Skeleton` uses it. But `themeAnimationDuration` (`lib/app.dart:36`),
    the button `animationDuration` (theme) and route transitions do not
    collapse to zero when reduce motion is on.
15. `lib/features/gallery/gallery_screen.dart:507` `initialValue: 'س'` is
    user-visible text that is not in the ARB files. It is a dev-only sample,
    but move it to ARB or a named constant. At
    `lib/design/components/app_button.dart:96`, `'$label, ...'` joins with a
    Latin comma; in Arabic that should be "،". Better: add an ARB message
    with a placeholder.
16. Unused ARB key `actionClose` (harmless).

Prompt and process

17. **The two design directions were not shown as screenshots** (Prompt 1:
    "First show me two color and type directions as screenshots and wait for
    my choice"; CLAUDE.md rule 4). This workspace cannot render, but CI can.
    Add one golden-style test that loads the bundled fonts (`FontLoader`)
    and pumps the gallery for A/B x ar/en x light/dark. Run it with
    `--update-goldens` in `checks` and publish the PNGs as Codemagic
    artifacts. The owner then gets the screenshots without a Mac.
18. **CI cost conflict, needs an owner decision before "CI is green"
    can be met.** Codemagic personal accounts get 500 free minutes on
    macOS M2 only, and "Builds on Linux and Windows do not have free build
    minutes" (Linux X2 USD 0.045/min) ([Codemagic pricing docs](https://docs.codemagic.io/billing/pricing/)).
    The `checks` workflow will not run on a free account until billing is
    enabled. The builder flagged this correctly (open question 4).
19. Prompt 1 asks for CI "builds for iPhone ... on every push". COST MODE
    limits iOS builds to main, tags and manual starts. That is the right
    reading of the newer owner rule, but it means no branch is
    iOS-compiled before it is validated. Record the trade-off, or add a
    cheap `flutter build ios --no-codesign --debug` only on PRs to main if
    the minutes allow.
20. The Done-when check needs the dev Firebase options from
    `flutterfire configure` (SETUP.md 3.9), which needs a machine with
    Flutter and Node. If the owner has no Mac or PC, say so in SETUP.md and
    offer a by-hand alternative: copy the values from Firebase console >
    Project settings into `firebase_options_dev.dart`.
21. SETUP.md has no step to restrict the Firebase/Google API keys (iOS key
    to the bundle ids, web key to the hosting domains). Prompt 1 lists
    "keys" among the console steps. Add this, along with the Maps keys in
    Prompt 5.
22. Offline detection is not wired up yet (acknowledged). The offline view
    exists in the gallery.

## Rule checks

| Rule | Result |
| --- | --- |
| SECURITY: deny-all rules | `firestore.rules` and `storage.rules` deny everything. Tests cover 12 paths x 4 identities (signed out, signed in, verified, admin claims) plus a collection list and Storage read/upload/delete. **Blocked by issue 2.** |
| SECURITY: App Check | Activated before any call outside the emulators: App Attest with DeviceCheck fallback in release and the debug provider in debug (`firebase_setup.dart:63-79`); off with the emulators. Callables enforce it through the `ENFORCE_APP_CHECK` param (true in dev/staging/prod, false in `.env.local`). |
| SECURITY: secrets | None committed. I grepped for API keys, private keys, Sentry DSNs and tokens. `functions/.env.*` hold only flags. `.p8`, `.p12`, `google-services.json` and `GoogleService-Info.plist` are gitignored. The Sentry DSN will go into the committed `functions/.env.dev`. Sentry treats the DSN as public, so this is acceptable. |
| PRIVACY: Sentry app | `sendDefaultPii` off; screenshots, view hierarchy, replay, print and interaction breadcrumbs off; `beforeSend` and `beforeBreadcrumb` scrub phones (incl. Arabic digits), 14-digit IDs, coordinates, emails and sensitive keys; the user is reduced to its id; request and server name are dropped. See issue 11 for gaps. |
| PRIVACY: Sentry functions | Same scrubber in TypeScript (`functions/src/scrub.ts`), `sendDefaultPii: false`. I re-ran the 11 TypeScript scrub tests here with Node 22 type stripping: **11/11 pass**. |
| PRIVACY: fake data only | The seed refuses to run without emulator env vars and a `demo-` project id. All data is invented. |
| DESIGN tokens | Colors, type, spacing, radii, shadows and motion live in `lib/design/tokens`. I found no hard-coded colors or sizes in screens and components; the only literals are icon sizes built from spacing tokens and the gallery's fraction widths. 8-point grid, 48 dp minimum (buttons, IconButton, `materialTapTargetSize.padded`, rows 64), light and dark, RTL-safe `EdgeInsetsDirectional`, one accent. I recomputed WCAG AA for every pair in `tokens_test.dart`: all pass in A/B x light/dark. Body text at 16 is met (issue 13 lists the exceptions). |
| LANGUAGES | `app_ar.arb` is the template; Arabic is the default locale and `LocaleController` defaults to `ar`. Both files have the same 70 keys and no placeholder mismatches (checked with a script). Every `l10n.*` key used in code exists. |
| COST MODE | `MIN_INSTANCES` defaults to 0 through `defineInt`, `maxInstances` is 10, PITR is off and documented (SETUP.md 5), the daily backup is prod only, Sentry sends errors only (no `tracesSampleRate`, replay rates 0) and iOS CI runs only on main, tags and manual starts. docs/COSTS.md exists. Linux CI is billed, see issue 18. |

## Prompt 1 coverage

| Bullet | Status |
| --- | --- |
| Flutter project, iPhone/web/Android, three flavors | Done through `tool/bootstrap.sh` (`flutter create --empty`) plus Dart entry points `main_{dev,staging,prod}.dart`; bundle id per `FLAVOR`. |
| Firebase per flavor, emulators (Auth, Firestore, Functions, Storage) | Done. The cloud options are placeholders until `flutterfire configure` (documented). |
| AR/EN, RTL, language switch | Done and saved on the phone; widget tests written. |
| Design system (tokens, themes, typeface, buttons, inputs, cards, sheets, rows, skeleton, empty, error, offline) | Done. Both typefaces are bundled with their OFL licenses. |
| Gallery in dev showing every component, AR/EN, light/dark; two directions as screenshots | Gallery done with switches. **Screenshots missing** (issue 17). |
| Five-tab shell (spec section 10) | Done. The tabs match the spec: Home, Carpools, Chats, Notifications, Profile. |
| Deny-all rules and a rules test project in CI | Written. **Fails (issue 2).** |
| App Check on iPhone, off in the emulator | Done. |
| Sentry in app and functions, scrubbed, one test error each | Done. **App does not compile (issue 1).** |
| Codemagic CI: analyze, tests, builds on every push | Linux `checks` (analyze, test, functions, rules, web, Android) on every push; iOS limited by COST MODE (issue 19). |
| Seed script | Done: 4 schools, 8 areas, 8 parents, 12 children, idempotent. |
| SETUP.md: projects, budget alerts, quotas, keys, PITR, backups | Done, except API key restrictions (issue 21). |
| Done when | Not yet possible: issue 1 blocks the build, issue 2 blocks a green CI, and the owner still has to finish SETUP.md and decide on CI billing. |

## codemagic.yaml and tool/bootstrap.sh

- `bootstrap.sh`: `bash -n` passes and the file is executable (100755).
  The flow is sound: it creates the native folders only when they are
  missing (it never overwrites `lib/`), removes the `MyApp` sample test,
  runs the Python patcher, runs the xcodeproj step only on macOS, then
  `pub get` and `gen-l10n`. Running it a second time for
  `FLAVOR=staging` before the APK build re-patches the ids, which is fine.
- `patch_native.py`: standard library only, idempotent, edits
  `build.gradle.kts` (the 3.50 template is Kotlin DSL). The Android
  namespace stays `org.schoolcarpool.school_carpool` while the applicationId
  changes per flavor. That is allowed.
- `configure_xcode.rb`: correct xcodeproj API use (variant group, known
  regions, entitlements on all configurations).
- `codemagic.yaml`: the YAML anchors resolve. The steps follow Codemagic's
  documented flow: `xcode-project use-profiles` writes
  `/Users/builder/export_options.plist`, and
  `app-store-connect get-latest-testflight-build-number` is used with the
  integration. `java: 21` suits the firebase-tools 15 emulators;
  `firebase-tools@15` exists (v15.36.0). The workflows would run once the
  owner setup is done, the integration and groups exist, and issues 1 and 2
  are fixed. See issues 7, 8, 9 and 18.

## Verified claims (with sources)

| Claim | Result | Evidence |
| --- | --- | --- |
| Material moved to the `material_ui` package; in-SDK `material.dart` deprecated | **Confirmed, version detail wrong.** The packages were published starting in Flutter 3.47 as opt-in; the in-framework libraries are "formally deprecated in Flutter 3.50". `packages/flutter/lib/material.dart` at tag 3.50.0 has `@Deprecated('Use package:material_ui/material_ui.dart instead. This feature was deprecated after v3.47.0-0.0.pre.')`; the 3.47.9 tag has no annotation. | [Flutter breaking change: material_ui and cupertino_ui](https://docs.flutter.dev/release/breaking-changes/material-ui-and-cupertino-ui); [Flutter blog](https://flutter.dev/blog/decoupling-material-cupertino); flutter/flutter tags 3.47.9 and 3.50.0 |
| Localizations delegates come from `material_ui` | **Confirmed.** `material_ui` exports `static const List<LocalizationsDelegate<dynamic>> delegates` (`global_material_localizations.dart:674`), so the spread in the `const` list in `lib/l10n/l10n.dart` is valid. The gen-l10n template still imports `flutter_localizations`, but `lib/l10n/gen` is excluded from analysis, so this does not matter. | flutter/packages `material_ui` source; flutter_tools `gen_l10n_templates.dart` at 3.50.0 |
| go_router 18 uses `material_ui` | **Confirmed.** CHANGELOG 18.0.0: "Migrates to material_ui and cupertino_ui"; 18.1.4 depends on `material_ui: ^1.0.0` and imports it. | flutter/packages tag `go_router-v18.1.4` |
| sentry_flutter 10 uses `material_ui` | **Refuted.** sentry_flutter 10.4.0 (latest) has `material_ui` only as a dev dependency. Its `lib/` still imports `package:flutter/material.dart` (for example `sentry_widget.dart`, `sentry_navigator_observer.dart`). 10.3.0 only added support for detecting taps on `material_ui` widgets. **No impact on this app:** the app passes no Material types to Sentry, and the deprecation warning stays inside the package. The other Sentry 10 claims are confirmed: minSdk 26, and CocoaPods support removed in favor of Swift Package Manager. | getsentry/sentry-dart tag `10.4.0` (`packages/flutter/pubspec.yaml`, CHANGELOG 10.0.0 and 10.3.0) |
| `flutter_gen` synthetic package removed | **Confirmed.** In flutter_tools 3.50.0, `synthetic-package: true` causes a tool exit: "Cannot enable \"synthetic-package\", this feature has been removed. See http://flutter.dev/to/flutter-gen-deprecation". `output-dir: lib/l10n/gen` is the correct replacement. | flutter_tools `localizations_utils.dart:486-501` |
| rules-unit-testing 6 needs Node 24 | Not checked; v5.0.2 exists (`engines: node >=20`, peer `firebase ^12.0.0`), so the chosen pin works on Node 22. | firebase-js-sdk tag `@firebase/rules-unit-testing@5.0.2` |

Every pinned version exists (checked against GitHub release tags; pub.dev and
npm are not reachable from this workspace):
`material_ui` 1.6.0 (latest 1.11.0), `go_router` 18.x (18.1.4),
`flutter_riverpod` 3.x (3.5.0), `firebase_core` 5.0.0, `firebase_auth` 7.0.0,
`cloud_firestore` 7.0.0, `firebase_storage` 14.0.0, `cloud_functions` 7.0.0,
`firebase_messaging` 17.0.0, `firebase_app_check` 0.5.0, `sentry_flutter` 10.x
(10.4.0), `shared_preferences` 2.5.3+ (2.5.6), `flutter_lints` 6.0.0;
npm: `firebase-functions` 7.x (7.4.0; peer `firebase-admin` up to ^14),
`firebase-admin` 14.x (14.5.1), `@sentry/node` 11.x (11.12.0),
`@firebase/rules-unit-testing` 5.0.2, `firebase` 12.18.0, `typescript` 5.9.3.

I also checked these APIs against the sources:

- App Check 0.5.0: `activate(providerApple:, providerAndroid:, providerWeb:)`, `AppleDebugProvider(debugToken:)`, `AppleAppAttestWithDeviceCheckFallbackProvider`, `ReCaptchaEnterpriseProvider`.
- Emulator calls: `useAuthEmulator` and `useStorageEmulator` return Futures; the Firestore and Functions ones return void. The code matches.
- Sentry 10: the option names, the `BeforeSendCallback` and `BeforeBreadcrumbCallback` signatures, and that the event, message, exception and breadcrumb fields are mutable.
- firebase-functions 7: `enforceAppCheck` accepts `Expression<boolean>`; `minInstances` accepts `Expression<number>`.
- Riverpod 3.5: `overrideWithValue` and `ProviderScope.overrides` typed `List<Override>`.
- go_router 18: `StatefulShellRoute.indexedStack` wraps inactive branches in `Offstage`, so the router tests' `find.byIcon` calls skip them.
- Firebase emulators: `singleProjectMode` only warns about other project ids, so the rules tests' separate project id is fine.

## Could not be verified here

- `flutter analyze`, `flutter test`, `flutter gen-l10n` and every build: no
  Flutter SDK. The strict lint set (infos fail the build) may still flag
  small style issues beyond issue 1.
- `npm test` in functions with the real types, and the rules tests on the
  emulators: no npm registry. The TypeScript scrubber logic was run here
  (11/11 pass).
- Codemagic runs, iOS signing, TestFlight upload, the Sentry delivery of
  both test errors, and App Check on a device.
- Visual quality of the two directions: no rendering here (issue 17).
- `tool/patch_native.py` on the real Flutter 3.50 templates: the builder
  says it tested this; I reviewed the code only.

---

# Re-review (round 2)

Reviewed commits `7f8b0c9..cf993d0` (10 builder commits after `bbe0f6e`).
As before, no Flutter SDK is available here, so analyze and test were not
run. Checks were made against the package sources at their release tags.

## Verdict

**PASS.** Both blocking issues are fixed, and I found no new blocking
compile risk in the changed code.

## Blocking fixes

1. **Issue 1 (final reassigned in catch) is fixed.**
   `settings_section.dart:155-173` now calls
   `_callFunctionTestError(l10n)`, which `return`s from `try` and from each
   `on` clause. Its result goes into
   `final String feedback = await ...`. No final local is assigned in a
   catch any more. `context` is still read only before the `await`.
2. **Issue 2 (rules contexts created before `env`) is fixed.**
   `tests/rules/deny_all.test.ts:59-95`: the `users` list holds `make`
   closures, and each `it` calls `make()` inside the test body. That runs
   after the async `before()`, so `env` is set by then. The same
   test coverage is kept: 12 paths x 4 identities, plus a collection list
   and Storage.

## New and changed code

- **`.github/workflows/checks.yml`** (new tool; the owner approved it, see
  progress note "Owner decisions" 5). It should run on `ubuntu-latest`:
  - **Action SHAs:** each one matches its tag. Checked with
    `git ls-remote`:
    - `actions/checkout@3d3c42e` = v7 / v7.0.1
    - `subosito/flutter-action@1a44944` = v2 / v2.23.0
    - `actions/upload-artifact@cf430e0` = v7 / v7.0.2
    - `actions/setup-java@b843ebf` = v6 / v6.1.0
    - `actions/setup-node@949feb2` = v7 / v7.1.0
    - `actions/cache@55cc834` = v6 / v6.1.0
  - **flutter-action:** `channel: stable`, `flutter-version: 3.50.0` and
    `cache: true` are valid inputs. 3.50.0 is a real stable tag and
    satisfies `sdk ^3.13`.
  - **Bootstrap:** it needs only bash, python3 and flutter, all present on
    ubuntu runners. `flutter create --platforms=ios` works on Linux, and the
    xcodeproj step is skipped off macOS.
  - **builds job:** Java 17 plus the runner's preinstalled Android SDK is
    enough for the 3.50 Gradle/AGP template. The web build and the
    debug-signed release APK look right.
  - **backend job:** Node 22 and Java 21 (the firebase-tools 15 emulators
    need Java 21). `npx --yes firebase-tools@15 emulators:exec --only
    firestore,storage --project demo-school-carpool "npm --prefix
    tests/rules test"` runs from the repo root, where `firebase.json` is.
    `singleProjectMode` only warns about the tests' separate project id.
    The emulator jars are cached in `~/.cache/firebase/emulators`.
  - **Artifact upload:** `if: always()` with `if-no-files-found: warn`,
    which is right for the screenshots.
- **Screenshots (`test/screenshots/screenshots_test.dart`).** The approach
  is sound:
  - `skip: !autoUpdateGoldenFiles` means a plain `flutter test` skips
    these tests; `--update-goldens` writes 16 PNGs to
    `test/screenshots/goldens/`. That folder is gitignored and uploaded as
    an artifact.
  - The real fonts are loaded through `FontLoader`. The `services.dart`
    import is needed, because `material_ui` does not export `FontLoader`
    or `rootBundle`.
  - The MaterialIcons load is wrapped in a `try`, so a missing font cannot
    fail the run.
  - Overriding `routerProvider` with a router per location is valid. The
    tests use `pump`, not `pumpAndSettle`, because the skeleton animation
    loops.
- **Reduce motion:**
  - `AppMotion.reduceMotion` now also checks `MediaQuery.maybeReduceMotionOf`
    (exists in 3.50, `media_query.dart:2073`).
  - `platformReducesMotion()` reads `AccessibilityFeatures.reduceMotion`
    and `disableAnimations` (both in `dart:ui`, `window.dart:954,965`).
  - `CarpoolApp` becomes a `ConsumerStatefulWidget` with
    `WidgetsBindingObserver.didChangeAccessibilityFeatures`, so the theme
    is rebuilt when the setting changes.
  - The theme switches off button `animationDuration`,
    `themeAnimationDuration` and page transitions.
  - `NoMotionPageTransitionsBuilder` overrides `transitionDuration` and
    `buildTransitions<T>` with signatures that match the widgets-layer base
    class. `TargetPlatform` reaches the app through `material_ui` →
    `widgets.dart` (`basic.dart:37`).
  - The new tokens tests cover iOS `reduceMotion` and the reduced theme.
- **`codemagic.yaml`** now holds iOS workflows only: `ios-staging` runs on
  main, `v*` tags and manual starts, and `ios-dev` runs only when started
  by hand. The Apple ID placeholders are quoted strings now, and the YAML
  parses. Issues 7, 8 and 18 are fixed.
- **Other review items:**
  - Fixed: the Arabic default for `StartupErrorApp` (10); helper and error
    text at 16 (13); the button loading label as an ARB message with a
    placeholder and an Arabic comma (15); the sample value moved to ARB
    (15); the unused `actionClose` removed (16); `flutter: ">=3.50.0"` and
    the corrected comments (3, 4); the `.pyc` removed and ignored (6).
  - ARB parity re-checked: 71/71 keys and matching placeholders, and every
    `l10n.*` key used in the code is defined.

## Non-blocking (new or still open)

- R1. There are still no lockfiles (`pubspec.lock`, `package-lock.json`).
  Commit them from the first green Actions run.
- R2. Actions pins Flutter 3.50.0, but Codemagic uses `flutter: stable`.
  Pin Codemagic to `3.50.0` too, so iOS builds the same SDK that CI
  checked.
- R3. The screenshot run renders the gallery at 390x5200 logical pixels,
  ratio 2, about 10k px tall. That is fine for an artifact, but if the
  runner gets tight on memory, split the gallery into two images.
- R4. Earlier items 11 (Dart scrubber: `contexts`) and 19 (no iOS compile
  on branches) are deferred in the progress note. That is acceptable.

## Still not verified here

`flutter analyze`, `flutter test` and the screenshot output; the Actions
and Codemagic runs; the TestFlight install and Sentry delivery. The first
green `checks` run on GitHub is the real confirmation.
