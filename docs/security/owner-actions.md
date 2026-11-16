# Security: what only the owner can do

From the security review of 16 Nov 2026 ([threat-model.md](threat-model.md)).
Code cannot do these: they are switches in consoles and accounts. Do them
for **prod first**, then staging (dev runs on the emulators). Replace
`<project>` with the project ID (for example `school-carpool-prod`) and
`<owner>/<repo>` with the GitHub repository.

Tick each line when done and write the date next to it.

## A. Accounts (do today)

1. **2-step verification on every account that can reach the app**, with
   an authenticator app or a security key (not SMS where there is a choice):
   - Google (Firebase and Google Cloud owner):
     <https://myaccount.google.com/signinoptions/two-step-verification>.
     Prefer a passkey or security key; turn on Advanced Protection if you
     can (<https://landing.google.com/advancedprotection/>).
   - Apple ID / App Store Connect: <https://account.apple.com> > Sign-In
     and Security (two-factor is on for new Apple IDs; check the trusted
     numbers are yours).
   - GitHub: <https://github.com/settings/security> > Two-factor
     authentication (authenticator app + recovery codes kept offline).
   - Codemagic: <https://codemagic.io/settings> > Security (or sign in
     only through GitHub with 2-step on).
   - Meta Business (WhatsApp):
     <https://business.facebook.com/settings/security> > require two-factor
     for everyone.
   - Sentry: <https://sentry.io/settings/account/security/>; Algolia and
     Stream dashboards: account security pages.
2. **Fewest people with Owner/Editor.** Google Cloud IAM:
   <https://console.cloud.google.com/iam-admin/iam?project=<project>>.
   Only you as Owner; developers get the narrowest role they need, on
   staging only. Remove anyone who has left (runbook section 6).

## B. Firebase and Google Cloud (prod, then staging)

3. **Enforce App Check on Firestore and Storage** (CLAUDE.md requires it;
   the setup script only registers the apps). First look at the metrics:
   <https://console.firebase.google.com/project/<project>/appcheck/products>
   > Cloud Firestore: when nearly all requests are "verified" (after the
   TestFlight build is in use), press **Enforce**; same for Cloud Storage.
   Callables already enforce it in code.
4. **Admin second factor: TOTP only.** Authentication > Settings >
   Multi-factor authentication:
   <https://console.firebase.google.com/project/<project>/authentication/settings>.
   Enable TOTP; leave SMS multi-factor **off** (the functions and rules now
   refuse an SMS second factor anyway). Same page: **Password policy**:
   require at least 12 characters, enforce. **User account linking** and
   **email enumeration protection**: on.
5. **Point-in-time recovery and daily backups (prod).**
   <https://console.cloud.google.com/firestore/databases?project=<project>>
   > (default) > Disaster recovery: PITR on; backup schedule daily, keep
   14 days. Test a restore once (docs/restore-test.md).
6. **Data Access audit logs** (who read what, for insiders and breaches):
   <https://console.cloud.google.com/iam-admin/audit?project=<project>>:
   tick Data Read and Data Write for **Cloud Firestore API**, **Cloud
   Storage**, **Secret Manager API**, **Cloud KMS**, **Identity Toolkit
   API**. Cost: small at pilot size; check docs/COSTS.md after a week.
7. **Keep an untouchable copy of the logs** (audit log immutability):
   Logging > Log Router:
   <https://console.cloud.google.com/logs/router?project=<project>> >
   Create sink > destination: a new Cloud Storage bucket in europe-west1
   with **Retention policy 400 days, Locked**; filter
   `logName:"cloudaudit.googleapis.com"` (admin activity and the Data
   Access logs of item 6). The Firestore `auditLog` collection is copied
   by the daily backup; the log bucket is the copy no one can edit.
   Nobody, you included, can delete those files before the retention ends.
8. **Public access prevention on every bucket**:
   <https://console.cloud.google.com/storage/browser?project=<project>> >
   each bucket > Permissions > Public access prevention: **Enforced**.
9. **Restrict every API key** (the Firebase web and iOS keys and the iOS
   Maps key are public by design, so their restrictions are what protects
   them): <https://console.cloud.google.com/apis/credentials?project=<project>>
   - iOS keys: Application restriction "iOS apps" with the bundle ID;
     API restriction: only the APIs that key needs (Maps SDK for iOS; for
     the Firebase key: Identity Toolkit, Token Service, Firestore, Firebase
     Installations, App Check, Cloud Storage for Firebase, FCM).
   - Web key (admin panel): "Websites" with the admin site's two domains.
   - Server key (`MAPS_SERVER_KEY`): no application restriction, API
     restriction Places API (New) + Routes API only.
   The staging keys in `lib/firebase/firebase_options_staging.dart` are in
   the public repository: check they are restricted as above.
