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
   the operating entity, which the lawyer confirmed; docs/DECISIONS.md).
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

**Staging without installing anything:** after steps 1 to 5 below, run
`bash tool/cloud_setup.sh staging school-carpool-staging <admin-email>` in
Google Cloud Shell. It does the rest of this section and the per-project
steps of sections 4 and 11 to 23 that a command can do, and prints what is
left. Guide: [docs/owner-cloud-shell.md](docs/owner-cloud-shell.md).

1. console.firebase.google.com > **Add project**. Suggested ids:
   `<yourname>-carpool-dev`, `-staging`, `-prod`. Turn Google Analytics
   **off** (not in our stack, and it collects data). Put the ids in
   `.firebaserc`.
2. **Upgrade to Blaze** (pay as you go). Cloud Functions need it. You pay
   nothing while usage stays in the free quotas; step 4 adds budget alerts.
3. **Location** (asked when you create Firestore): this is permanent.
   Hosting abroad in `europe-west1` (Belgium) is confirmed by the lawyer
   (docs/DECISIONS.md, 14 Nov 2026): use it for dev, staging and prod.
   Functions use `europe-west1` too
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
    npm ci --prefix functions   # locked versions; `npm install` if there is no package-lock.json yet
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

Owner decision (14 Nov 2026): point-in-time recovery (PITR) **on in prod**;
daily backups **on in prod only**. Install the Google Cloud CLI (`gcloud`) and log in.

- Daily backup, prod only, kept 7 days:

  ```sh
  gcloud firestore backups schedules create \
    --project=<prod-id> --database='(default)' \
    --recurrence=daily --retention=7d
  gcloud firestore backups schedules list --project=<prod-id> --database='(default)'
  ```

- Switch PITR on in prod (owner decision; it adds storage cost, COSTS.md):

  ```sh
  gcloud firestore databases update --project=<prod-id> \
    --database='(default)' --enable-pitr
  ```

  With PITR on you can read or restore data from any minute of the last
  7 days. Leave it on in prod.
- The restore drill: `docs/restore-test.md` (SETUP 23.7).

## 6. Sentry (free Developer plan)

1. sentry.io > sign up > choose the **Developer** (free) plan. Pick the EU
   data region if offered (hosting abroad is confirmed by the lawyer;
   docs/DECISIONS.md).
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
2. A push to `main` runs three jobs: Flutter (analyze, tests, screenshots),
   web/Android compile, and backend (Functions tests, rules tests on the
   emulators). A green check mark next to the commit means all passed.
   Other branches are checked only when started by hand (Actions > checks >
   **Run workflow**), to save minutes.
3. **Screenshots without a Mac:** open a run > scroll to **Artifacts** >
   download **screenshots** (a zip of PNGs: tab shell and gallery in Arabic
   and English, light and dark, design A and B).
4. **Package versions are locked.** The lock files (`pubspec.lock`,
   `functions/package-lock.json`) are committed and every build installs
   exactly those versions. They change only when someone starts the
   workflow by hand with **update_locks** ticked on a work branch; the
   steps are in docs/WORKFLOW.md, "Package versions".
5. **Before the public launch the repository goes private again**, and
   GitHub then counts the minutes: docs/launch-private-repo.md.

## 8. Codemagic (iPhone builds)

1. codemagic.io > sign up with GitHub (free personal plan: 500 macOS
   minutes a month).
2. **Add application** > the GitHub repository > Flutter App > "Use
   codemagic.yaml".
3. App settings > **Environment variables**: create the groups
   `dev_defines` and `staging_defines` with the Sentry DSNs (mark them
   **Secret**).
4. Codemagic only builds the iPhone app, and only when asked (500 free
   minutes a month): `ios-staging` when you press **Start new build** or
   push a tag `v*` (for example `v0.1.0`); `ios-dev` only on **Start new
   build**. A push to `main` starts no build. Until steps 1 to 3 are done
   for staging, a staging build fails or opens on an error screen.

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
   With this provider on, a password reset sent to a parent's inbox could
   otherwise open the account without the phone. The functions
   `blockNonCodeSignIn` and `blockSignInEmails` (Identity Platform
   blocking functions, free tier) refuse every password, email-link, SMS
   and anonymous sign-in and never send password-reset or sign-in emails.
   They register themselves on deploy; check **Authentication > Settings >
   Blocking functions** shows them for "Before sign in" and "Before email
   sent". Only the WhatsApp code (custom token) signs in.
4. **Auto-delete old sign-in records** (Firestore TTL, free):

   ```sh
   gcloud firestore fields ttls update expireAt --collection-group=otpCodes --enable-ttl --project <id>
   gcloud firestore fields ttls update expireAt --collection-group=otpLimits --enable-ttl --project <id>
   ```
5. **Real WhatsApp (prod; staging only if you want to test it).** The
   full owner guide, click by click, with documents, waiting times,
   limits and prices, is **docs/meta-whatsapp-setup.md**. Start its
   business verification step first: it is the slowest item of the launch.
   In short:
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

7. **Check the per-IP limit sees real client addresses** (once per
   project, after the first deploy). Ask for a code once on Wi-Fi and once
   on mobile data. Logs Explorer, filter `requestCode`: the two log lines
   must show different `ipKeyPrefix` values (a hash, not the IP). If they
   are the same, set `CLIENT_IP_HOP=2` in `functions/.env.<alias>` and
   deploy again. The cap itself is `OTP_MAX_SENDS_PER_IP` (60 an hour).

**Where to find the code and the email link while testing**

- Local emulators: the terminal running `firebase emulators:start` prints
  `[fake WhatsApp] sign-in code 123456 for +20********01`. The Auth
  emulator prints the email confirmation link in the same terminal; open
  it in the Mac's browser. Optional: copy `functions/.secret.local.example`
  to `functions/.secret.local`.
- Cloud dev or staging (fake sender): Google Cloud console > **Logging >
  Logs Explorer**, filter `"fake WhatsApp"`. The confirmation email is
  really sent by Firebase, so use an inbox you can open.

## 12. Identity verification (Prompt 3)

1. **Secret for the ID number hash** (each cloud project; never rotate it
   without re-hashing, the ban list depends on it):
   `openssl rand -hex 32 | firebase functions:secrets:set NATIONAL_ID_HMAC_KEY --project dev --data-file=-`
   The emulators use a fixed dev key when it is not set.
2. **Provider settings** in `functions/.env.<alias>`: `KYC_PROVIDER=fake`
   (default; refused when `APP_ENV=prod`) or `valify` once the contract is
   signed (`VALIFY_ENABLED=true`, `VALIFY_BASE_URL`, `VALIFY_USERNAME`,
   `VALIFY_CLIENT_ID`, `VALIFY_BUNDLE_KEY`, and the secrets
   `VALIFY_CLIENT_SECRET`, `VALIFY_PASSWORD`). The Valify class is a stub
   that fails closed (result "error", manual review) until then.
3. **Fake check result:** Firestore document `config/kyc` with
   `fakeResult` = `match` | `no_match` | `error`, or
   `npm --prefix functions run review:emulator -- kyc no_match`.
4. **Deploy:** `firebase deploy --only firestore:rules,firestore:indexes,storage,functions --project dev`.
   The deploy creates the daily Cloud Scheduler job
   (`purgeVerificationImagesDaily`, 03:10 Cairo time).
5. **Review a case before the admin panel (Prompt 4):**
   - Emulators: `npm --prefix functions run review:emulator -- queue`, then
     `... -- approve <caseId>` or `... -- reject <caseId> selfie_mismatch [note]`.
   - Cloud dev project: `gcloud auth application-default login`, then
     `REVIEW_PROJECT=<dev project id> npm --prefix functions run review:cloud -- queue`
     (projects with "prod" in the name are refused).
   - To use the admin functions from a client, give an account the admin
     claim: `... -- grant-admin <uid>`.
6. **Turn off soft delete on the bucket** (each project). New Cloud
   Storage buckets keep deleted files for 7 days by default, which would
   keep verification images for up to 13 days after the decision (spec:
   within 7 days, backups included):
   `gcloud storage buckets update gs://<project-id>.firebasestorage.app --clear-soft-delete`
   (older projects: `gs://<project-id>.appspot.com`). Check with
   `gcloud storage buckets describe gs://<bucket> --format="value(soft_delete_policy)"`.
7. **Prod uses `KYC_PROVIDER=valify`** (`functions/.env.prod`). With the
   fake there, every instance logs a CONFIGURATION ERROR at start and
   reports it to Sentry, and submissions answer "not configured".
8. **Bucket:** the default Firebase bucket is private: no public access,
   and storage.rules let a parent only upload into their own
   `verification/{uid}/pending/` folder. Nobody reads images through the
   SDK; admins get 5-minute signed links from `openVerificationCase`.

## 13. Admin web panel (Prompt 4)

The panel is a Flutter web app in this repository
(`lib/admin/main_admin_<flavor>.dart`) on its own Firebase Hosting site.
Admins are separate email accounts (no phone number) with the `admin`
custom claim (`superAdmin` too for super admins), a password and a TOTP
authenticator app. Parents cannot sign in there: their accounts have no
password and the blocking function refuses a password for any account
without the claim.

### 13.1 Turn on two-step sign-in (each cloud project, once)

1. Authentication must be on the Identity Platform tier (step 3). TOTP has
   no per-message charge (only SMS does, and we use none).
2. In Authentication > Sign-in method, Email/Password stays **on** (it is
   already on for the email confirmation link). Email link sign-in stays off.
3. `gcloud auth application-default login`, then
   `ADMIN_PROJECT=<project id> npm --prefix functions run admins:cloud -- enable-totp`.
4. **Check it:** `ADMIN_PROJECT=<project id> npm --prefix functions run admins:cloud -- check-totp`
   must print "OK, TOTP is on". In the printed settings,
   `multiFactorConfig.state` is `DISABLED`: that switch is for **SMS**
   second factors (kept off; the Admin SDK requires the field, so it
   cannot be left out), and the `providerConfigs` entry with
   `totpProviderConfig` has state `ENABLED`. Also look in the Firebase
   console: Authentication > Settings > Multi-factor authentication should
   show TOTP on and SMS off.

