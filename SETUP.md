# Console setup (owner)

Step by step, in order. Everything here is done once in web consoles; nothing
needs a Mac except the optional "Run from a Mac" section. Cost rules come from
CLAUDE.md "COST MODE": pick the free plan everywhere; [docs/COSTS.md](docs/COSTS.md)
lists each limit and when to upgrade.

Placeholders used in the code that you will replace with your own values:

| Placeholder | Where | What to put |
| --- | --- | --- |
| `org.schoolcarpool.app` | `tool/bootstrap.sh` (`BUNDLE_ID_BASE`), `codemagic.yaml` | **Decided:** this is the bundle id base. Apps get `.dev` and `.stg` suffixes; prod has none |
| `REPLACE-school-carpool-dev` / `-staging` / `-prod` | `.firebaserc` | Your three Firebase project ids |
| `CodemagicASC` | `codemagic.yaml` | Name you give the App Store Connect key in Codemagic |
| `APP_STORE_APPLE_ID: 0000000000` | `codemagic.yaml` | Numeric Apple ID of the dev and staging apps |

---

## 1. Apple Developer account

1. Enroll at developer.apple.com (paid yearly). An organization account needs
   a D-U-N-S number; this decides the seller name on the App Store (ties to
   the "operator entity" question for the lawyer).
2. **Certificates, Identifiers & Profiles > Identifiers > +  > App IDs > App.**
   Create three explicit App IDs:
   - `org.schoolcarpool.app.dev` (School Carpool Dev)
   - `org.schoolcarpool.app.stg` (School Carpool Stg)
   - `org.schoolcarpool.app` (School Carpool)

   On each, tick the capabilities **Push Notifications** and **App Attest**.
   (Codemagic creates the signing profiles from these App IDs, so the
   capabilities must be on before the first build.)
3. **Keys > +**: create one key with **Apple Push Notifications service
   (APNs)** enabled. Download the `.p8` file (only once), note the Key ID and
   your Team ID. You upload it to Firebase in step 3.7.
4. **App Store Connect > Apps > +  > New App** for the dev and staging bundle
   ids (iOS, primary language Arabic). Open each app > App Information and
   copy its **Apple ID** (a number) into `codemagic.yaml`
   (`APP_STORE_APPLE_ID` of `ios-dev` and `ios-staging`).
5. **App Store Connect > TestFlight > Internal Testing**: create a group and
   add yourself, so every upload lands on your phone without review.

## 2. App Store Connect API key for Codemagic

1. App Store Connect > **Users and Access > Integrations > App Store Connect
   API > Team Keys > Generate API Key**. Name `Codemagic`, access **App
   Manager**.
2. Download the `.p8` (only once). Note the **Issuer ID** and **Key ID**.
3. Codemagic > Team settings > **Integrations > Developer Portal > Connect**.
   Name it `CodemagicASC` (or change the name in `codemagic.yaml`), paste the
   Issuer ID and Key ID, upload the `.p8`.
4. Never commit the `.p8` anywhere (`.gitignore` blocks `*.p8`).

## 3. Three Firebase projects

Do this three times: **dev**, **staging**, **prod**. Use only fake data in dev
and staging, ever.

1. console.firebase.google.com > **Add project**. Suggested ids:
   `<yourname>-carpool-dev`, `-staging`, `-prod`. Turn Google Analytics
   **off** (not in our stack, and it collects data). Put the ids in
   `.firebaserc`.
2. **Upgrade to Blaze** (pay as you go). Cloud Functions need it. You pay
   nothing while usage stays in the free quotas; step 4 adds budget alerts.
3. **Location** (asked when you create Firestore): this is permanent.
   Hosting data abroad needs the lawyer's answer (spec section 7). Until
   then, use `europe-west1` (Belgium) for the dev project only and wait
   with staging and prod. Functions use `europe-west1` too
   (`functions/src/config.ts`, `lib/firebase/firebase_setup.dart`).
4. **Build > Firestore Database > Create database**: Standard edition,
   **production mode** (deny all). We deploy our own rules anyway.
5. **Build > Storage > Get started**, production mode. Note: Cloud Storage is
   free only in some US regions; elsewhere it is billed per GB (small).
6. **Build > Authentication > Get started**, then **Settings > Upgrade to
   Identity Platform** (free tier: 50,000 monthly active users). Then
   **Settings > SMS region policy > Deny all regions**: we never send SMS,
   and this blocks SMS fraud bills. Sign-in settings: section 11.
7. **Project settings > Cloud Messaging > Apple app configuration**: upload
   the APNs `.p8` from step 1.3 with its Key ID and Team ID.
