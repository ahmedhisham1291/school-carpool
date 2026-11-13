# School Carpool

Free, non-profit app for verified parents in Egypt to share school runs.
Flutter (iPhone first, then web and Android) on Firebase. Arabic first,
right to left.

- Product spec: [docs/spec.md](docs/spec.md)
- Build plan: [docs/build-prompts.md](docs/build-prompts.md)
- Rules for coding agents: [CLAUDE.md](CLAUDE.md) / [AGENTS.md](AGENTS.md)
- Console setup for the owner: [SETUP.md](SETUP.md)
- Running costs and free-tier limits: [docs/COSTS.md](docs/COSTS.md)
- Progress notes per prompt: [docs/progress](docs/progress)

## Requirements

| Tool | Version |
| --- | --- |
| Flutter | stable, 3.50 or newer (Material comes from the `material_ui` package) |
| Xcode | current release, for iPhone builds (macOS only) |
| Node.js | 22 (Cloud Functions runtime) |
| Java | 21 (Firebase emulators) |
| Firebase CLI | 15 (`npm install -g firebase-tools`) |

## First run (Mac)

```sh
tool/bootstrap.sh                     # creates ios/ android/ web/, applies our settings,
                                      # flutter pub get, flutter gen-l10n
npm install --prefix functions
firebase emulators:start --project demo-school-carpool     # terminal 1
npm --prefix functions run seed:emulator                   # terminal 2: fake data
flutter run -t lib/main_dev.dart                           # iOS Simulator
```

On a physical iPhone, point the app at your Mac's address on the same Wi-Fi:

```sh
flutter run -t lib/main_dev.dart --dart-define=EMULATOR_HOST=192.168.1.20
```

The emulator UI is at http://localhost:4000.

## Flavors

| Flavor | Entry point | Backend | Developer tools |
| --- | --- | --- | --- |
| dev | `lib/main_dev.dart` (also `lib/main.dart`) | local emulators (`demo-school-carpool`), or the dev project with `USE_EMULATORS=false` | gallery, A/B design switch, test errors |
| staging | `lib/main_staging.dart` | staging project, App Check on | none |
| prod | `lib/main_prod.dart` | production project, App Check on | none |

Bundle ids come from `BUNDLE_ID_BASE` (see `tool/bootstrap.sh`): `.dev`, `.stg`
and no suffix for prod. Run `FLAVOR=staging tool/bootstrap.sh` before building
another flavor's native app.

## Build-time defines

Pass with `--dart-define=NAME=value` (never commit values):

| Name | Default | Purpose |
| --- | --- | --- |
| `USE_EMULATORS` | `true` | dev only: use the local emulators |
| `EMULATOR_HOST` | `localhost` (`10.0.2.2` on Android) | where the emulators run |
| `SENTRY_DSN` | empty (Sentry off) | Sentry project DSN for this flavor |
| `SENTRY_SAMPLE_RATE` | `1.0` | share of errors sent (free plan) |
| `APP_CHECK_DEBUG_TOKEN` | empty | App Check debug token for debug builds on devices |
| `RECAPTCHA_SITE_KEY` | empty | App Check on the web (Stage 2) |

## Checks

```sh
flutter analyze
flutter test
npm test --prefix functions
npm install --prefix tests/rules
firebase emulators:exec --only firestore,storage --project demo-school-carpool "npm --prefix tests/rules test"
```

Screenshots of the tab shell and the gallery (Arabic/English, light/dark,
directions A/B) are written to `test/screenshots/goldens/`:

```sh
flutter test test/screenshots --update-goldens
```

CI: GitHub Actions (`.github/workflows/checks.yml`) runs all of the above on
every push and publishes the screenshots as the `screenshots` artifact.
Codemagic (`codemagic.yaml`) builds the iPhone app for TestFlight.

## Layout

```
lib/
  main_{dev,staging,prod}.dart   flavor entry points -> bootstrap.dart
  config/        flavor config from --dart-define
  firebase/      Firebase options per flavor, emulators, App Check
  observability/ Sentry setup and the personal-data scrubber
  l10n/          app_ar.arb (default), app_en.arb; generated code in l10n/gen
  design/        tokens, themes (directions A and B), components
  router/        go_router with the five bottom tabs
  features/      shell, placeholder tabs, settings, dev gallery
functions/       Cloud Functions (TypeScript, 2nd gen) and the emulator seed
tests/rules/     Firestore and Storage rules tests (emulator)
tool/            bootstrap.sh and native overrides (iOS plist, entitlements)
```
