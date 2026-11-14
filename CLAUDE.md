# School Carpool App: rules for the coding agent

Source of truth: docs/spec.md. Owner decisions (incl. legal answers): docs/DECISIONS.md. Feature IDs (F1 to F44) are in section 4.
If the spec and a prompt disagree, stop and ask me.

STACK (decided: the strongest option for each job, paid where that buys
quality)
- Flutter, stable channel: one codebase for iPhone, website and Android.
  Riverpod for state and go_router for navigation, unless you give me a
  reason to change.
- Firebase on Google Cloud: Authentication on the Identity Platform tier,
  Firestore with point-in-time recovery and daily backups, Storage, Cloud
  Functions second generation (TypeScript) with instances kept warm for
  sign-in, alerts and the wallet, Cloud Messaging, App Check, Hosting.
- Three Firebase projects and three app flavors: dev, staging, prod.
  Dev runs on the Firebase emulators.
- Sign-in: a one-time code sent by WhatsApp from Cloud Functions, then a
  Firebase custom token. SMS only as a backup when WhatsApp delivery fails,
  through our own SmsProvider in Cloud Functions (owner decision 14 Nov
  2026); never Firebase phone auth.
- The WhatsApp Business Platform is called only from Cloud Functions.
- Google Maps Platform for every map, with Places for address search and
  Routes for arrival times.