### 13.2 The first super admin (each cloud project, once)

`ADMIN_PROJECT=<project id> npm --prefix functions run admins:cloud -- create-super-admin you@example.com "Your Name"`

It prints a one-time link (valid 1 hour) where that person sets their
password. For a project with "prod" in its id add `CONFIRM_PROD=yes`.
Every later admin is created in the panel (Admins page, super admins only):
the panel shows the new admin's one-time link once; pass it on directly.
At first sign-in the panel asks the admin to add the authenticator app
(Google or Microsoft Authenticator: type the setup key), then to sign in
again with both steps.

The old `review ... grant-admin <uid> --allow` command (Prompt 3) now
refuses parent accounts (any account with a phone number), needs the
`--allow` flag, writes the admin record and logs itself in the audit log.
Prefer the commands above.

### 13.3 Hosting site for the panel (each cloud project, once)

1. Firebase console > Hosting > Add another site, for example
   `<project id>-admin`.
2. `firebase target:apply hosting admin <site id> --project dev` (writes
   the mapping into `.firebaserc`; the emulator project is mapped already).
3. Build and deploy:
   ```
   FLAVOR=dev tool/bootstrap.sh
   flutter build web --release -t lib/admin/main_admin_dev.dart \
     --dart-define=USE_EMULATORS=false --dart-define=RECAPTCHA_SITE_KEY=<key>
   rm -rf build/admin_web && mv build/web build/admin_web
   firebase deploy --only hosting:admin --project dev
   ```
   `firebase.json` sends security headers for the site (no framing,
   no-referrer, no indexing by search engines).
4. **App Check on the web:** create a reCAPTCHA Enterprise key for the
   admin site's domain and register it in Firebase App Check (Web app).
   Pass it as `RECAPTCHA_SITE_KEY`. Without it the admin functions refuse
   calls in staging and prod (`ENFORCE_APP_CHECK=true`).
5. **Authorized domains:** Authentication > Settings > Authorized domains:
   add the admin site's domains (`<site id>.web.app`, `<site id>.firebaseapp.com`).
6. **Images in the panel (Storage CORS):** the panel draws document images
   on the canvas (never as a downloadable `<img>`), which needs CORS on the
   bucket for the admin site only. `tool/storage_cors.json` holds the
   staging admin site (`school-carpool-staging-admin`); for another project
   put that project's admin site domains in it, then
   `gsutil cors set tool/storage_cors.json gs://<bucket>`.
7. **Deploy the rules, indexes and functions:**
   `firebase deploy --only firestore:rules,firestore:indexes,functions --project dev`.

### 13.4 On the emulators (dev)

1. `firebase emulators:start --project demo-school-carpool`
2. `npm --prefix functions run seed:emulator`: adds two dev admins
   (`superadmin@example.com` and `reviewer@example.com`, password
   `dev-only-password`), two cases waiting for review with fake document
   images, two "Other" schools and three reports.
3. `flutter run -d chrome -t lib/admin/main_admin_dev.dart`
4. The Auth emulator has no TOTP, so on the emulators only the second step
   is skipped (in the panel and in the functions). Cloud projects always
   require it; there is no setting that turns it off.

### 13.5 Sessions and access

- The sign-in lasts only as long as the browser tab (session persistence).
- 15 minutes without a click, key press or scroll: the panel signs out.
  The functions enforce the same limit on their side: every admin call
  checks `admins/{uid}.lastActiveAt` (written at most once a minute) and
  the sign-in time; while the admin is active the panel calls `adminPing`
  at most every 5 minutes, so reading a long case is not idle.
- The functions and the rules refuse a sign-in older than 8 hours.
- Disabling an admin revokes their refresh tokens and sets
  `admins/{uid}.revokedAt`; the functions and the rules refuse any token
  issued before it, so access ends at once (not when the 1-hour ID token
  expires). The rules do not check idle time (the panel never reads
  Firestore directly; the functions do).
- No account can be created from a client: the `blockClientSignUps`
  blocking function (beforeUserCreated) refuses password sign-ups, email
  links and every other provider. Parents and admins are created by our
  functions with the Admin SDK. After deploying, check in Authentication >
  Settings > Blocking functions that it is set for "Before account
  creation".

### 13.6 Maps in the panel (later)

School and area pins are typed as "latitude, longitude" (copied from
Google Maps) with a placeholder where the map goes. To show a real map:
a Maps JavaScript API key restricted to the admin site's domain, the
`google_maps_flutter` package (with its web implementation) and the
script tag in `web/index.html` (added by tool/bootstrap.sh). Owner decision
(open question in docs/progress/prompt-04.md).

## 14. Schools list (Prompt 4B)

The schools parents pick from come from an import (Python 3.11 or newer,
nothing to install). Search runs on Algolia in staging and prod; dev uses a
fake search on the emulators, so no Algolia account is needed to work on
the app.

**Staging does all of 14.1 to 14.4 by itself** (owner decision 15 Nov
2026: every school and kindergarten we can get from open data): step 12 of
`tool/cloud_setup.sh` downloads the OpenStreetMap list, imports it with any
CSV lists you put in `data/schools/`, loads it and sends it to Algolia;
step 6 asks once for the Algolia keys (docs/algolia-setup.md). The rest of
this section is what it does, for a Mac or for prod.

### 14.1 Download the data

