# Prompt 1: Foundation — progress note

Branch: `prompt-01-foundation`. Date: 13 Nov 2026.
The coordinator gave "go" on the owner's behalf (CLAUDE.md environment note).

**Status: code complete, not yet compiled.** This workspace has no Flutter
SDK and no package registry, so `flutter analyze`, `flutter test`, the
Functions build and the rules tests are **written, not run here**. They run
in the Codemagic `checks` workflow. The first CI run is the real check; expect
to fix small compile errors there.

## Plan that was followed

1. Project config, dependencies, bundled fonts.
2. Design tokens, two directions (A and B), Material 3 light and dark themes.
3. Localization (Arabic default, English), flavor config, saved settings.
4. Components: buttons, inputs, cards, sheets and confirm dialog, list rows,
   section header, skeletons, empty, error and offline states.
5. Firebase per flavor, emulators in dev, App Check elsewhere, Sentry with a
   personal-data scrubber.
6. App shell: five bottom tabs (spec section 10) with placeholder screens,
   settings on the Profile tab, dev-only gallery.
7. Firebase config, deny-all rules, rules tests on the emulators.
8. Cloud Functions (TypeScript, 2nd gen): Sentry, scrubber, `debugTestError`,
   emulator seed script.
9. `tool/bootstrap.sh` with the iOS and Android overrides.
10. Codemagic CI, SETUP.md, docs/COSTS.md, this note.

No data model changes (no app collections yet; the seed writes fake
`schools`, `areas`, `users`, `parentLocations` and `children` to the emulator
only).

## What was built

| Area | Files |
| --- | --- |
| Flavors | `lib/main_dev.dart`, `main_staging.dart`, `main_prod.dart` (`main.dart` = dev), `lib/bootstrap.dart`, `lib/config/flavor.dart` |
| Firebase | `lib/firebase/firebase_setup.dart` (emulators in dev, App Check otherwise), `demo_firebase_options.dart`, placeholders `firebase_options_{dev,staging,prod}.dart`, `firebase.json`, `.firebaserc`, `firestore.rules`, `storage.rules`, `firestore.indexes.json` |
| Localization | `l10n.yaml`, `lib/l10n/app_ar.arb` (template, default), `app_en.arb` (70 strings each, same keys), `lib/l10n/l10n.dart` |
| Settings | `lib/settings/` language, theme mode and design direction, saved on the phone |
| Design system | `lib/design/tokens/*` (colors, type scale, 8-point spacing, radii, shadows, motion), `lib/design/theme/*` (Material 3 themes, `AppColors` extension), `lib/design/components/*` |
| Navigation | `lib/router/app_router.dart` (go_router, `StatefulShellRoute` with 5 tabs; gallery route only in dev), `lib/features/shell/home_shell.dart`, `lib/features/placeholder/placeholder_tab_screen.dart` |
| Dev tools | `lib/features/gallery/gallery_screen.dart`, `lib/features/settings/settings_section.dart` (design A/B switch, gallery, app test error, server test error) |
| Sentry | `lib/observability/` (app), `functions/src/sentry.ts`, `functions/src/scrub.ts` |
| Functions | `functions/src/index.ts` (`debugTestError`), `functions/src/config.ts` (`MIN_INSTANCES` param, default 0), `functions/.env.*` (non-secret flags) |
| Seed | `functions/scripts/seed.ts` (`npm --prefix functions run seed:emulator`): 4 schools, 8 areas, 8 parents (mixed statuses), 12 children, all fake; refuses to run outside the emulators or on a non-`demo-` project |
| Rules tests | `tests/rules/deny_all.test.ts`: signed-out, signed-in, verified and admin-claim users cannot read, write, list or delete anything in Firestore or Storage |
| Native | `tool/bootstrap.sh`, `tool/patch_native.py`, `tool/ios/` (entitlements, ar/en `InfoPlist.strings`, `configure_xcode.rb`) |
| CI | `codemagic.yaml` |
| Docs | `README.md`, `SETUP.md`, `docs/COSTS.md` |
| Tests | `test/design/tokens_test.dart`, `test/settings/locale_switch_test.dart`, `test/router/router_test.dart`, `test/observability/pii_scrubber_test.dart`, `functions/test/scrub.test.ts` |

## Two design directions (choose one)

Both follow the DESIGN rules: one accent color, calm neutrals, rounded cards
(16 px), soft shadows in light mode, body text 16 or larger, zero letter
spacing (it breaks Arabic letter joins), 8-point grid. Switch between them in
the dev build: **Profile tab > Developer tools > Design direction**, or the
palette button in the gallery's top bar. Default is **A**.