- Live location on the phone: the free geolocator plugin ("While Using
  the App" + Precise Location, background location mode, blue indicator),
  running only while a run is on (owner decision 14 Nov 2026). The paid
  flutter_background_geolocation is deferred to the Android stage or the
  pilot if tracking proves unreliable (docs/DECISIONS.md).
- Chat: our own chat on Firestore (owner decision 14 Nov 2026, replaces
  Stream). Cloud Functions decide who is a member of which carpool chat;
  rules let only members read and write.
- School search: Algolia, fed from Firestore by a Cloud Function.
- ID check: Valify behind one interface (KycProvider).
- Wallet: a payment partner licensed by the Central Bank of Egypt behind
  one interface (WalletProvider). The partner holds the money. Our database
  keeps a copy of balances and a record of transfers, never the money.
- Errors: Firebase Crashlytics in the app; Google Cloud Error Reporting and
  Logging for Cloud Functions (owner decision 14 Nov 2026, replaces Sentry).
- Pilot feature switches: server settings turn features on or off without a
  new build; the wallet and other non-core features start off (docs/DECISIONS.md).
- Builds and releases: Codemagic.
- Fakes for dev: the ID check, wallet, WhatsApp and school search each have
  a fake provider, so the app runs on the emulators with no paid account
  and work is never blocked by a contract. SMS has a fake provider too.

COST MODE (decided 13 Nov 2026): FREE TIER FIRST
Start every service on its free plan; upgrade only when usage reaches that
plan's limit. Code must not depend on any paid-only feature being on.
- Firebase: Blaze plan (needed for Cloud Functions) but stay inside the free
  quotas. minInstances = 0 for every function (no warm instances) - keep it
  a config value so it can be raised later. Firestore point-in-time recovery
  ON in prod (owner: best option even if paid); daily backup ON in prod.
  Auth: Identity Platform free tier.
- Algolia: free Build plan (10k searches/month); keep the fake search for dev.
- Crashlytics, Error Reporting and Cloud Logging: free; log no personal data.
- SMS backup: paid per message; only after a WhatsApp failure, Egyptian
  numbers only, strict per-number and per-IP limits (SMS fraud).
- Codemagic: free personal tier (500 macOS min/month): build iOS only by
  hand (Start new build) or on a v* tag, never on push; analyze/test on
  GitHub Actions.
- Google Maps: stay inside the monthly free allowance; cache place details,
  debounce Places autocomplete with session tokens, Routes only during a
  live run, at most once a minute per stop.
- WhatsApp: messages are paid per template; keep WhatsApp for codes and the
  critical alerts by default, everything else push-only unless the parent
  switches WhatsApp on.
- Valify and the wallet partner: fake providers until the pilot.
- Live location: geolocator, free, no licence (owner decision 14 Nov
  2026). flutter_background_geolocation (about USD 400) only if the Android
  stage or the pilot shows tracking is unreliable; switching back is a
  one-file change (docs/DECISIONS.md).
- Add a docs/COSTS.md listing each service, its free limit, how we track
  usage, and the trigger to upgrade.

PLATFORM ORDER
iPhone first. A feature is done only when it runs on iPhone. The website and
Android must keep compiling in CI, but their platform work waits for the
Stage 2 and Stage 3 prompts.

HOW TO WORK
1. Plan first. Before writing code, list the tasks, the files you will touch,
   data model changes and open questions. For every new screen, describe
   the layout and its loading, empty, error and offline states. Wait for my
   "go".
2. Keep changes small. One feature ID per commit, for example
   "F7: rotation per direction".
3. Do not add a dependency, a paid service or a new tool beyond the STACK
   list without telling me why first.
4. End every session with: what you built, screenshots of each new screen in
   Arabic and English, how I test it on my iPhone step by step, and what is
   not done.

DESIGN (applies to every screen in every prompt)
- Look: modern, calm and trustworthy. Generous white space, one accent
  color, rounded cards and a clear hierarchy. Parents use this app in a
  hurry.
- Material 3 with our own theme. Colors, type sizes, spacing, corner radii
  and shadows come from design tokens. No hard-coded values in screens.
- One typeface family that is strong in both Arabic and Latin. Body text at
  least 16.
- 8-point spacing grid. One primary action per screen. Touch targets at
  least 48 by 48.
- Every screen has a loading state (skeleton placeholders), an empty state,
  an error state and an offline state.
- Forms are split into short steps with a progress indicator, check each
  field as the parent types, and say how to fix an error.
- Every action gives feedback. Ask for confirmation before anything that
  cannot be undone.
- Accessibility: contrast at WCAG AA, text that scales to 200 percent
  without breaking the layout, and labels for screen readers.
- Right-to-left first: design each screen in Arabic, then check English.
- Light and dark themes.
- Motion is short and subtle, and follows the phone's reduce-motion setting.
- Driver screens are readable at a glance: large buttons, few words, and no
  typing while a run is on.
- Reuse components from the design system. A new component goes into the
  gallery screen first.
- Every label, button, tab, chip and title fits on one line in Arabic and
  English at 320 dp width; write short wording, never let text wrap in
  these places (shared components enforce maxLines 1).
- Elegant, refined look: restrained palette, hairline borders over heavy
  shadows, generous white space, consistent radii; follow docs/DESIGN.md.

PARENT ID
Every parent gets a public parent ID when the account is created: 8
characters from letters and digits that cannot be confused (no 0, O, 1 or
I), unique, never reused, and not derived from the phone or national ID
number. Only a Cloud Function creates it.

MONEY (never skip)
- Every wallet action goes through Cloud Functions and the WalletProvider.
  The app never writes a balance or a transfer.
- Each transfer carries a unique request ID so a retry can never send twice.
- A fresh Face ID, fingerprint or app passcode check before every transfer.
- Limits per transfer and per day, kept in server settings.
- The transfer record is append-only: no edits and no deletes.
- The app takes no fee and no commission.

SECURITY (never skip)
- Firestore and Storage rules deny everything by default.
- The app never writes status, role, verification or schedule ownership.
  Cloud Functions do. "verified" and "admin" are custom claims.
- Every rules change comes with emulator tests. No failing rules test is
  merged.
- App Check is enforced on Functions, Firestore and Storage in staging and
  prod.
- Secrets live in Secret Manager or build-time defines, never in the
  repository. Algolia, Valify, WhatsApp, SMS and wallet secrets stay in
  Cloud Functions; the app holds only short-lived tokens and search-only
  keys.

PRIVACY (never skip)
- Never log phone numbers, national ID numbers, images, coordinates or
  message text, and never send them to Crashlytics, logs or Algolia.
- Only fake data in dev and staging. Never copy production data.
- ID, selfie, school ID, licence and driver photos go to a private bucket,
  encrypted with our KMS key, and are kept while the account is active and
  deleted 1 year after it closes (docs/DECISIONS.md, data retention). Admins
  read them only through a logged reason.
- Other parents get rounded home coordinates only. Exact pickup points are
  readable only by approved members of that carpool.

LANGUAGES
Every string lives in ARB files in Arabic and English. Arabic is the default.
Every screen must work right-to-left.

TESTS
Unit tests for logic (rotation, swaps, seat limits, retention, transfers),
rules tests for every collection, widget tests for the main screens, and
golden tests of the main screens in Arabic and English, light and dark. Run
flutter analyze, flutter test and the Functions tests before you say a task
is done.

ENVIRONMENT NOTE (build workspace)
This cloud workspace has NO Flutter SDK and no access to pub.dev or npm.
Code is written here and compiled/tested on Codemagic (and on the owner's
Mac if available). So:
- Write code that compiles on Flutter stable; pin package versions you are
  confident exist; keep pubspec and package.json accurate.
- Native folders (ios/, android/, web/) are generated by `flutter create`
  in tool/bootstrap.sh, run by CI or on a Mac; commit only the overrides
  we need (Info.plist keys, entitlements, Podfile settings) as patch files
  or documented steps applied by that script.
- Never claim tests pass unless they were run. Say "written, not run here".
- Owner instruction: the coordinator says "go" on your behalf; do not wait
  for approval. Record plans and open questions in docs/progress/<prompt>.md.
