# Staging app on TestFlight (Prompt 13)

How the staging iPhone app gets from GitHub to your iPhone. Codemagic
builds it, signs it with your Apple account and uploads it to TestFlight.
**Never paste a key, password or code into a chat, an issue or the
repository**: every secret goes only into the Codemagic or Apple screens
named below.

What is already in the repository (`codemagic.yaml`, workflow
`ios-staging`):

- Bundle id `org.schoolcarpool.app.stg`, display name "School Carpool Stg",
  `lib/main_staging.dart` (talks to the **staging** Firebase project).
- Signing: App Store distribution, profiles fetched by Codemagic from your
  Apple account through the App Store Connect API key.
- Build number: the last TestFlight build number + 1 (automatic).
- Upload: to App Store Connect, then **TestFlight** (internal testers get
  it without Apple review).
- Starts only on: **Start new build** by hand, or a tag `v...` (for example
  `v0.1.0`). A push to `main` or any other branch starts nothing (COST
  MODE: about 20 of the 500 free macOS minutes per build).
- No location licence is needed any more (free `geolocator`, DECISIONS.md).

## Once: Apple (about 20 minutes)

1. developer.apple.com > **Certificates, Identifiers & Profiles >
   Identifiers**: open `org.schoolcarpool.app.stg` (create it if missing:
   App IDs > App > Explicit). Tick **Push Notifications** and **App
   Attest**; if you use invite links, **Associated Domains**; optional
   **Time Sensitive Notifications**. Save. (SETUP.md 1.2.)
2. App Store Connect > **Apps > +  > New App**: platform iOS, name "School
   Carpool Stg", primary language **Arabic**, bundle id
   `org.schoolcarpool.app.stg`, SKU `school-carpool-stg`. Open the app >
   **App Information** > copy the **Apple ID** (a 10-digit number).
3. Put that number in `codemagic.yaml` > `ios-staging` > `vars` >
   `APP_STORE_APPLE_ID` (replace `"0000000000"`, keep the quotes) and commit
   it. It is not a secret.
4. App Store Connect > **Users and Access > Integrations > App Store
   Connect API > Team Keys > +**: name `Codemagic`, access **App Manager**.
   Download the `.p8` file (only possible once). Note the **Issuer ID** (top
   of the page) and the **Key ID** (in the row). Keep the `.p8` in a safe
   place on your Mac, never in the project folder.
5. App Store Connect > the staging app > **TestFlight > Internal Testing >
   +**: group "Owner", add yourself (and the second test account's Apple
   ID if it is a different person).

## Once: Codemagic (about 15 minutes)

1. codemagic.io > **Team settings** (or your personal account settings) >
   **Integrations > Developer Portal > Connect**. Name: `CodemagicASC`
   (exactly; `codemagic.yaml` uses it). Paste the **Issuer ID** and **Key
   ID**, upload the `.p8`. Save. Codemagic stores it encrypted.
2. Codemagic > the app > **Environment variables**. Group
   **`staging_defines`** (create it if missing). Add, each with **Secret**
   ticked:
   - `SENTRY_DSN_APP_STAGING`: Sentry > the staging project > Settings >
     Client Keys (DSN).
   - `MAPS_API_KEY_IOS`: Google Cloud (staging project) > APIs & Services >
     Credentials > the iOS key restricted to `org.schoolcarpool.app.stg`
     (SETUP.md 15.2). Leave it out to build without a Google map.
   - `INVITE_LINK_DOMAIN` (optional): the staging links site host
     (SETUP.md 16.2); only after Associated Domains is ticked in step 1.
   If an old `BG_GEO_LICENSE` variable is there, delete it.
3. The Firebase options for staging must be generated and committed
   (`lib/firebase/firebase_options_staging.dart`, SETUP.md 3 step 9, "Connect the app"); they are
   not secret.
4. Staging Firebase project: upload the APNs key (SETUP.md 3 step 7 and 18.1), deploy
   the functions, rules and indexes (SETUP.md 23.1), and register App Check
   with **App Attest** for the iOS app (SETUP.md 3 step 8).
   Chat needs nothing more: it is our own, on Firestore (SETUP.md 19),
   so two phones can chat in staging. No Stream account, key or secret.
   The script also gives Firebase Storage the role its rules need for
   chat photos (SETUP.md 19.2).

   **Easiest:** [docs/owner-cloud-shell.md](owner-cloud-shell.md). After four
   console clicks, one command in Google Cloud Shell
   (`bash tool/cloud_setup.sh staging school-carpool-staging <admin-email>`)
   does the deploy, App Attest, the Maps keys (it prints `MAPS_API_KEY_IOS`
   for step 2), the admin panel and the staging Firebase options for step 3.
   The APNs upload stays a console step.

## Every build

1. Codemagic > the app > **Start new build** > branch `main` > workflow
   **iOS staging to TestFlight** (or push a tag `v...` on `main`). Merging
   to `main` alone starts no build.
2. Wait for the build (about 20 minutes) and Apple's processing (5 to 30
   minutes; you get an email).
3. iPhone > **TestFlight** app > School Carpool Stg > **Install**.
4. The first time: App Store Connect may ask for **export compliance**:
   the app is already marked as using only standard encryption
   (`ITSAppUsesNonExemptEncryption` = NO), so no question should appear.

## When a build fails

| Message | Fix |
| --- | --- |
| No matching profiles / "Could not find a provisioning profile" | Step Apple 1 (App ID and capabilities) and Codemagic 1 (integration name `CodemagicASC`). |
| `APP_STORE_APPLE_ID` / "app not found" | Apple step 3. |
| "Missing Purpose String in Info.plist" (email from Apple) | `tool/patch_native.py` sets all of them; tell the developer which key Apple names. |
| Build uploaded but not in TestFlight | Apple is still processing, or you are not in the internal group (Apple step 5). |
| App opens on an error screen | The staging Firebase options are missing (Codemagic step 3). |

Next: run docs/test-iphone.md with two test accounts.