8. **App Check** (Build > App Check):
   - Register the iOS app with **App Attest** (and DeviceCheck as fallback:
     needs a DeviceCheck key from Apple > Keys, same flow as APNs).
   - Do **not** press "Enforce" yet. Install a build, watch the App Check
     metrics show "verified requests", then enforce **Firestore**,
     **Storage** and **Cloud Functions** in **staging and prod only**.
     Callable functions also enforce it in code (`ENFORCE_APP_CHECK`).
   - For a debug build on a real iPhone: run it once, copy the debug token
     from the Xcode console, add it under App Check > Apps > Manage debug
     tokens, and pass it with `--dart-define=APP_CHECK_DEBUG_TOKEN=...`.
9. **Connect the app** (on a Mac or any machine with Flutter and Node):

   ```sh
   dart pub global activate flutterfire_cli
   flutterfire configure --project=<dev-id> \
     --out=lib/firebase/firebase_options_dev.dart \
     --platforms=ios,android,web \
     --ios-bundle-id=org.schoolcarpool.app.dev \
     --android-package-name=org.schoolcarpool.app.dev
   # same for staging (.stg, firebase_options_staging.dart)
   # and prod (no suffix, firebase_options_prod.dart)
   ```

   Commit the three generated files (Firebase app config is not secret;
   App Check and the rules protect the backend). If flutterfire offers to
   write `GoogleService-Info.plist` or `google-services.json`, decline: the
   app configures Firebase from Dart.

   **No computer with Flutter?** Fill the file by hand instead. In the
   Firebase console > Project settings > General > Your apps, add an iOS
   app (bundle id `org.schoolcarpool.app.dev`), an Android app and a web
   app. Each shows its config values. Edit
   `lib/firebase/firebase_options_dev.dart` on GitHub (pencil icon) and
   replace the `throw` with values like this, one block per platform:

   ```dart
   static FirebaseOptions get currentPlatform {
     if (kIsWeb) return web;
     return defaultTargetPlatform == TargetPlatform.android ? android : ios;
   }
   static const FirebaseOptions ios = FirebaseOptions(
     apiKey: '<API_KEY from the iOS app>',
     appId: '<GOOGLE_APP_ID, 1:...:ios:...>',
     messagingSenderId: '<GCM_SENDER_ID>',
     projectId: '<project id>',
     storageBucket: '<project id>.firebasestorage.app',
     iosBundleId: 'org.schoolcarpool.app.dev',
   );
   // android and web: same fields from their app cards.
   ```

   Add `import 'package:flutter/foundation.dart';` at the top. Or ask the
   coding agent to do it from the values you paste.
10. **Deploy rules and functions** (dev first):

    ```sh
    npm install --prefix functions
    # put the functions Sentry DSN (step 6) in functions/.env.dev
    firebase deploy --only firestore:rules,firestore:indexes,storage,functions --project dev
    ```

## 4. Budget alerts, quotas and key restrictions (each project)

1. console.cloud.google.com > **Billing > Budgets & alerts > Create budget**.
   Scope: one project. Amount: USD 20. Alerts at 5 percent (USD 1), 25
   percent (USD 5) and 100 percent, emailed to you. Repeat per project.
2. **APIs & Services**: keep only the APIs Firebase turned on. Maps APIs come
   in Prompt 5 with per-day caps (Quotas page: set "requests per day" on
   Places and Routes to stay inside the free allowance).
3. Cloud Functions cannot scale past 10 instances (set in code). Warm
   instances are off (`MIN_INSTANCES=0` in `functions/.env.*`).
4. **Restrict the API keys** Firebase created (APIs & Services >
   Credentials). They are not secret, but restricted keys cannot be reused
   by others:
   - "iOS key": Application restrictions > iOS apps > add
     `org.schoolcarpool.app.dev` (or `.stg`, or the prod id for that
     project).
   - "Android key": Android apps > package name plus the SHA-1 of the
     signing key (Stage 3).
   - "Browser key": Websites > the hosting domains (Stage 2) and, in dev,
     `localhost`.
   - API restrictions on each: only the Firebase APIs it uses (Identity
     Toolkit, Token Service, Firestore, Cloud Storage for Firebase, Firebase
     Installations, FCM, App Check). The Maps keys get the same treatment in
     Prompt 5.

## 5. Firestore point-in-time recovery and daily backups

COST MODE: point-in-time recovery (PITR) **off** for now; daily backups
**on in prod only**. Install the Google Cloud CLI (`gcloud`) and log in.