| | **A: Calm teal** | **B: Warm indigo** |
| --- | --- | --- |
| Feel | Clean, clinical-calm, "safety" | Warmer, friendlier, more "family" |
| Accent (light / dark) | Teal `#0B6E66` / `#7FD5CA` | Indigo `#3A4BC8` / `#BBC3FF` |
| Background (light / dark) | Cool off-white `#F7F9F8` / `#0F1514` | Warm sand `#FBF8F3` / `#151310` |
| Cards | White on off-white, thin cool border | White on sand, thin warm border |
| Typeface | **IBM Plex Sans Arabic** (400, 500, 600, 700) | **Tajawal** (400, 500, 700) |
| Type character | Even, modern, very legible small sizes; matching Latin is IBM Plex Sans | Rounder, geometric, popular in Gulf and Egyptian apps; Latin is simpler |
| Contrast (WCAG) | Text on accent 6.1:1; secondary text 7.1:1 | Text on accent 7.0:1; secondary text 8.3:1 |

Every text/background pair used by the themes was checked at AA (4.5:1 for
text, 3:1 for input borders) in both directions and both brightnesses (the
numbers were computed here; `tokens_test.dart` repeats the check in CI).

**Screenshots:** not possible in this workspace (no Flutter SDK, no
simulator). To compare: install the dev build (steps below), open
Profile > Developer tools > Component gallery and press the palette, globe
and moon buttons.

Recommendation: **A**. IBM Plex Sans Arabic has more weights (a true
SemiBold for titles), stays legible at 200 percent text size, and the teal
reads as "safe" without the "bank app" feel of blue. Once you choose, the
other direction and its font are deleted.

## Decisions

1. **Material from `material_ui`.** Flutter 3.47 deprecated
   `package:flutter/material.dart`; Material now ships as the `material_ui`
   package (current stable is 3.50.0). go_router 18 and Sentry 10 already
   use it, so the app imports `package:material_ui/material_ui.dart`
   everywhere and takes its localizations delegates from `material_ui`.
2. **Generated localizations in source.** The synthetic `flutter_gen`
   package was removed from Flutter. Code is generated into
   `lib/l10n/gen/` (not committed; `tool/bootstrap.sh` runs
   `flutter gen-l10n`) and imported as
   `package:school_carpool/l10n/gen/app_localizations.dart` through
   `lib/l10n/l10n.dart`.
3. **Fonts bundled, not `google_fonts`.** `google_fonts` downloads fonts
   from Google at runtime: slow on weak connections, a request to Google on
   every new install, and one more dependency. Both families are bundled
   from google/fonts with their OFL licenses in `assets/fonts/`.
4. **One new dependency: `shared_preferences`** (official Flutter plugin) to
   keep the language, theme and design choice on the phone. Not in the
   STACK list, so flagged here (rule 3). Only non-personal settings go in
   it.
5. **Flavors by Dart entry point**, not native Xcode schemes or Android
   product flavors. `tool/bootstrap.sh` sets the bundle id per flavor
   (`.dev`, `.stg`, none) and display name. Simpler to keep working without
   committing `ios/`; separate schemes can come later if needed.
6. **Firebase configured from Dart** (`flutterfire configure` output per
   flavor), no `GoogleService-Info.plist`. Dev uses the `demo-school-carpool`
   project id, which the SDKs and emulators treat as offline-only: dev can
   never reach a cloud project by mistake. `USE_EMULATORS=false` lets a dev
   build use the cloud dev project (for TestFlight).
7. **Native folders not committed.** `tool/bootstrap.sh` runs
   `flutter create --empty` when they are missing and then applies
   `tool/patch_native.py` (bundle id, iOS 15.0, Info.plist keys, entitlements,
   localized permission texts, Android `minSdk 26`) and
   `tool/ios/configure_xcode.rb` (entitlements setting, localized resources).
   The patcher was tested here on the real Flutter 3.50 templates and is
   idempotent.