10. **Dedicated service account for Cloud Functions** (high, open): today
    the functions run as `<number>-compute@developer.gserviceaccount.com`,
    which on older projects has **Editor** on everything. Plan (developer
    task, one change, test on staging first): create
    `functions-runtime@<project>.iam.gserviceaccount.com` with Cloud
    Datastore User, Storage Object Admin on the two buckets, Secret Manager
    Secret Accessor, Firebase Authentication Admin, Cloud KMS
    CryptoKey Encrypter/Decrypter on the photo key, Logging Log Writer,
    Monitoring Metric Writer, Eventarc Event Receiver, Pub/Sub Subscriber,
    Service Account Token Creator on itself; set
    `setGlobalOptions({ serviceAccount })`; then remove Editor from the
    default compute account. Ask the developer to do it as one prompt.
11. **WhatsApp spend cap**: Meta Business > WhatsApp Manager > Payment
    settings: set a monthly spending limit and alert, so code requests
    from bots cannot run up a bill.
12. **Identity Platform logging** (for alert 13a): Authentication >
    Settings > **Cloud Logging: enable** (Identity Platform logs every
    sign-in).

## C. Alerts (Cloud Monitoring)

13. Create these alerting policies, notification channel = your email and
    phone (Monitoring > Alerting:
    <https://console.cloud.google.com/monitoring/alerting?project=<project>>).
    Log-based ones need a log-based metric first (Logging > Log-based
    metrics: <https://console.cloud.google.com/logs/metrics?project=<project>>).
    a. **Admin sign-in**: log-based metric with filter
       `resource.type="identitytoolkit_project" AND protoPayload.methodName:"SignInWithPassword"`;
       alert on any value > 0 outside your working hours (or on every
       sign-in while there are only one or two admins).
    b. **Rule denials spike**: metric
       `firestore.googleapis.com/rules/evaluation_count` filtered to
       `result = DENY`; alert when more than 500 in 5 minutes (tune after
       a week of normal use).
    c. **Mass reads**: metric `firestore.googleapis.com/document/read_count`;
       alert at 5 times the normal hourly peak.
    d. **Sign-in code volume**: log-based metric on the `requestCode`
       function's executions (`resource.labels.service_name="requestcode"`);
       alert above 200 an hour at pilot size (bot or cost attack).
    e. **Function errors**: Sentry already alerts on new issues
       (SETUP.md 23.6); keep the "signin", "trips" and "privacy" area rules.
    f. **Secret access by a person**: log-based metric on
       `protoPayload.serviceName="secretmanager.googleapis.com" AND protoPayload.methodName:"AccessSecretVersion" AND NOT protoPayload.authenticationInfo.principalEmail:"gserviceaccount.com"`;
       alert on any.
    g. **IAM change**: `protoPayload.methodName="SetIamPolicy"`; alert on any.
14. Budget alerts already exist (USD 20; COSTS.md). Add a second budget
    for prod with a lower first threshold if the pilot starts.
15. Look at Admin panel > Security alerts once a week (scraping and
    retention-failure alerts).

## D. GitHub (public repository)

16. <https://github.com/<owner>/<repo>/settings/security_analysis>: turn on
    **Dependabot alerts**, **Dependabot security updates**, **Secret
    scanning** and **Push protection** (all free for public repositories).
    The repo now has `.github/dependabot.yml` for version updates.
17. Branch protection for `main`:
    <https://github.com/<owner>/<repo>/settings/rules> > New branch
    ruleset > target `main`: require a pull request (0 or 1 approvals is
    fine while you work alone with the coordinator), block force pushes,
    block deletion, require the "checks" workflow to pass, require signed
    commits only if every contributor signs.
18. Actions settings:
    <https://github.com/<owner>/<repo>/settings/actions>: "Workflow
    permissions: Read repository contents" (the workflow asks for more
    only where needed), untick "Allow GitHub Actions to create and approve
    pull requests", "Require approval for all outside collaborators" for
    fork pull requests.
19. Codemagic: environment groups hold the App Store Connect key and the
    defines; limit who is in the Codemagic team; builds stay manual or on a
    `v*` tag.

## E. After the next deploy

20. **Admin panel CSP.** The panel now sends the full Content Security
    Policy as report-only. Open the staging admin panel, sign in, open a
    case with photos, Settings and Users, then open the browser's
    developer console: if there is **no** "Content-Security-Policy-Report-Only"
    message, ask the developer to make that policy the enforced one (one
    line in firebase.json). If there are messages, send them to the
    developer (they name the host to add).
21. **Feature switches.** Admin panel > Settings: switch Settle up **off**
    once (and leave the wallet off). The server already treats a missing
    switch as off; writing it makes the app hide Settle up too.
22. **Admins sign in again for sensitive actions.** Opening photos or
    routes, suspending, admin accounts and feature switches now ask for a
    sign-in less than 30 minutes old ("Your session ended. Sign in
    again."). That is expected.
23. Choose the external penetration tester (SECURITY.md); give them
    threat-model.md as the starting point.