- Daily backup, prod only, kept 7 days:

  ```sh
  gcloud firestore backups schedules create \
    --project=<prod-id> --database='(default)' \
    --recurrence=daily --retention=7d
  gcloud firestore backups schedules list --project=<prod-id> --database='(default)'
  ```

- Switch PITR on later (before real families join, your decision; it adds
  storage cost):

  ```sh
  gcloud firestore databases update --project=<prod-id> \
    --database='(default)' --enable-pitr
  ```

  Off again: `--no-enable-pitr`. With PITR on you can read or restore data
  from any minute of the last 7 days.
- A restore drill is written in Prompt 12.

## 6. Sentry (free Developer plan)

1. sentry.io > sign up > choose the **Developer** (free) plan. Pick the EU
   data region if offered (cross-border data question for the lawyer).
2. Create two projects: **carpool-app** (platform Flutter) and
   **carpool-functions** (platform Node.js). Environments (dev, staging,
   prod) come from the app, so one project each is enough.
3. Each project > **Settings > Security & Privacy**: turn on **Data
   Scrubber**, **Use Default Scrubbers** and **Prevent Storing of IP
   Addresses**. (The app and functions scrub phones, IDs, coordinates and
   message text before sending; this is a second layer.)
4. **Settings > Spike Protection**: on. Do not enable Performance,
   Profiling or Session Replay (paid quota, and not needed).
5. Copy the DSNs (Project > Settings > Client Keys):
   - app DSN: Codemagic environment groups `dev_defines`
     (`SENTRY_DSN_APP_DEV`) and `staging_defines`
     (`SENTRY_DSN_APP_STAGING`); for a Mac run pass
     `--dart-define=SENTRY_DSN=...`.
   - functions DSN: `SENTRY_DSN=` line in `functions/.env.dev` and
     `functions/.env.staging` (and `.env.local` to test in the emulator).
6. Alerts: Alerts > Create alert > "A new issue is created" > email you.

## 7. GitHub Actions (checks and screenshots)

1. The repository already has `.github/workflows/checks.yml`. On GitHub >
   the repository > **Actions**, allow workflows if GitHub asks.
2. Every push runs three jobs: Flutter (analyze, tests, screenshots),
   web/Android compile, and backend (Functions tests, rules tests on the
   emulators). A green check mark next to the commit means all passed.
3. **Screenshots without a Mac:** open a run > scroll to **Artifacts** >
   download **screenshots** (a zip of PNGs: tab shell and gallery in Arabic
   and English, light and dark, design A and B).

## 8. Codemagic (iPhone builds)

1. codemagic.io > sign up with GitHub (free personal plan: 500 macOS
   minutes a month).
2. **Add application** > the GitHub repository > Flutter App > "Use
   codemagic.yaml".
3. App settings > **Environment variables**: create the groups
   `dev_defines` and `staging_defines` with the Sentry DSNs (mark them
   **Secret**).
4. Codemagic only builds the iPhone app: `ios-staging` on pushes to `main`
   and tags `v*`, `ios-dev` only when you press **Start new build**. Until
   steps 1 to 3 are done for staging, a push to `main` gives a failed or
   error-screen staging build; you can switch off automatic builds for
   `ios-staging` in Codemagic until then.

## 9. Get the app on your iPhone

**A. Without a Mac (TestFlight)**

1. Finish steps 1, 2, 3 (dev project, including "Connect the app") and 8.
2. Codemagic > the app > **Start new build** > workflow **iOS dev to
   TestFlight (manual)**. About 20 minutes.
3. On the iPhone install **TestFlight** from the App Store and sign in with
   the Apple ID that is an internal tester. The build appears there after
   Apple's processing (usually 5 to 30 minutes). Install "School Carpool
   Dev".
4. This dev build talks to the cloud **dev** project (not local
   emulators), with the gallery and developer tools in the Profile tab.

**B. From a Mac (debug build, also needed for step-by-step debugging)**

1. Install Xcode, Flutter (stable), Node 22, Java 21, CocoaPods
   (`brew install cocoapods`) and `npm install -g firebase-tools`.
2. In the project folder: `tool/bootstrap.sh`.
3. `open ios/Runner.xcworkspace` (or `ios/Runner.xcodeproj` if no
   workspace) > Runner target > **Signing & Capabilities** > tick
   "Automatically manage signing" and choose your team.
4. Start the emulators: `firebase emulators:start --project demo-school-carpool`
   and in another terminal `npm --prefix functions run seed:emulator`.
5. Connect the iPhone by cable (first time: on the phone, Settings >
   Privacy & Security > Developer Mode on). Find the Mac's Wi-Fi address
   (System Settings > Wi-Fi > Details) and run
   `flutter run -t lib/main_dev.dart --dart-define=EMULATOR_HOST=<mac-ip>`.
   Allow "Local Network" when the phone asks.