8. **Versions** (checked against the projects' release tags on 13 Nov 2026):
   FlutterFire 5 line (`firebase_core ^5.0.0`, Firebase iOS SDK 13, iOS 15
   minimum), `flutter_riverpod ^3.0.0`, `go_router ^18.0.0`,
   `sentry_flutter ^10.0.0` (needs Android `minSdk 26` = Android 8, which
   matches the spec, and Swift Package Manager on iOS, which is Flutter's
   default now), `firebase-functions ^7`, `firebase-admin ^14`,
   `@sentry/node ^11`, TypeScript 5.9. Rules tests use
   `@firebase/rules-unit-testing ^5` with `firebase ^12` because version 6
   needs Node 24 and our runtime is Node 22.
9. **Region `europe-west1`** for Functions (and suggested for the dev
   database) until the lawyer answers the hosting-abroad question.
10. **Sentry (free plan):** errors only, no tracing, replay or screenshots;
    `sendDefaultPii` off; user reduced to the account id; every event and
    breadcrumb scrubbed of phone numbers (including Arabic digits), 14-digit
    IDs, coordinates, emails and message text, plus sensitive keys. The
    same scrubber exists in Dart and TypeScript.
11. **Cost mode** (owner decision during this prompt): `MIN_INSTANCES=0`
    as a parameter, `maxInstances` 10, PITR off and daily backups in prod
    only (SETUP.md step 5), Sentry free plan, iOS CI builds only on `main`,
    tags or by hand. See docs/COSTS.md.

## Open questions for the owner

1. **Design direction:** A or B?
2. **Bundle id base:** what reverse domain do you own? Placeholder is
   `org.schoolcarpool.app` (in `tool/bootstrap.sh` and `codemagic.yaml`).
3. **App name:** working name "مشوار المدرسة" / "School Carpool". Final?
4. **CI cost:** Codemagic has free minutes on macOS only; Linux is billed
   (about USD 0.045 a minute, roughly USD 0.50 to 0.70 per `checks` run). You
   asked for checks on Linux. Options: (a) keep Linux and accept a few
   dollars a month, (b) switch `checks` to `mac_mini_m2` and share the 500
   free minutes with iOS builds (about 25 to 35 runs a month in total),
   (c) run the checks on GitHub Actions, which has free Linux minutes for
   this repository (a new tool, so it needs your yes).
5. **Region:** keep `europe-west1` for now, or wait for the lawyer before
   creating the staging and prod databases (the location cannot change)?
6. **Firebase project ids** for `.firebaserc`.
7. **`shared_preferences`**: OK to keep this dependency?

## How to test on your iPhone (the "Done when" check)

Prerequisites: SETUP.md steps 1, 2, 3 (dev project, including "Connect the
app"), 6 and 7. Then:

1. Codemagic: start **iOS dev to TestFlight (manual)**. Wait for the build
   and for TestFlight processing.
2. iPhone: open TestFlight, install **School Carpool Dev**. Open it. You see
   the Home tab in Arabic, right to left, with a "DEV" ribbon in the
   corner.
3. Tap each of the five bottom tabs: الرئيسية، المشاوير، المحادثات،
   الإشعارات، حسابي. Each shows its placeholder.
4. **حسابي (Profile)** > اللغة > **English**. The whole layout flips to left to
   right and the texts turn English. Close and reopen the app: it stays
   English. Switch back to العربية.
5. Profile > المظهر / Appearance: try **Dark**, **Light**, **Same as phone**.
6. Profile > Developer tools > **Component gallery**. Scroll through all
   components; use the top-bar buttons to switch language, light/dark and
   design A/B. Try the bottom sheet, the confirmation dialog and the
   loading button.
7. Profile > Developer tools > **Send test error**. Within a minute the error
   appears in Sentry (project carpool-app, environment dev). Check that it
   contains no phone number or coordinates.
8. Profile > Developer tools > **Server test error** (needs the functions
   deployed to the dev project, SETUP.md step 3.10, with the functions DSN).
   The error appears in Sentry project carpool-functions.
9. Codemagic: the latest **Checks** build is green.

From a Mac you can do the same against the local emulators: SETUP.md
section 8B.

## Verified here vs not run

Run in this workspace:
- WCAG contrast of every color pair in both directions and themes.
- The TypeScript scrubber's 11 unit tests, run against `src/scrub.ts` with
  Node 22 type stripping: all pass. The Dart scrubber uses the same
  patterns.
- `tsc` type-check of all Functions code against stand-in type stubs for
  Firebase and Sentry (catches our own strict-mode errors, not API
  mismatches): passes.
- `tool/patch_native.py` on the real Flutter 3.50 iOS and Android templates
  (twice, to prove it is idempotent).
- `codemagic.yaml` parses and its anchors resolve; Ruby and shell scripts
  pass syntax checks; Arabic and English ARB files have the same 70 keys.
- APIs used were checked against the current sources of FlutterFire,
  Sentry Dart, go_router, material_ui, Riverpod, firebase-functions and
  rules-unit-testing.

Written, not run here: `flutter analyze`, `flutter test` (4 test files),
`npm test` in functions, the rules tests on the emulators, every build.

## Not done / known risks

- **Not compiled.** First CI run may show small analyzer issues (the lint
  set is strict and analyze fails on infos).
- **Screenshots** of the screens in Arabic and English are missing (rule 4);
  they need a simulator. Golden tests come with the first real screens.
- **Firebase options** are placeholders until you run `flutterfire
  configure`; without them a staging or cloud-dev build opens an error
  screen instead of the app.
- **Offline detection** is not wired yet: the offline state widget exists in
  the gallery, but no screen listens to connectivity (needs a connectivity
  check, planned with the first data screen; may need `connectivity_plus`,
  which I will ask about first).
- **Android**: builds in CI with debug signing; emulator connection from an
  Android device (cleartext HTTP) and release signing wait for Stage 3.
- **Web**: builds in CI; App Check for web and hosting wait for Stage 2.
- **Push notifications** are not requested or tested yet (Prompt 8); the
  capability, background mode and APNs key are prepared.
- **README.md** also exists on `main` (short placeholder); merging this
  branch will need the longer version kept.