0. **OpenStreetMap through the Overpass API (what staging uses).**
   ```sh
   python3 tools/import_schools/fetch_osm_schools.py
   ```
   Asks a public Overpass server (overpass-api.de, then
   overpass.private.coffee, then maps.mail.ru; a busy server moves on to
   the next at once, a pause only after every server failed, two rounds)
   with a **broad** query: every `amenity=school|kindergarten`,
   `education=school|kindergarten`, a named `building=school|kindergarten`,
   a named feature with `school=*` or `isced:level=*`, and any feature
   (not a street) whose `name`, `name:ar` or `name:en` reads like a school
   (starts with مدرس / مدارس / روض / حضان, optionally after "ال" or "مجمع",
   or contains school / kindergarten / KG). The download is wider than
   what is kept: the importer (`classify_tags`) alone decides, and the
   report lists every drop reason (university, college, courses/centres/
   academies, childcare, named like a school but a street/shop/place/
   historic madrasa/pitch, building part, no name, ...). Unnamed schools
   take `official_name`, `alt_name`, `short_name` or a school-like
   `operator` (never the ministry). If the broad query fails everywhere,
   the old narrow query (`amenity` only) is used. Also downloads the
   27 governorate borders (`admin_level=4`, `ISO3166-2=EG-*`). Writes
   `data/schools/osm/egypt_schools_osm.geojson` (same columns as the HDX
   export below, so the IDs are the same), `data/schools/osm/fetch_report.md`
   (date, server, counts, licence) and
   `data/schools/boundaries/egypt_governorates_osm.geojson`. A border with
   a gap in OpenStreetMap is left out (the nearest town is used there).
   `--max-age-days 7` keeps a download newer than a week; a download that
   fails or comes back nearly empty keeps the earlier file. All of it is
   git-ignored. The data is (c) OpenStreetMap contributors under the ODbL
   1.0 (<https://www.openstreetmap.org/copyright>); the attribution belongs
   in the app's licences screen before the public launch (open item).
   With this download you do not need the HDX files of step 1 (if both are
   there, the HDX copies are listed as "same source ID twice").
   **Per governorate (since 16 Nov 2026):** the broad query for all of Egypt
   timed out on every public server, so it runs once per governorate (27
   parts, `[timeout:180]` each, search area = the governorate's boundary
   relation, failover between the servers, a second pass for the parts that
   failed). Each part is kept in `data/schools/osm/governorates/EG-xx.geojson`
   with its own date; a part newer than `--max-age-days` is not asked again,
   and a part that still fails keeps its older file (the report lists the
   status and date per governorate; "NO data" means it has never been
   downloaded). The narrow amenity-only query for all of Egypt runs as a
   safety net, and everything is merged with each OSM object once.
   `--max-minutes` (default 75) caps the time spent on new requests. The
   places download (14.6) is split the same way.
   **What counts:** `data/schools/categories.json` (owner decision 16 Nov
   2026: schools, kindergartens and nurseries; universities off; Al-Azhar
   institutes are schools).
   **Wikidata (second source):**
   `python3 tools/import_schools/fetch_wikidata_schools.py` asks the
   Wikidata Query Service (query.wikidata.org) for items of class school
   (Q3914) or kindergarten (Q126807) or any subclass, country Egypt (Q79),
   with coordinates (P625), not dissolved, with Arabic and English labels.
   Writes `data/schools/wikidata/egypt_schools_wikidata.geojson` and a
   fetch report (git-ignored). Classes that are not schools for us
   (universities, colleges, music/driving schools, historic
   madrasas; an Egyptian "language school" stays a school) become tags the importer drops. An OSM school tagged
   `wikidata=Q..` absorbs that item (its labels fill missing Arabic or
   English names); other overlaps are merged by the usual name + 300 m
   rule. Wikidata is CC0 (no attribution required; we credit "Wikidata"
   in the licences screen with OpenStreetMap). The User-Agent
   carries a contact, as Wikimedia's User-Agent policy asks:
   `tool/cloud_setup.sh` uses the `<admin-email>` argument unless
   `WIKIDATA_CONTACT` (an email or web page) is set; run by hand, set
   `WIKIDATA_CONTACT` yourself. A 403 answer means the service refused
   the request.
   **Overture Maps Places (third source):**
   `python3 -m pip install --user duckdb` once, then
   `python3 tools/import_schools/fetch_overture_schools.py --max-age-days 30`.
   Reads Overture's latest release (named by
   <https://stac.overturemaps.org/catalog.json>) straight from its public
   S3 bucket with DuckDB, only Egypt's box, places whose taxonomy category
   is a school, kindergarten, preschool or nursery (or has one as an
   alternate), confidence at least 0.2. Writes the raw rows to
   `data/schools/overture/raw/` and, for the import, those with confidence
   at least `--min-confidence` (default 0.5), not permanently closed and
   not in another country, to `data/schools/overture/egypt_schools_overture.geojson`
   (all git-ignored). `--from-raw --min-confidence 0.7` converts again with
   another threshold without downloading. The report counts rows per
   category, confidence band and upstream dataset. The importer applies the
   OSM keep/drop rules plus a name check (a "school" category whose name
   says courses, centre or university is dropped) and merges an Overture
   place into the OSM or Wikidata school with the same name within 300 m.
   Licence: CDLA Permissive 2.0 (most providers), Apache 2.0 (Foursquare),
   CC0 (AllThePlaces); the attribution is open item D24.
   **Why is a school missing?**
   `python3 tools/import_schools/why_missing.py "<name>" ...` (or
   `--file names.txt`) runs the import on the downloads and says, for each
   name, which source has it and whether it was kept, merged into another
   entry, or dropped (and why), or that no source has it. Step 12 runs it on
   `data/schools/check_names.txt` when that file exists (one name per line;
   see `data/schools/check_names.example.txt`).
1. **OpenStreetMap schools (HDX).** Open
   <https://data.humdata.org/dataset/hotosm_egy_education_facilities>
   ("Egypt Education Facilities (OpenStreetMap Export)", by the
   Humanitarian OpenStreetMap Team). If the link moved, search HDX for
   "Egypt Education Facilities". Download the **GeoJSON** points and
   polygons files (`hotosm_egy_education_facilities_points_geojson.zip`
   and `..._polygons_geojson.zip`, or the CSV). Put the zip files as they
   are into `data/schools/` (they are not committed: `data/schools/.gitignore`).
2. **Ministry, governorate or school-group lists (optional).** Save each as
   CSV (UTF-8) in `data/schools/`. Accepted headers, English or Arabic
   (other columns are listed in the report and ignored):
   `source_id`/`code`/`كود المدرسة`, `name_ar`/`اسم المدرسة`,
   `name_en`/`اسم المدرسة بالانجليزي`, `governorate`/`المحافظة`,
   `city`/`district`/`الإدارة`/`الحي`, `kind`/`stage`/`المرحلة`, and
   `lat`+`lng` or `خط العرض`+`خط الطول` (optional). The file name becomes
   the source (`list_<file name>`), so keep the name the same between runs.
3. **Governorate boundaries (optional, recommended).** OpenStreetMap
   points rarely say which governorate they are in; without boundaries the
   tool uses the nearest town, which can be wrong within a few kilometres
   of a border. Download "Egypt - Subnational Administrative Boundaries"
   from HDX (admin level 1, GeoJSON) and put it in
   `data/schools/boundaries/`.

### 14.2 Run the import and read the report

```sh
python3 tools/import_schools/import_schools.py
# writes build/schools/schools.json and build/schools/report.md
```

The report lists schools per governorate, what was dropped and why
(no name, only "school" as a name, universities and courses, outside
Egypt...), the duplicates it merged (same or similar name within about
300 m, Arabic spelling differences ignored), and **likely duplicates** it
did not merge, for you to check. Schools of a different stage (KG,
primary, preparatory, secondary) or for boys and for girls are never
merged, even with the same name; a pair where only one name says the
stage, where one name is inside the other, or where a person's name
differs ("الشهيد أحمد" / "الشهيد محمد") is listed, not merged. CSV files
saved by Excel (UTF-8 with BOM, "Unicode text", older Arabic Windows
encoding, comma, semicolon or tab) are read; a file that cannot be read
is listed under "Problems with the input files". Running it again on the same files gives
the same IDs.

Try it first with the hand-written sample (not real data):
`python3 tools/import_schools/import_schools.py --input data/schools/sample`.

### 14.3 Load into Firestore

- **Emulators (dev):** start the emulators, then
  `npm --prefix functions run schools:load:emulator`.
- **Cloud project:** `gcloud auth application-default login`, then
  `SCHOOLS_PROJECT=<project-id> npm --prefix functions run schools:load:cloud -- --dry-run`
  to see what would change, and the same with `--yes` to write.

Loading twice never creates duplicates: schools are matched by ID and by
every source key, unchanged schools are not written, schools an admin
edited or merged are left alone, and nothing is deleted. Writes go in
batches of 400 with progress lines and retries; if it stops half way, run
it again (what was written is matched and not written twice). Never load
the sample into prod.

`--hide-sample build/schools-sample/schools.json` (used by cloud_setup
once a real list is loaded): the hand-written sample schools already in
the project get `searchHidden: true`. They stay as documents (a test child
or carpool may point at one) but leave search. Admin-edited ones are left
alone.

Cost of the first real load: about one write per school (20,000 to 30,000;
Firestore's free tier is 20,000 writes a day, so a few US cents at most)
and one read per school per run. With Algolia on, each new school also
triggers `syncSchoolToSearch` once (free function quota).

### 14.4 Algolia (before staging tests; not needed for dev)

**Staging:** follow docs/algolia-setup.md (sign up, then give the three
values to `tool/cloud_setup.sh` when it asks; `--replace-algolia` to change
them). It stores the keys, sets `SCHOOL_SEARCH_PROVIDER=algolia`,
`ALGOLIA_APP_ID` and `ALGOLIA_INDEX=schools_staging`, deploys, and runs
`schools:algolia -- sync` (settings, then every active school in batches of
1,000, and removal of merged, pending and hidden ones; the index is never
emptied, so search keeps working). By hand:

```sh
ALGOLIA_APP_ID=... ALGOLIA_WRITE_KEY=... ALGOLIA_INDEX=schools_staging \
SCHOOLS_PROJECT=<staging-project-id> npm --prefix functions run schools:algolia -- sync
```

**Prod, or index-limited keys** (the manual way):

1. Create an Algolia account and one application. Create one index per
   project: `schools_dev` (optional), `schools_staging`, `schools`.
2. Apply the settings and send the schools once (admin key from Algolia's
   API keys page, on your Mac only, never committed):
   ```sh
   ALGOLIA_APP_ID=... ALGOLIA_ADMIN_KEY=... ALGOLIA_INDEX=schools_staging \
   SCHOOLS_PROJECT=<staging-project-id> npm --prefix functions run schools:algolia -- reindex
   ```
3. In Algolia > API keys, create two keys **limited to that index**:
   - a **write** key with `addObject` and `deleteObject` only;
   - a **search-only** key with `search` only, max hits per query 20 and
     max queries per IP per hour **100**. The app's keys carry a user
     token, so Algolia counts this limit per parent, not per IP address
     (many phones share one address on Egyptian mobile networks). Each
     parent gets at most 6 keys a day (`searchKeyLimits`), so one account
     can make at most about 600 search requests a day.
4. Store them in Secret Manager for the project:
   `firebase functions:secrets:set ALGOLIA_WRITE_KEY --project staging` and
   `firebase functions:secrets:set ALGOLIA_SEARCH_KEY --project staging`.
   In dev (fake search), set both to `unused`: the functions declare them.
5. In `functions/.env.staging` (and `.env.prod`):
   `SCHOOL_SEARCH_PROVIDER=algolia`, `ALGOLIA_APP_ID=<app id>`,
   `ALGOLIA_INDEX=schools_staging`. Deploy the functions.

The prod project refuses `SCHOOL_SEARCH_PROVIDER=fake` (the function
answers "not configured" and reports to Sentry): set up Algolia before
prod. From then on `syncSchoolToSearch` keeps the index in step: active schools
are indexed with their names and places only; schools awaiting review,
merged schools and hidden sample schools are not. Without Algolia, a cloud
build's school search reads at most 200 schools; when that is not the
whole list it shows "search unavailable" instead of part of the list. The app never holds an Algolia secret: it asks
`getSchoolSearchKey` for a key that can only search that index and expires
after an hour. If the index ever drifts, run the `reindex` command again.

### 14.5 "Other" schools

A parent whose school is missing types its name and governorate (and may
paste a pin) under "Other". It waits in the admin panel's **New schools**
queue, visible only to that parent. Approve it (fix the names, add the
city and pin) or merge it into an existing school; once approved it is
indexed and every parent finds it.

### 14.6 City -> Area -> District (F4 grouping, F46 addresses)

Owner decision 16 Nov 2026 (docs/DECISIONS.md): schools and home addresses
use City (governorate) -> Area (qism, markaz or new city) -> District
(neighbourhood). Not the per-school `areas` of carpools, which stay.

1. **Download** (step 12 does it, after the schools, starting with the
   Overpass server that just answered):
   `python3 tools/import_schools/fetch_osm_places.py` writes every
   administrative boundary of `admin_level` 5 to 10 inside Egypt and every
   named `place=suburb|quarter|neighbourhood` to `data/schools/places/`
   (git-ignored), shapes simplified to about 30 m.
2. **Which level is which is measured, not assumed:** the import counts,
   for each level, the share of schools inside its polygons (report.md,
   "Places"). Area = the finest of levels 5 to 7 covering at least half
   the schools (else the best covered); where it has no polygon, a coarser
   level is used, then a finer one. District = the finest of 8 to 10
   covering 30 % (same fallback); where no district boundary holds a
   point, the nearest named place of that area within 1.5 km. A list entry
   without a pin gets its area from its district column ("قسم"/"مركز"
   ignored). Each school gets `placeAreaId`, the area's names and
   `placeDistrictId`; `build/schools/places.json` lists the areas and
   districts.
3. **Load:** `schools:load:cloud` also loads `places.json` (next to
   `schools.json`, or `--places <file>`) into `placeAreas`,
   `placeDistricts` and `placeIndex/areas` (the server's lookup table):
   new and changed places only, admin edits kept, school counts
   recomputed. Rules: signed-in users read areas and districts; nobody
   writes them from a client.
4. **Admin panel > Places:** City -> Area -> District with school and
   address counts; add, rename, deactivate, merge duplicates; the "new
   districts" queue (parents' "My district isn't listed"). Schools list:
   City and Area filters and an Area column; a school's page: "Move to
   area". Every change is in the audit log.
5. **App:** the school picker has "By area" (City -> Area -> the area's
   schools); search can be narrowed to an area (Algolia `placeAreaId`
   filter, set by `schools:algolia -- settings`/`sync`). The home address
   (F46) uses the same dropdowns: no setup beyond the deploy
   (`setHomeAddress`, `geocodeAddress`, `placeForPoint`); the address
   search uses the existing Places key and limits.

Dev and tests use the hand-written sample in `data/schools/sample/places`
(rough boxes, not real borders).

## 15. Maps, home and nearby parents (Prompt 5)

Keys are never committed. Each Firebase project (dev, staging, prod) is a
Google Cloud project; make the keys in that project.

### 15.1 Turn on the APIs (each cloud project)

console.cloud.google.com > APIs & Services > Library: enable **Maps SDK for
iOS**, **Maps SDK for Android** (Stage 3) and **Places API (New)**. Maps
JavaScript API waits for the website (Stage 2).

### 15.2 Three keys per project

APIs & Services > Credentials > Create credentials > API key, three times:

| Key | Application restriction | API restriction | Where it goes |
| --- | --- | --- | --- |
| iOS maps key | iOS apps: `org.schoolcarpool.app.dev` (`.stg`, or the prod id) | Maps SDK for iOS | Codemagic environment group (`dev_defines` / `staging_defines`) as `MAPS_API_KEY_IOS` |
| Server Places key | None possible for Cloud Functions; keep the API restriction | Places API (New) only | Secret Manager: `firebase functions:secrets:set MAPS_SERVER_KEY --project staging` |
| Android maps key (Stage 3) | Android apps: package name + SHA-1 | Maps SDK for Android | `MAPS_API_KEY_ANDROID` in the Android build environment |

In dev on the emulators nothing is needed: the Places search is fake and
the maps are drawn by a sketch marked "Preview". Set
`firebase functions:secrets:set MAPS_SERVER_KEY` to `unused` in a cloud
project that still uses the fake search (the functions declare it).

### 15.3 Functions settings

In `functions/.env.staging` (and `.env.prod`): `PLACES_PROVIDER=google`.
Optional limits (defaults in brackets): `MAP_HOME_MOVES_PER_DAY` (4),
`MAP_NEARBY_SEARCHES_PER_HOUR` (30), `MAP_PLACE_SEARCHES_PER_HOUR` (60),
`MAP_PLACE_DETAILS_PER_HOUR` (20, picked addresses not in the cache),
`MAP_DRIVING_SCHOOL_CHANGES_PER_DAY` (3). Deploy the functions and the
Firestore indexes (`firebase deploy --only functions,firestore:indexes`;
the nearby search needs the `parentLocations` index).

Firestore > TTL policies: add a policy on collection group `placeCache`,
field `expiresAt` (cached addresses are deleted after 30 days).

### 15.4 Caps and budget (each project)

APIs & Services > each Maps API > Quotas: set "requests per day" to about
300 for Places API (New) (autocomplete and details) so a bug cannot pass
the free monthly calls. The budget alert from section 4 stays on.

### 15.5 Build with a key

- **Codemagic:** add `MAPS_API_KEY_IOS` to the environment group. The
  bootstrap writes it into `ios/Flutter/Maps.xcconfig` (generated, not
  committed), `Info.plist` reads it as `GMSApiKey`, `AppDelegate.swift`
  passes it to Google Maps, and the build adds
  `--dart-define=MAPS_ENABLED=true` when the key is set.
- **On a Mac:** `MAPS_API_KEY_IOS=<key> FLAVOR=dev tool/bootstrap.sh`, then
  `flutter run -t lib/main_dev.dart --dart-define=MAPS_ENABLED=true`
  (add `--dart-define=EMULATOR_HOST=<Mac LAN address>` on a real iPhone).
- Without a key the app never crashes: dev shows the sketch map,
  staging and prod show "Map unavailable" and the address search still
  works.
- If bootstrap printed "could not find didFinishLaunchingWithOptions",
  open `ios/Runner/AppDelegate.swift` and add, at the start of that
  function: `if let key = Bundle.main.object(forInfoDictionaryKey:
  "GMSApiKey") as? String, !key.isEmpty { GMSServices.provideAPIKey(key) }`
  and `import GoogleMaps` at the top.

### 15.6 Fake nearby parents (emulators)

`npm --prefix functions run seed:emulator` adds eight fake verified
parents around Maadi whose children go to "Nile International School
(test)" (one hides from the map). Set your home in Maadi and pick that
school for your child to see them.

## 16. Carpools and invite links (Prompt 6)

### 16.1 Functions settings (each cloud project)

In `functions/.env.dev`, `.env.staging` and `.env.prod` set
`INVITE_LINK_BASE` to the links site of that project (16.2), for example
`https://<project id>-links.web.app`. Optional limits (defaults in
brackets): `CARPOOL_CREATES_PER_DAY` (3), `CARPOOL_SEARCHES_PER_HOUR` (30),
`CARPOOL_JOIN_REQUESTS_PER_DAY` (10), `CARPOOL_INVITES_PER_DAY` (20),
`CARPOOL_INVITE_OPENS_PER_HOUR` (20), `CARPOOL_WANTED_SAVES_PER_DAY` (5),
`CARPOOL_WANTED_LISTS_PER_HOUR` (30). Deploy rules, indexes and functions:
`firebase deploy --only firestore:rules,firestore:indexes,functions --project dev`
(the activity search needs the `carpools` index on kind, status and
`activity.geohash`).

### 16.2 The links site (each cloud project, once)

The invite link `https://<links site>/c/<code>` opens the app on an
iPhone that has it (universal links) and a short page otherwise. The page
never shows anything about the carpool.

1. Firebase console > Hosting > Add another site, for example
   `<project id>-links`.
2. `firebase target:apply hosting links <site id> --project dev`.
3. Build and deploy the site (your Apple Team ID is in the Apple Developer
   account > Membership; the bundle id of the flavor is
   `org.schoolcarpool.app.dev`, `.stg` or the prod id):
   ```
   python3 tool/links_site.py --team-id <TEAM ID> --bundle-id org.schoolcarpool.app.dev \
     [--app-store-url https://apps.apple.com/app/id<numeric id>]
   firebase deploy --only hosting:links --project dev
   ```
   `firebase.json` serves `/.well-known/apple-app-site-association` as JSON
   and every `/c/...` path as the fallback page.
4. Check: open `https://<site id>.web.app/.well-known/apple-app-site-association`
   in a browser; it shows your Team ID and bundle id.

### 16.3 Associated Domains on the iPhone app (each flavor, once)

1. Apple Developer > Certificates, Identifiers & Profiles > Identifiers >
   the App ID (`org.schoolcarpool.app.dev`, `.stg`, prod) > tick
   **Associated Domains** > Save. Codemagic makes new profiles on the next
   build (`xcode-project use-profiles`).
2. Add `INVITE_LINK_DOMAIN=<site id>.web.app` (host only, no https://) to
   the Codemagic environment group of that flavor (`dev_defines`,
   `staging_defines`). On a Mac: `INVITE_LINK_DOMAIN=<site id>.web.app
   FLAVOR=dev tool/bootstrap.sh`.
3. The bootstrap then adds `applinks:<site id>.web.app` to
   `Runner.entitlements`. Leave `INVITE_LINK_DOMAIN` empty until step 1 is
   done: signing fails when the entitlement is there but the App ID lacks
   the capability.
4. Test: send yourself an invite link in WhatsApp or Notes on the iPhone
   and tap it. The app opens on the invite screen. iOS caches the
   association file; after changing it, delete and reinstall the app.

Android App Links (`assetlinks.json`) come with Stage 3.

### 16.4 Expiry (each cloud project)

Firestore > TTL policies: add policies on collection `carpoolInvites`,
field `expiresAt` (invite codes, 14 days), and on collection
`carpoolWanted`, field `expiresAt` ("looking for a carpool" posts,
60 days).

### 16.5 Two fake parents on the emulators

`npm --prefix functions run seed:emulator` gives the fake parents Hoda
(`seed-map-parent-1`), Tarek and Rania approved cars, and adds a ready
carpool by Hoda at "Nile International School (test)" (`seed-carpool-1`).
Play a second parent from the Mac with
`npm --prefix functions run carpool:emulator -- <command> --as <uid>`
(`search`, `request`, `approve`, `consent`, `invite`, `mine`; the header of
`functions/scripts/carpool.ts` lists them). You can also sign in as Hoda on
a second phone or simulator with her fake number `+201000000101` (the code
is printed in the emulator log).

## 17. Schedule (Prompt 7)

### 17.1 Functions settings and deploy (each cloud project)

Optional settings in `functions/.env.dev`, `.env.staging`, `.env.prod`
(defaults in brackets): `SCHEDULE_CONFIRM_BY` (`21:00`, Cairo time on the
evening before each run: drivers confirm by then), `SCHEDULE_LATE_LEAD_MIN`
(60: a run planned or released after that time must be confirmed this many
minutes before it starts), `SCHEDULE_PLANS_PER_DAY` (20),
`SCHEDULE_CHANGES_PER_DAY` (100). Deploy rules, indexes and functions:
`firebase deploy --only firestore:rules,firestore:indexes,functions --project dev`.
The scheduled function `scheduleTick` needs the two collection group
indexes on `schedule` (status + confirmBy, status + startAt); the deploy
creates them, and Cloud Scheduler gets the job (Africa/Cairo, every 15
minutes) on the first deploy.

### 17.2 Expiry (each cloud project)

Firestore > TTL policies: add a policy on collection `scheduleEvents`,
field `expiresAt` (alert events, 30 days).

### 17.3 The schedule on the emulators

The emulators do not run scheduled functions by themselves. Run the tick
by hand (cut-offs and the drive balance, now):
`npm --prefix functions run carpool:emulator -- tick --as any`.
Play the second fake parent (Hoda, `seed-map-parent-1`) with the schedule
commands in the header of `functions/scripts/carpool.ts`: `days`, `runs`,
`confirm`, `swap`, `take`, `absent`, `plan`.

### 17.4 Firestore backups

Unchanged from section 5: daily backups in prod only, point-in-time
recovery off for now. The schedule lives in Firestore under
`carpools/{id}/schedule`, `swaps`, `exceptions` and `balances`, so the
daily backup covers it.


## 18. Notifications: push and WhatsApp (Prompt 8)

One Cloud Function, `sendNotification`, sends every notification. Every
producer (schedule flows, join requests, verification decisions, the
new-parent event, the reminder and alarm tick) writes an event to
`notificationEvents`; the function writes the in-app record
(`users/{uid}/notifications/{eventId}`), sends the push to each of the
parent's phones and, when that group is on, the WhatsApp template.

### 18.1 Push on the iPhone: APNs key (each cloud project, once)

1. Apple Developer > Identifiers: the three App IDs already have **Push
   Notifications** (step 1.2). Nothing to add.
2. Apple Developer > Keys: the APNs `.p8` key from step 1.3 works for every
   App ID of the team. Keep the Key ID and Team ID.
3. Firebase console, **for each project (dev, staging, prod)** > Project
   settings > Cloud Messaging > Apple app configuration > the iOS app of
   that project > **APNs Authentication Key > Upload**: the `.p8`, its Key
   ID and the Team ID. (Same as step 3.7; check it is done in all three.)
4. Without this, FCM accepts the token but nothing reaches the iPhone.

### 18.2 Functions settings (each cloud project)

In `functions/.env.dev`, `.env.staging`, `.env.prod`:

| Setting | Value | Notes |
| --- | --- | --- |
| `PUSH_PROVIDER` | `fcm` in dev (cloud), staging and prod; `fake` on the emulators | `fake` logs the push (type, level, number of phones; never the token) and is refused in prod |
| `WHATSAPP_PROVIDER` | as section 9 (`fake` until the Meta account is live) | the fake logs the template, the masked number and the generic text |
| `NOTIFY_ALARM_DELAY_MIN` | 15 | critical alert unread this long: the alarm sounds |
| `REMINDER_EVENING_AT` | `19:00` | Cairo time of the "you drive tomorrow" reminder |
| `NOTIFY_DEVICE_CHANGES_PER_DAY`, `NOTIFY_SETTINGS_CHANGES_PER_DAY` | 30, 100 | limits per parent |

Deploy rules, indexes and functions:
`firebase deploy --only firestore:rules,firestore:indexes,functions --project dev`.
The first deploy creates the collection group index on `notifications`
(alarmState + alarmAt) and the Cloud Scheduler job of `notificationTick`
(every 5 minutes, Africa/Cairo).

### 18.3 Time Sensitive Notifications (iPhone, optional but recommended)

Critical alerts ("no driver", "child not confirmed") are sent with the
iOS interruption level **time-sensitive**, so they break through Focus.
That needs the capability:

1. Apple Developer > Identifiers > each App ID > tick **Time Sensitive
   Notifications** > Save. Regenerate the provisioning profiles (Codemagic
   does it on the next build).
2. Set `TIME_SENSITIVE_ALERTS=1` in the Codemagic environment group (and
   in your shell when you run `tool/bootstrap.sh` on the Mac).
   `tool/patch_native.py` then adds the entitlement
   `com.apple.developer.usernotifications.time-sensitive`.

Leave it unset until step 1 is done: signing fails when the entitlement is
present but the App ID lacks the capability. Without it, critical alerts
still sound, but Focus can hold them.

### 18.4 WhatsApp templates (Meta Business Manager, before the pilot)

Step by step for the owner, with every template's Arabic and English
text ready to paste and which ones to create first:
**docs/meta-whatsapp-setup.md**, step G.

Create these **utility** templates, Arabic and English, in WhatsApp
Manager > Message templates. `{{1}}` is the run ("Mon 16 Nov, to school");
the others have no parameter. No names, no addresses, no message text.

| Template | English body |
| --- | --- |
| `cp_no_driver` | No driver for {{1}}. Please take your own child. |
| `cp_child_not_confirmed` | A drop-off was not confirmed. Please check now. |
| `cp_drive_tomorrow` | You drive the {{1}} run. |
| `cp_drive_soon` | Your {{1}} run starts within the hour. |
| `cp_confirm_drive` | Please confirm the {{1}} run before the deadline. |
| `cp_swap_requested` | A member asked for a swap: {{1}}. |
| `cp_new_driver` | The {{1}} run has a driver now. |
| `cp_swap_cancelled` | The swap for {{1}} was taken back. |
| `cp_needs_driver` | The {{1}} run needs a driver. |
| `cp_child_absent` | A child is away for the {{1}} run. |
| `cp_child_back` | A child is back for the {{1}} run. |
| `cp_plan_ready` | Check your runs this week. |
| `cp_schedule_changed` | Days off or times changed in your carpool. |
| `cp_time_changed` | The {{1}} run has a new time. Check the plan. |
| `cp_join_requested` | A parent asked to join your carpool. |
| `cp_join_approved` | You are now in the carpool. |
| `cp_join_declined` | Your request to join was declined. |
| `cp_review_approved` | Your documents were approved. |
| `cp_review_rejected` | Open the app to see what to fix. |
| `cp_new_parent` | A new verified parent near your school. |
| `cp_wallet_received` | Money received. Open your wallet to see the details. |
| `cp_wallet_sent` | Your transfer went through. Open your wallet. |
| `cp_wallet_failed` | Transfer failed. No money left your wallet. |
| `cp_wallet_frozen` | Your wallet is paused for now. Open the app. |
| `cp_wallet_updated` | Your wallet has an update. Open the app. |

The Arabic bodies are in `functions/src/notifications/texts.ts`. Add
"Open the app for details." as the footer. Only `cp_no_driver` and
`cp_child_not_confirmed` (and `cp_time_changed` when a run moved with no
time left to confirm: it follows the "No driver" switch) are sent by
default (COST MODE); the others, including the five `cp_wallet_*`
templates (Prompt 11B; no amount, name or note), only
for parents who switch that group on, and only to parents who agreed to
WhatsApp at sign-up.

### 18.5 Expiry (each cloud project)

Firestore > TTL policies: collection group `notificationEvents`, field
`expiresAt` (30 days), and collection group `notifications`, field
`expiresAt` (in-app records, 60 days). The old `scheduleEvents` policy
from section 17.2 can stay; nothing writes there any more.

### 18.6 On the emulators and on the iPhone

- **Emulators:** the functions emulator runs `sendNotification` whenever an
  event is written. With `PUSH_PROVIDER` and `WHATSAPP_PROVIDER` at `fake`,
  the emulator log shows `[fake push] ...` and `[fake WhatsApp] template
  cp_... to +20*******01 ...`. The emulators do not run scheduled
  functions: run the reminders and alarms by hand with
  `npm --prefix functions run carpool:emulator -- remind --as any`, or
  send one test event with
  `npm --prefix functions run notify:emulator -- <uid> <type> [carpoolId] [YYYY-MM-DD]`.
- **A real push on the iPhone** needs the deployed dev project (FCM cannot
  reach a phone from the emulators: the app on the emulators uses a demo
  project with no push sender). Do 18.1 and 18.2 for dev, deploy, run the
  dev build **without** `EMULATOR_HOST`, sign in, allow notifications,
  then `GCLOUD_PROJECT=<dev project id> npm --prefix functions run notify:cloud -- <your uid> drive-hour`
  (needs `gcloud auth application-default login`; refuses any project
  that does not end in `-dev`).

## 19. Chat on Stream (Prompt 9)

Chat runs on Stream Chat. Cloud Functions hold the Stream secret, issue
short-lived tokens to verified parents only, create every channel and add
or remove every member. The app cannot create a channel or add anyone
(Stream channel-type permissions, set by a script). Chat push goes through
our own notification sender (section 18): Stream's own push stays off.

Two Stream apps: **one for dev and staging** (fake users only: the seed
parents get a Stream user the first time they open Chats) and **one for
prod**. Never use the prod app with test data, or the dev app with real
families.

### 19.1 Stream apps (once)

1. Sign up at getstream.io and create an organization for the project.
2. Create the app `school-carpool-dev` (region: EU, Dublin, the closest to
   `europe-west1`). Later create `school-carpool-prod` the same way.
3. Plan: **Build (free)** for both (COST MODE). docs/COSTS.md says when to
   move to Maker.
4. For each app, copy the **Key** and the **Secret** (Dashboard > App >
   Overview). The key is public; the secret is not.

### 19.2 Secret and parameters (each cloud project)

```bash
# Dev and staging projects: the DEV Stream app. Prod: the PROD app.
firebase functions:secrets:set STREAM_API_SECRET --project dev
```

Then in `functions/.env.dev` (and `.env.staging`, `.env.prod`):

```
CHAT_PROVIDER=stream
STREAM_API_KEY=<the app's key>
CHAT_RETENTION_DAYS=180
```

`CHAT_PROVIDER=fake` (the default for dev and staging in the repository)
keeps everything on the phone: the app shows a few fake chats and nothing
goes to Stream. The fake is refused in prod. Deploying needs the secret
to exist even with the fake: set it to any value then.

On the emulators: `functions/.env.local` and `functions/.secret.local`
(copy `.secret.local.example`) with the DEV app's key and secret, if you
want real chat between two phones while the rest runs on the emulators.

### 19.3 Configure the Stream app (each app, and after changing chat rules)

```bash
STREAM_API_KEY=<key> STREAM_API_SECRET=<secret> \
  WEBHOOK_URL=https://europe-west1-<project id>.cloudfunctions.net/chatWebhook \
  npm --prefix functions run chat:setup
```

The script (`functions/scripts/stream_setup.ts`, plan in
`functions/src/chat/setup_plan.ts`):

- checks that every permission it grants exists in the app and that no
  parent gets a forbidden one (create channel, add members, change or
  freeze a channel, delete others' messages, skip moderation);
- creates the blocked-terms lists `carpool_blocked_ar` and
  `carpool_blocked_en` (blocked, not just flagged);
- creates the four channel types `cp_private`, `cp_school`, `cp_area`,
  `cp_carpool`: uploads (photos) on only for private and carpool chats,
  read receipts only for those, no reactions, threads, polls, commands or
  Stream push; parents (role `user`) may only edit or delete their own
  messages; members read, write, mention and type;
- creates the `carpool-system` user that creates every channel;
- sets the webhook (event `message.new`) to `chatWebhook`;
- removes every **app-level** right of parents (`user`, `guest`,
  `anonymous`): no updating their own Stream user (name, parent ID) and no
  listing users. It reads the settings back and stops with an error if
  `update-user-owner` or `search-user` is still granted. Names and parent
  IDs are written only by Cloud Functions; the app connects with its uid
  only;
- sends the AI moderation policy for text and images (19.4). Without
  Stream's moderation product the script fails; for a dev app without it
  add `-- --no-moderation` (never for prod).

**Manual check on the dev Stream app (once, and after Stream changes its
defaults).** With a dev parent's token from `getChatToken` (Functions log
in the emulator, or the app's debug console), in a Node shell with the
`stream-chat` client: `client.connectUser({ id: '<uid>' }, '<token>')`, then

1. `client.partialUpdateUser({ id: '<uid>', set: { name: 'School admin' } })`
   must fail (permission error);
2. `client.queryUsers({})` must fail;
3. `client.channel('cp_school', 's-<schoolId>').create()` and
   `addMembers(['<other uid>'])` on a carpool chat must fail;
4. sending a message with an attachment in a school group must fail.

Write the date of the check in docs/progress.

Run it again whenever `setup_plan.ts` changes. Without `WEBHOOK_URL` (first
time, before the first deploy) it skips the webhook: deploy, then run it
again with the URL.

### 19.4 Moderation (each app)

Stream Dashboard > Moderation: turn on **AI Text** and **AI Image** for the
app, then run 19.3 again (the policy step prints FAIL until moderation is
on; the blocked-terms lists work without it). Harmful text and images are
removed; borderline ones are flagged in Stream's review queue. Reports from
parents still go to OUR admin panel (Reports), not to Stream.

Extend the blocked terms in `setup_plan.ts` (Arabic and English, a few
common spellings) and run 19.3 again.

### 19.5 Webhook

`chatWebhook` is an HTTPS function without App Check (Stream calls it). It
refuses every request whose `X-Signature` is not Stream's HMAC of the body
with the app secret (HTTP 401) and reads nothing then. Check in the Stream
Dashboard > Webhooks that the URL is set and the last calls return 200.

### 19.6 Retention and expiry (each cloud project)

- Since Prompt 12, `retentionDaily` (03:10 Cairo) deletes a chat 1 year
  after it ended (owner decision, confirmed by the lawyer; docs/DECISIONS.md).
  `chatRetentionDaily` and `CHAT_RETENTION_DAYS` are gone. Reports keep
  their own short copy, cleared 1 year after the report is handled.
- Firestore > TTL policies: collection `chatRequests`, field `expiresAt`
  (30 days after the last change), and collection group `chatPushes`,
  field `expiresAt` (2 days: delivery records of chat pushes).

### 19.7 On the iPhone

- Info.plist gets the photo library text (`tool/patch_native.py`): the
  camera text now also mentions chat photos.
- Photos are re-encoded as JPEG with EXIF removed (location included)
  before upload; the app keeps chats in Stream's offline storage, so a
  message written offline sends when the phone is back online. Signing out
  clears that storage.

## 20. Trips and live location (Prompt 10)

### 20.1 Functions settings and deploy (each cloud project)

In `functions/.env.<alias>` (defaults shown; dev on the emulators needs none):

```
ROUTES_PROVIDER=google      # fake in dev and CI; refused as fake in prod
ROUTES_TRAFFIC=true         # traffic-aware arrival times (Routes "Pro" SKU)
TRIP_STALE_SEC=120          # no point for this long: "location stopped"
TRIP_SELFIE_PERCENT=20      # share of runs that ask for a live selfie (F38)
TRIP_HANDOVER_MIN=10        # F34: minutes to confirm an afternoon drop-off
```

- The server key `MAPS_SERVER_KEY` (section 15) must also allow
  **Routes API**: Google Cloud > APIs & Services > enable "Routes API",
  then Credentials > the server key > API restrictions > add Routes API.
  Set a per-day quota on Routes API (Quotas) as for Places.
- `firebase deploy --only functions,firestore:rules,firestore:indexes,storage --project <alias>`.
  New functions: `prepareTrip`, `submitSelfieCheck`, `startTrip`,
  `tripAction`, `confirmHandover`, `quickMessage`, `tripEmergency`,
  `saveHandoverAdults`, `getHandoverAdults`, `setEmergencyContact`,
  `getTodayDriverCards`, `tripLocation` (HTTPS, called by the phone's
  location plugin with the run's own token; App Check cannot run there) and
  `tripTick` (every minute, Africa/Cairo: the fifth Cloud Scheduler job,
  see COSTS.md).
- `tripLocation` must allow public invocation (it checks the trip token
  itself): Cloud Run > `triplocation` > Security > "Allow unauthenticated
  invocations" (the deploy asks once).

### 20.2 Expiry (each cloud project)

Live selfies (`selfieChecks/`) are deleted by `submitSelfieCheck` on every
path and swept by `tripTick` after one hour. Optional second line: a
Cloud Storage lifecycle rule "delete objects with prefix `selfieChecks/`
older than 1 day" on the default bucket (Cloud Storage > bucket >
Lifecycle).

**Drivers verified before Prompt 10** have no face reference (the identity
selfie is kept as one only from now on, or a driver photo): they see "Add
your photo" before their next run and add the driver photo in Profile >
Driving (it is reviewed like the other driver documents).


`tripTick` deletes live points, arrival times and emergencies past their
time every minute. As a second line, add Firestore TTL policies on field
`expiresAt` for collection groups `points`, `eta`, `emergencies` and
collection `tripStops` and `tripChecks`:

```
for g in points eta emergencies tripStops tripChecks; do
  gcloud firestore fields ttls update expiresAt --collection-group=$g --enable-ttl --project <id>
done
```

### 20.3 WhatsApp templates (with section 18.4)

| Template | English body |
| --- | --- |
| `cp_driver_arrived` | The car is outside for the {{1}} run. Send your child now. |
| `cp_location_stopped` | The car's location stopped during the {{1}} run. |
| `cp_child_not_coming` | Your child was marked not coming for the {{1}} run. |
| `cp_emergency` | The driver pressed Emergency on the {{1}} run. Open the app. |
| `cp_emergency_contact` | {{1}} pressed the emergency button during a school run. Location: {{2}} |
| `cp_trip_started` | The car is on its way: {{1}}. |
| `cp_child_picked_up` | Your child got in for the {{1}} run. |
| `cp_child_dropped` | Your child was dropped off: {{1}}. |
| `cp_driver_late` | The driver is running late: {{1}}. |
| `cp_driver_at_gate` | The driver is at the school gate: {{1}}. |
| `cp_all_children_in` | All children are in the car: {{1}}. |
| `cp_run_still_on` | No location from you for 2 minutes on the {{1}} run. Open the app to continue. (Prompt 13, to the driver) |

Arabic bodies: `functions/src/notifications/texts.ts` (the emergency
contact one: "ضغط {{1}} زر الطوارئ أثناء مشوار المدرسة. الموقع: {{2}}").
On by default (COST MODE: urgent only): Arrived, location stopped, child
marked not coming and run still on (group "Car outside, location") and
Emergency. The others are push only
unless the parent switches "Run updates" on. `cp_emergency_contact` goes to
a number that is not a parent of the app: the driver saved it and is
asked to tell that person.

### 20.4 iPhone: background location (applied by tool/patch_native.py)

Prompt 13 (owner decision, docs/DECISIONS.md "Location tracking on
iPhone"): the free `geolocator` plugin, "While Using the App" with Precise
Location to start a run. "Always" is only offered once to drivers as an
optional step for run recovery (owner, 13:44; `packages/run_recovery`).
The patch also makes the iOS app a classic app-delegate app (no UIScene)
so a background relaunch for location runs Dart (Prompt 13 review).

- `UIBackgroundModes`: `location` and `remote-notification` only.
- Permission texts in Arabic and English (`tool/ios/<lang>.lproj/InfoPlist.strings`):
  `NSLocationWhenInUseUsageDescription` and
  `NSLocationAlwaysAndWhenInUseUsageDescription` (the optional "Always"
  step for run recovery).
- The blue location indicator shows while a run tracks with the app in
  the background. Swiping the app away stops tracking on iPhone; the server
  pushes the driver "Run still on" after 2 minutes and tells the parents.
  With "Always", the run usually resumes by itself within a few minutes
  after the car moves (to be confirmed on a device: docs/test-iphone.md T6).
- App Store review: docs/app-review-notes.md.

### 20.5 Licence: none needed

No licence or build secret is needed for live location. The paid
flutter_background_geolocation (and its `BG_GEO_LICENSE`) was removed in
Prompt 13; DECISIONS.md says how to bring it back. If an old
`BG_GEO_LICENSE` variable is still in Codemagic's `staging_defines` or
`dev_defines` group, delete it.

### 20.6 Try it (the "Done when" check)

1. Emulators, seed and the dev app with `--dart-define=EMULATOR_HOST=<Mac IP>`
   as in sections 16.5 and 17.3. Your car is approved; give it a driver
   photo in Profile > Driving (optional: then some runs ask for a selfie;
   set `TRIP_SELFIE_PERCENT=100` in `functions/.env.local` to see it every
   time, `0` to skip it).
2. Plan and confirm a run of today within the next hour (Prompt 7 steps).
3. Second device: an iOS Simulator (or a second iPhone) signed in as the
   seed parent Hoda (`+201000000101`, code in the functions log), whose
   child rides your run.

4. On your iPhone: Carpool > Week plan > today's run > **Start run**. Allow
   location **While Using the App** (Precise on) and notifications when
   asked; if something is off, the "Before you drive" steps show what to
   change. The first time, the optional "Resume runs by itself" screen
   offers "Always" (either answer works). Lock the phone and walk or drive
   a little.
5. On the second device: Carpools > the carpool > **Today** > the driver
   card (or Week plan > the run > **Follow run**). The car moves on the
   map (the sketch map without a Maps key) and "Car in about N min" shows
   (straight-line times with `ROUTES_PROVIDER=fake`).
   `npm --prefix functions run carpool:emulator -- trip <carpoolId> <runId> --as any`
   prints the status and how old the last point is.
6. On the iPhone tap **Arrived** for Hoda's child: her Alerts tab shows "Car
   is outside" (the functions log shows the push and `[fake WhatsApp]
   template cp_driver_arrived`). Tap it again: a second alert. Then
   **Picked up** and **At school** (or, in the afternoon, Picked up,
   Arrived and **Handed over**): an alert each time.
7. Location stopped: on the iPhone turn on Airplane mode for more than two
   minutes, then run `... carpool:emulator -- triptick --as any` (the
   emulators do not run scheduled functions). Hoda's Alerts shows
   "Location stopped" and the live run shows a warning.
8. A parent whose child is not on the run: sign the second device in as
   another seed parent (or remove Hoda's child from the run with Away):
   the live run shows "Not started" and Firestore refuses the reads
   (`tests/rules/trips.test.ts` proves it).
9. After the last drop-off the driver screen shows "Run finished", the
   location arrow leaves the iPhone's status bar and the `trip` command
   shows `ended` with no new points. In the afternoon, leave a handover
   unconfirmed for 10 minutes and run `triptick`: "Child not confirmed"
   reaches both parents (critical, with the alarm). Confirm with
   `... carpool:emulator -- home <carpoolId> <runId> <childId> --as seed-map-parent-1`.
## 21. Wallet (Prompt 11B; switched off for the pilot, see 21b)

The wallet runs through ONE `WalletProvider` in Cloud Functions
(`functions/src/wallet/`). Until the contract with the payment partner
licensed by the Central Bank of Egypt is signed, dev and staging use the
**fake provider** (test money kept in Firestore `fakeWalletAccounts` and
`fakeWalletOps`). The fake is refused in prod; the partner provider is a
stub that refuses every call until it is built and switched on.

### 21.1 Functions settings (each cloud project)

In `functions/.env.<alias>`:

```
WALLET_PROVIDER=fake          # dev and staging; prod: partner (after the contract)
WALLET_PARTNER_ENABLED=false  # true only once the partner provider is built and tested
MIN_INSTANCES_WALLET=0        # COST MODE; raise if cold starts slow transfers
```

With `WALLET_PROVIDER=partner` and `WALLET_PARTNER_ENABLED=false` the app
shows "Wallet not open yet" and parents pay contributions in cash.

### 21.2 Limits (server settings, no deploy needed)

Firestore > `config/wallet` (create the document in each project). Amounts
are **piastres** (100 = 1 EGP). Missing or odd values use the defaults;
values above the hard ceilings in `functions/src/wallet/model.ts` are
ignored.

| Field | Default | Meaning |
| --- | --- | --- |
| `minAmount` | 100 | Smallest amount (1 EGP) |
| `perTransferMax` | 200000 | Largest transfer or withdrawal (2,000 EGP) |
| `perDayMax` | 500000 | Sent plus withdrawn per Cairo day (5,000 EGP) |
| `perDayCount` | 20 | Transfers plus withdrawals per day |
| `topUpMax` | 500000 | Largest single top-up |
| `topUpPerDayMax` | 1000000 | Added per day |
| `lookupsPerHour` | 20 | Parent ID lookups per parent per hour |
| `alertNewReceivers` | 3 | Admin alert: this many first-time receivers within an hour |
| `alertTransfersPerHour` | 10 | Admin alert: this many transfers within an hour |
| `reportsPerDay` | 10 | Transfer problem reports per parent per day |

Change them to the partner's limits when the contract is signed.

### 21.3 Indexes, schedule and rules

- `firebase deploy --only firestore:indexes,firestore:rules` (new indexes on
  `transfers`, `walletAlerts`, `fakeWalletOps`).
- `walletReconcile` runs every 5 minutes: transfers whose answer was lost
  are settled by asking the partner (never by guessing; a request is
  cancelled at the partner before it is recorded as failed, and one the
  partner can neither confirm nor cancel stays pending with a "stuck" admin
  alert), and freezes the partner missed are applied again. One more Cloud
  Scheduler job (docs/COSTS.md).
- Every wallet collection is closed to the app (`tests/rules/wallet.test.ts`).

### 21.4 Trying it on the emulators and the iPhone

- Two verified fake parents (seed, Prompts 6 and 7). Each opens the wallet
  (Profile > Wallet > agree > Open wallet) and adds test money.
- Pending and reconciliation: set Firestore `config/walletFake` to
  `{ mode: "timeout" }` (the partner moves the money but the answer is
  lost), `"lost"` (it never arrives) or `"down"`; back to `"ok"` to settle.
  The transfer shows "In progress"; Check again (or the 5-minute job)
  settles it without ever sending twice.
- Face ID: the iPhone asks before every transfer and withdrawal
  (`NSFaceIDUsageDescription`, Arabic and English, `tool/patch_native.py`).
  A simulator: Features > Face ID > Enrolled, then Matching Face.

### 21.5 Before the pilot (the partner)

- Implement `PartnerWalletProvider` against the partner's API (idempotency
  key = our transfer ID; a lookup by that key for reconciliation; a cancel
  or void by that key that guarantees the request never runs afterwards,
  answering its final state; webhooks if the partner needs them), keep its secrets in Secret Manager and bind
  them only to the wallet functions.
- Confirm with the partner: limits, identity checks it needs from parents,
  how add money (payment page) and withdraw (to which account) work, the
  dispute process, and that transfers between parents carry no fee.

### 21.6 A "stuck" transfer (Prompt 12)

When the partner could neither confirm nor cancel a transfer, admins see an
"Outcome unknown" alert (admin panel > Wallet). Nothing is guessed and no
money moves from our side:

1. Ask the partner, in writing, what happened to that request ID (the
   transfer ID in the alert): it ran, or it was cancelled and will never run.
2. A super admin records the answer once (it is written to the audit log):
   `GCLOUD_PROJECT=<project> npm --prefix functions run wallet:settle -- <transferId> done|failed <partnerRef or -> <yourAdminUid>`
3. The transfer gets its one result (append-only), the day's limit counter
   is released, both parents are told, and the alert closes as "Settled
   with partner".


## 21b. Feature switches and Settle up by InstaPay (F45)

### 21b.1 Feature switches (no setup needed)

The optional features are switched from the admin panel: **Settings**
(super admin only; every change asks for confirmation and is written to
the Log). The switches live in Firestore `config/features`. With no
document the pilot defaults apply:

| Switch | Pilot default | What "off" means |
| --- | --- | --- |
| `wallet` | off | No wallet row or screens; every wallet function refuses; `walletReconcile` does nothing |
| `ratingsAndVouching` | off | No "Rate parents"; rating functions refuse. Who may drive does not depend on it |
| `yearlyChecks` | off | No school-year card; nobody is reminded, marked overdue or blocked |
| `settleUp` | on | (off: no Settle up row or screens; its functions refuse) |

A change reaches open apps within seconds (one listener) and the functions
within about 30 seconds (their cache). No deploy and no app release.
Sign-in, verification, carpools, the schedule, trips and alerts, and chat
cannot be switched off.

### 21b.2 Settle up: nothing to sign up for

Settle up needs **no account, no contract and no key**: the app only keeps
records between parents and shows an InstaPay address; parents pay in the
InstaPay app. There is no InstaPay API call anywhere in the code.

In `functions/.env.<alias>` (already filled in with these defaults):

```
SETTLE_UP_REQUESTS_PER_DAY=20            # new records per parent per day
SETTLE_UP_CHANGES_PER_DAY=100            # I paid, Received, Not received, cancel, decline, report
SETTLE_UP_ADDRESS_CHANGES_PER_DAY=5      # saving or removing the InstaPay address
SETTLE_UP_ADDRESS_VIEWS_PER_HOUR=30      # how often a payer may open payees' addresses
SETTLE_UP_REPORT_AFTER=2                 # "Not received" marks before Report shows
```

### 21b.3 The largest amount (server setting, no deploy needed)

Firestore > `config/settleUp` > field `maxAmount` in **piastres** (100 = 1
EGP). Missing or odd values use the default: `500000` (EGP 5,000).

### 21b.4 Indexes and rules

`firebase deploy --only firestore:rules,firestore:indexes` (the setup
script does it): two indexes on `settleUps` (`parties` with `updatedAt`,
and `pair` with `finished`). Rules: a record is read only by its two
parties; nobody reads an InstaPay address directly; the app writes nothing.

### 21b.5 Trying it

Two verified accounts in one carpool: docs/test-iphone.md section 9. On
the emulators the same steps work with the fake parents of section 16.5.

## 22. Trust and yearly checks (Prompt 11)

Ratings and vouching, family (guardian) links, driving papers, the yearly
check of children and the re-verification of a new phone number or car.
All of it runs in Cloud Functions (`functions/src/trust/`); the app reads
and writes no trust record directly (`tests/rules/trust.test.ts`).

### 22.1 Functions settings (each cloud project)

In `functions/.env.<alias>` (defaults shown):

```
TRUST_RATE_WINDOW_DAYS=30   # a finished trip can be rated for 30 days
SCHOOL_YEAR_START=09-01     # first day of the school year (Cairo)
YEAR_CHECK_OPEN_DAYS=21     # the yearly check opens this many days before it
YEAR_CHECK_GRACE_DAYS=14    # and closes this many days after it
YEAR_CHECK_FIRST_YEAR=2027  # first school year that is checked (2027 = 2027-28)
LICENCE_REMINDER_DAYS=30,7,1
```

After the deadline a parent who did not confirm gets no new driving days
until they do (`users.yearCheckOverdue`, written by `trustDaily`).

### 22.2 Indexes, schedule and storage

- `firebase deploy --only firestore:indexes,firestore:rules,storage` (new
  indexes on `trips` (viewerUids, status, date), `guardianLinks`,
  `ratings`, `memberships` (uid, status); the `phoneChecks/` upload rule).
- `trustDaily` runs every morning at 08:10 Cairo time: papers reminders
  (30, 7 and 1 days before the earlier expiry), "papers expired" with the
  runs after it released, and the yearly check's reminders and deadline.
  One more Cloud Scheduler job (docs/COSTS.md).
- Triggers: `releaseRunsOnUserBlock` (suspend or ban: the driver's runs
  open for the group), `recheckRunsOnVehicleWrite` (a car that changed or
  expired: runs it cannot carry are released) and
  `refreshOnGuardianLinkWrite` (a linked parent's map and school groups).

### 22.3 WhatsApp templates (with section 18.4; off by default)

| Template | English body |
| --- | --- |
| `cp_licence_expiring` | Your licence or car licence expires on {{1}}. Renew it and update your driving details. |
| `cp_licence_expired` | You get no new driving days until you update your driving details. |
| `cp_year_check` | Confirm your children, grades and schools for the new year. |
| `cp_guardian_requested` | Another parent asked to link to your children. Open the app to answer. |
| `cp_guardian_linked` | Your account is now linked to the other parent's children. |
| `cp_guardian_declined` | You were not linked to the children. Open the app for details. |
| `cp_phone_changed` | Your account's phone number changed. If it wasn't you, contact us at once. |

Arabic bodies: `functions/src/notifications/texts.ts`. All are in the new
"Papers and family" group, push only unless the parent switches WhatsApp
on (COST MODE).

### 22.4 Try it on the emulators and the iPhone (the "Done when" check)

The iPhone is a verified parent in a carpool with the seed's Hoda
(`seed-map-parent-1`), with the week planned (sections 17.3 and 20.6).

1. **Rate a parent after a finished trip.** Make one run a finished trip
   (test data): `npm --prefix functions run carpool:emulator -- finishtrip
   <carpoolId> <runId> --as any` (a run Hoda drives with your child, or
   you drive with hers). On the iPhone: Profile > Rate parents > Hoda >
   stars, a tag, "I vouch" > Send rating. "Thanks for rating"; she leaves
   the list until next month. The finished run's screen also has "Rate this
   trip". Two stars or "Unsafe driving" go to the admin panel > Trust.
2. **An expired licence blocks a driving day.** `... -- expire 2026-11-16
   --as seed-map-parent-1` (her licence's last valid day). Her runs after
   that day lose the driver (the group hears "driver unavailable"), and
   taking one of them or planning her refuses ("car expired"). On her
   Profile > Driving: "Your papers expired". `... -- trustdaily --as any`
   sends the "papers expire soon / expired" notices.
3. **Suspending a driver opens swap requests.** Admin panel > Users > Hoda >
   Suspend (the dialog says her driving days open for her groups). On the
   iPhone the carpool's schedule shows her runs open ("Needs a driver") and
   the alert says only that the driver is unavailable; take one with Take.
4. **Yearly check.** Set `YEAR_CHECK_FIRST_YEAR` to the current year and,
   for a quick try, `SCHOOL_YEAR_START` to a date within 21 days, restart
   the emulators, run `... -- trustdaily --as any`. Profile shows "New
   school year"; confirm with one child "Left school": the child leaves the
   carpool and the school chats.
5. **Family links.** Second account: Profile > Family links > Link to a
   parent > your parent ID, Mother > Send request. On the iPhone: Requests
   for you > tick the children > Accept. A "Guardian" link waits in the
   admin panel > Trust.
6. **Phone change.** Profile > Phone > new number > code (the fake
   WhatsApp sender logs it in the functions emulator) > selfie. The fake
   face check answers what `config/kyc` says (section 12).

## 23. Privacy and security hardening (Prompt 12)

Code: `functions/src/privacy/`, `lib/features/privacy/`,
`lib/features/security/app_lock.dart`, `lib/features/analytics/`.
SECURITY.md has the MASVS checklist, the outside services and the incident
plan; `docs/restore-test.md` the backup restore test.

### 23.1 Deploy (each cloud project)

- `npm --prefix functions install` picks up **sharp** (server thumbnails).
- `firebase deploy --only functions,firestore:rules,firestore:indexes,storage`.
  The deploy asks to delete `purgeVerificationImagesDaily` and
  `chatRetentionDaily`: answer yes. Both now run inside `retentionDaily`
  (03:10 Cairo time), so the number of Cloud Scheduler jobs goes down by one.
- `makePhotoThumbnail` is a Storage trigger on the default bucket; the bucket
  must be in `europe-west1` like the functions (it is, if it was created with
  the project in that region; otherwise set the trigger's region to the
  bucket's).
- Give the Cloud Functions service account the "Cloud KMS CryptoKey
  Encrypter/Decrypter" role only if a function writes with an explicit key;
  with the bucket's default key (23.2) Cloud Storage's own service agent
  does the encryption and the functions need nothing more.
- New parameters (optional, defaults in brackets): `OTP_MAX_FAILURES_PER_DAY`
  (30).

### 23.2 Our own encryption key for the photos (each project, once)

Run `tool/setup_kms.sh <project-id>` (gcloud signed in as owner). It creates
key ring `school-carpool` and key `private-photos` in `europe-west1` with a
yearly automatic rotation, lets Cloud Storage use it, and sets it as the
bucket's default key. Then:

1. Check: `gcloud storage buckets describe gs://<bucket> --format='value(default_kms_key)'`.
2. Upload a test photo in staging; `gcloud storage objects describe gs://<bucket>/<path> --format='value(kms_key)'`
   shows the key.
3. Never destroy the key or its versions: every photo encrypted with it
   would be lost. Give "Cloud KMS Admin" to the owner only.
4. Photos uploaded before the key was set keep Google's key until rewritten.
   To rewrite them once: `gcloud storage objects update gs://<bucket>/verification/** --encryption-key=<key id>`
   (and the same for `faceRefs/**`, `driverPhotos/**`, `selfieArchive/**`,
   `thumbs/**` and `routeArchive/**`). Then run
   `GCLOUD_PROJECT=<project> npm --prefix functions run thumbs:backfill` so
   every kept photo has a thumbnail made from its current version.
5. `tool/setup_kms.sh` runs on Linux, Cloud Shell and macOS (it picks GNU or
   BSD `date`, or python3).

### 23.3 Retention: lifecycle rules and TTL policies (each project, once)

Run `tool/setup_retention.sh <project-id>`. It applies
`tool/storage_lifecycle.json` (kept photos to Nearline after 30 days and
Coldline after 180 days; route archives Coldline at once and deleted after
400 days; exports and live selfies deleted after 2 days), keeps soft delete
at 7 days, and switches on every Firestore TTL policy (sign-in records,
place cache, invites, "looking" posts, events, notifications, chat requests
and pushes, live trip points, privacy requests, abuse counters, sign-ins,
phones, mail, job reports). Section 12.6's "turn off soft delete" no longer
applies: photos are now kept, and 7 days of soft delete protect against a
mistaken deletion.

`retentionDaily` writes `retentionRuns/{date}` (counts only). A failure opens
a "retentionFailed" security alert and a Sentry error.

### 23.4 Email for "new phone signed in" (owner decision needed)

The functions write the email to the `mail` collection in the format of
Firebase's **Trigger Email from Firestore** extension. Until the extension is
installed the messages wait there (30-day TTL) and nothing else breaks. To
send them (a new tool: owner's OK first, SETUP and COSTS):
Firebase console > Extensions > Trigger Email from Firestore, collection
`mail`, an SMTP connection URI from a provider in Secret Manager, a "From"
address on the app's domain, region `europe-west1`.

The same alert also goes as a push (`new-device`) to the old phone. Its
WhatsApp template `cp_new_device` is off by default (COST MODE); submit it
to Meta with the other templates (18.4) only if the owner wants WhatsApp too:

| Template | Text (English; Arabic in functions/src/notifications/texts.ts) |
| --- | --- |
| `cp_new_device` | Someone signed in to your account on a new phone, so we signed out the others. If it wasn't you, contact us at once. |

### 23.5 Google Analytics (each project)

Firebase console > Analytics: link or create the Analytics property for the
project (free). Then Admin > Data settings > **Data retention: 2 months**;
Data collection: Google signals **off**; Data sharing: all **off**. The app
sends no user ID and no advertising ID (docs/analytics-events.md).

### 23.6 Sentry alerts on new errors in sign-in, trips and the wallet

Every event carries the tag `area` (`signin`, `trips`, `wallet`, `privacy`,
`other`), from the route pattern in the app and from the function name in
Cloud Functions. In Sentry, for each project (app and functions):
Alerts > Create alert > Issues > "A new issue is created" AND "The event's
tags match `area` equals `signin`" (then the same for `trips` and `wallet`)
> send an email to the owner. Keep Sentry's own PII scrubbing ("Data
scrubber", "Use default scrubbers") on as the second layer.

### 23.7 Point-in-time recovery and backups (prod)

Owner decision (14 Nov 2026, "best option, even if paid"): **point-in-time
recovery ON in prod**, and the daily backups stay on (section 5). Switch it
on once:

```sh
gcloud firestore databases update --database='(default)' --enable-pitr --project=<prod-id>
gcloud firestore databases describe --database='(default)' --project=<prod-id> \
  --format='value(pointInTimeRecoveryEnablement,versionRetentionPeriod)'
# expect POINT_IN_TIME_RECOVERY_ENABLED and 604800s (7 days)
```

`tool/setup_retention.sh <prod-id> --prod` does the same. Any minute of the
last 7 days can then be read or cloned into a new database
(`docs/restore-test.md`). Run the restore test once now in staging and
every 3 months.

### 23.8 Try it on the iPhone (the "Done when" check)

1. **Export:** Profile > Privacy > Download my data. The JSON opens in
   Safari (share it to Files to keep it). It has a section for every data
   type, your chat messages and your wallet history.
2. **A second phone listed:** sign in with the same number on a second
   phone (or the simulator). On the iPhone the account gets "New phone"
   (push), and the first phone signs out at its next start. On the second
   phone, Profile shows "New phone: take a selfie"; chats and the wallet
   open after the selfie (the fake face check answers what `config/kyc`
   says). Profile > Privacy > Phones and sign-ins lists both phones;
   "Sign out" on the other one.
3. **App lock:** Profile > Settings > App lock (Face ID asks once). Leave the
   app for over 30 seconds and come back: it is locked; Face ID opens it.
4. **Delete a test account:** with an empty wallet, Profile > Privacy >
   Delete account > Next > tick > Delete my account > Face ID. The app
   returns to Welcome. In the console: `users/<uid>` is gone,
   `closedAccounts/<uid>` holds the purge date and an empty `failed` list,
   `transfers` still hold its transfer records, `bannedIds` keeps the ID's
   hash only if the account was banned. Photos, run summaries, route
   archives and consents wait in place until the purge date (owner
   decision: 1 year after closure).
5. **Rules tests:** `npm --prefix tests/rules run test:emulator` (CI runs it).

