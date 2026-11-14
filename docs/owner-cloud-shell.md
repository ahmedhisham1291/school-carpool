# Set up the staging project from Cloud Shell (no installs)

One script, `tool/cloud_setup.sh`, does almost all of the one-time cloud
setup of the **staging** project (`school-carpool-staging`) for the first
TestFlight test. It runs in **Google Cloud Shell**, a terminal in your
browser that already has every tool it needs. Nothing goes on your Mac.

## Before: four console clicks (about 10 minutes)

1. console.firebase.google.com > **Add project** > id
   `school-carpool-staging`, Google Analytics **off**.
2. In that project: **Upgrade** (bottom left) > **Blaze**, pick your billing
   account.
3. **Build > Firestore Database > Create database**: Standard edition,
   location **europe-west1 (Belgium)**, **production mode**.
4. **Build > Storage > Get started**: production mode, location
   **europe-west1**.

You need to be **Owner** of the project, and an admin of the billing
account (for the budget alert). Keep your **Apple Team ID** at hand
(developer.apple.com > Account > Membership details; 10 letters/digits).

## Run it

1. Open <https://shell.cloud.google.com/?project=school-carpool-staging>
   and wait for the prompt.
2. Paste this, with **your own email** (it becomes the first admin of the
   admin panel):

   ```sh
   git clone https://github.com/ahmedhisham1291/school-carpool.git && cd school-carpool && bash tool/cloud_setup.sh staging school-carpool-staging <admin-email>
   ```

3. It asks for the Apple Team ID (type it, or press Enter to skip the
   invite-links site and App Attest). It may also show a sign-in link once:
   open it, sign in with the same Google account, paste the code back.
4. Wait. The first run takes 20 to 40 minutes (the Cloud Functions deploy
   and the Flutter download for the admin panel are the long parts).
   Cloud Shell must stay open in its tab.

## What it does

Each step checks first and skips what is already done.

- Checks Blaze, Firestore and Storage (in europe-west1); turns on the
  Google APIs the app uses (Firebase, Functions, Maps SDK for iOS, Places,
  Routes, KMS, reCAPTCHA, ...).
- Authentication: Identity Platform (free tier), Email/Password on (for the
  email confirmation and the admins), sign-up and delete from apps off, SMS
  denied everywhere.
- Gives the functions' service account the roles SETUP.md needs (sign-in
  tokens, secrets, events).
- Makes two Google Maps keys: one for the iPhone app only (bundle
  `org.schoolcarpool.app.stg`, Maps SDK for iOS only) and one for the
  functions (Places and Routes only).
- Creates the secrets in Secret Manager. Random keys for the sign-in and ID
  hashes; the word `unused` for services staging fakes (WhatsApp, Algolia,
  Stream). **An existing secret is never replaced.**
- Creates the Hosting sites `school-carpool-staging-links` and
  `school-carpool-staging-admin`, registers the iPhone and web apps in
  Firebase, writes `lib/firebase/firebase_options_staging.dart`.
- App Check: registers the iPhone app with App Attest and the admin site
  with a reCAPTCHA Enterprise key. It does **not** switch enforcement on.
- Admin site domains for sign-in and for the photos (CORS), the retention
  rules (TTL, storage lifecycle) and our own encryption key for the photos.
- Deploys the Firestore and Storage rules, indexes and all Cloud Functions
  (tries once more after 60 seconds if the first deploy fails).
- Loads the **sample** schools (a hand-written test list, not real data) so
  the school search works; staging uses the built-in fake search, no
  Algolia.
- Builds and deploys the invite-links site and the admin panel; turns on
  two-step sign-in (TOTP) and makes you the first super admin.
- Creates a USD 20 budget with emails at 5, 25 and 100 percent.

At the end it prints a checklist: **DONE** and **STILL TO DO**.

## What it prints, and where it goes

| Printed | What to do |
| --- | --- |
| ONE-TIME SET-PASSWORD LINK | Open it **at once** yourself (valid 1 hour), set your admin password. Never paste it anywhere. Then open the admin panel link, sign in, and add the authenticator app when asked. |
| `paste into Codemagic MAPS_API_KEY_IOS` | Codemagic > the app > Environment variables > `staging_defines` > add `MAPS_API_KEY_IOS`, tick **Secret**. Do **not** paste it in chat. |
| `BEGIN ... firebase_options_staging.dart ... END` | Not secret: copy everything between the two markers into the chat for the developer, who commits it. |
| "These repository files also changed" | Only appears if something differs from the repository; copy that too. |
| Logs Explorer link | Where the 6-digit sign-in codes appear while staging uses the fake WhatsApp sender (filter `"fake WhatsApp"`). |

## After: the console steps that remain

The script lists them with direct links. Usually:

1. **APNs key** (needed for pushes): Firebase console > Project settings >
   Cloud Messaging > Apple app configuration > School Carpool Stg > APNs
   Authentication Key > Upload the `.p8`, its Key ID and your Team ID.
2. **Blocking functions:** Authentication > Settings > Blocking functions
   shows `blockClientSignUps`, `blockNonCodeSignIn` and `blockSignInEmails`.
3. **Maps daily caps:** the two Quotas links: "per day" rows to 300
   (Places) and 150 (Routes).
4. **Codemagic:** `MAPS_API_KEY_IOS` as above.
5. **App Check:** do not press **Enforce** yet (SETUP.md 3.8).
6. Anything else listed under STILL TO DO (for example a step the script
   could not finish).

## Run it again safely

Run the same command again at any time (in Cloud Shell: `cd school-carpool
&& git pull && bash tool/cloud_setup.sh staging school-carpool-staging
<admin-email>`). Finished steps are skipped, secrets and keys are kept,
schools are not duplicated, and your admin account is not recreated (if you
never used the first password link, a new one is printed). If it stops with
**STOPPED**, read the line under it, fix that (usually a console click), and
run it again. If it fails twice, copy the lines above **STOPPED** to the
developer (they contain no keys).

Optional settings, typed before `bash`: `APPLE_TEAM_ID=XXXXXXXXXX` (skip
the question), `SKIP_ADMIN_WEB=1` (no admin panel build),
`ADMIN_NAME="Your Name"`.