## 10. Xcode by hand (only if bootstrap printed a warning)

`tool/bootstrap.sh` sets these with `tool/ios/configure_xcode.rb` when the
`xcodeproj` gem is installed. If it was not:

1. Runner target > Build Settings > **Code Signing Entitlements** =
   `Runner/Runner.entitlements` (all configurations).
2. Project Runner > Info > **Localizations**: add Arabic and English.
3. Drag `ios/Runner/ar.lproj/InfoPlist.strings` and
   `en.lproj/InfoPlist.strings` into the Runner group, target Runner
   ticked; Xcode groups them as one localized "InfoPlist.strings".
4. Separate Xcode schemes per flavor are not needed: the flavor is chosen
   by the Dart entry point (`-t lib/main_<flavor>.dart`) and the bundle id by
   `FLAVOR=<flavor> tool/bootstrap.sh`.

## 11. Sign-in with a WhatsApp code (Prompt 2)

Do steps 1 to 4 in **each** cloud project (dev, staging, prod). The local
emulators need none of this.

1. **Secrets** (Secret Manager). On any machine with `firebase-tools`:

   ```sh
   # A long random key for the keyed hashes of codes, numbers, devices, IPs.
   openssl rand -hex 32 | firebase functions:secrets:set OTP_HMAC_KEY --data-file=- --project dev
   # WhatsApp token. In dev and staging (fake sender) any text will do:
   echo unused | firebase functions:secrets:set WHATSAPP_ACCESS_TOKEN --data-file=- --project dev
   ```

   Never reuse the prod `OTP_HMAC_KEY` elsewhere, and never change it while
   codes are pending (they would stop matching for 5 minutes, nothing more).
2. **Custom tokens.** `verifyCode` signs a Firebase custom token, which needs
   the role **Service Account Token Creator** for the functions' service
   account. Google Cloud console > IAM > find
   `<project-number>-compute@developer.gserviceaccount.com` > Edit > Add
   role "Service Account Token Creator". Without it, sign-in fails with
   "internal" after a correct code.
3. **Authentication > Sign-in method > Email/Password: enable** (the email
   confirmation link needs it; nobody signs in with a password). Then
   **Authentication > Settings > User actions: untick "Enable create
   (sign-up)" and "Enable delete"**, so no account can be made outside our
   functions. Optional: **Templates > Email address verification** to set
   the sender name and the Arabic text.
4. **Auto-delete old sign-in records** (Firestore TTL, free):

   ```sh
   gcloud firestore fields ttls update expireAt --collection-group=otpCodes --enable-ttl --project <id>
   gcloud firestore fields ttls update expireAt --collection-group=otpLimits --enable-ttl --project <id>
   ```
5. **Real WhatsApp (prod; staging only if you want to test it).**
   1. business.facebook.com > create a Business portfolio, verify the
      business (needs the operator entity, spec section 7).
   2. developers.facebook.com > create an app of type Business > add
      **WhatsApp**. Add a phone number that is not used on a phone's
      WhatsApp app.
   3. WhatsApp Manager > **Message templates > Create > Authentication**,
      name `login_code`, "Copy code" button, languages **Arabic (ar)** and
      **English (en)**. Wait for approval.
   4. Create a **system user** with a permanent token (permission
      `whatsapp_business_messaging`) and store it:
      `firebase functions:secrets:set WHATSAPP_ACCESS_TOKEN --project prod`.
   5. Put the **Phone number ID** (not the number) in `functions/.env.prod`
      as `WHATSAPP_PHONE_NUMBER_ID`. If the template languages differ, set
      `WHATSAPP_TEMPLATE_LANG_AR` / `_EN`. `WHATSAPP_PROVIDER=meta` is
      already set for prod; the fake sender is refused there.
6. **Deploy** as in step 3.10. The new functions are `requestCode`,
   `verifyCode`, `confirmEmail` and `acceptConsents`.

**Where to find the code and the email link while testing**

- Local emulators: the terminal running `firebase emulators:start` prints
  `[fake WhatsApp] sign-in code 123456 for +20********01`. The Auth
  emulator prints the email confirmation link in the same terminal; open
  it in the Mac's browser. Optional: copy `functions/.secret.local.example`
  to `functions/.secret.local`.
- Cloud dev or staging (fake sender): Google Cloud console > **Logging >
  Logs Explorer**, filter `"fake WhatsApp"`. The confirmation email is
  really sent by Firebase, so use an inbox you can open.
