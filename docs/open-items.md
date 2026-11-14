# Open items, known bugs and missing accounts

State after Prompt 13 (14 Nov 2026). One list for the owner: what is
missing before testers, before the pilot and before the App Store. Each
line says who acts. Sources: the progress notes and reviews of Prompts 1
to 13, docs/DECISIONS.md.

## A. Accounts and setup the owner still has to do

| # | Item | Needed for | Where |
| --- | --- | --- | --- |
| A1 | **Firebase projects** dev, staging, prod: created, Blaze, region, Auth upgrade, App Check (App Attest), APNs key, flutterfire options committed for staging and prod (still placeholders in `lib/firebase/firebase_options_staging.dart` / `_prod.dart`) | TestFlight (staging), pilot (prod) | SETUP.md 3 |
| A2 | **Codemagic**: `CodemagicASC` integration, `staging_defines` group, `APP_STORE_APPLE_ID` of the staging app in `codemagic.yaml` (still `0000000000`) | TestFlight | docs/testflight.md |
| A3 | **App Store Connect**: staging app record, internal testing group; later the prod app, privacy answers, privacy policy URL, screenshots, review notes | TestFlight / App Store | docs/testflight.md, docs/app-store-privacy.md, docs/app-review-notes.md |
| A4 | **WhatsApp Business**: verified business, sender number, every template approved in Arabic and English (`cp_code` and the alert templates in SETUP 18.4, 20.3 incl. new `cp_run_still_on`, 22.3) | Real sign-in codes on staging/prod | SETUP.md 18.4 |
| A5 | **Valify** contract and keys (ID check and face match). Until then the face match is a stub: every new-phone check and phone change waits for an admin (now possible from the panel, Prompt 13) | Pilot | SETUP.md 12 |
| A6 | **Wallet partner** (CBE-licensed) contract and API; the wallet stays a fake with test money until then | Pilot with money | SETUP.md 21.5 |
| A7 | **Google Maps keys** per project (iOS, Android, web, server) with restrictions and caps | Maps on staging | SETUP.md 15.2 |
| A8 | **Stream** dev/staging/prod apps, secrets, chat setup script | Chat on staging | SETUP.md 19 |
| A9 | **Algolia** app and keys (staging/prod) | School search on staging | SETUP.md 14.4 |
| A10 | **Sentry** projects and DSNs; alert rules | Error reports | SETUP.md 6, 23.6 |
| A11 | **Email service** for the new-phone alert email (Trigger Email extension + SMTP provider, for example Resend free tier); no email is sent until it is set up | New-phone emails | SETUP.md 23.4 |
| A12 | **KMS key** for the photos bucket, Storage lifecycle, retention TTLs | Staging and prod | SETUP.md 23.2, `tool/setup_retention.sh` |
| A13 | **Public privacy policy and terms page** (App Store requires a URL) | App Store | Owner + lawyer |
| A14 | **Admin accounts** with two-step sign-in on staging (to approve verifications during the test) | TestFlight test | SETUP.md 13.1, 13.2 |
| A15 | Demo account and review code for Apple | App Store review | docs/app-review-notes.md |

## B. Owner decisions still open

| # | Question | Default used now |
| --- | --- | --- |
| B1 | Paid location plugin (about USD 400) for Android or if iPhone tracking is not reliable enough in the pilot | Free geolocator; decide after test-iphone.md T1 to T7 |
| B2 | Existing parents accepted the 2026-11-13 privacy policy: ask them again for the 2026-11-14 version (one-time screen) or rely on a notice | Notice (no forced screen) |
| B3 | A deletion job for transfer records at the end of the 5 years | None yet (append-only); records are kept |
| B4 | External penetration test (MASVS L2): choose and pay a tester | Not done (SECURITY.md) |
| B5 | Data protection officer and PDPC licence (Law 151 regulations) | Owner with the lawyer |
| B6 | Revenue number of families (spec section 13) | Not set |

## C. Accepted limitations (decided, not bugs)

| # | Item | Decision |
| --- | --- | --- |
| C1 | **Chat stays connected up to 60 minutes after sign-out** on a signed-out phone (Stream token lifetime, `CHAT_TOKEN_TTL_MIN`) | Accepted by the owner (14 Nov 2026, 13:29). Firebase data closes at once. Fix later: call `chat.revokeTokens(uid)` in `revokeSessions`. |
| C2 | **Swiping the app away stops location on iPhone** (free plugin) | Accepted (DECISIONS.md "Location tracking on iPhone"): the server pushes the driver "Run still on" after 2 minutes and tells the parents |
| C3 | Transfer records kept 5 years | Confirmed (owner, 13:29) |
| C4 | Trips of a closed carpool | Kept per parent: active + 1 year; built in Prompt 13 (`trip_retention.ts`) |

## D. Known bugs and gaps (not done)

| # | Item | Impact | Plan |
| --- | --- | --- | --- |
| D1 | **Flutter and rules tests not run in this workspace** (no Flutter SDK, no emulators). Prompt 13's widget, golden and screen tests are written, not run | CI may show small analyzer or test fixes | One CI run on the branch (coordinator) |
| D2 | **Screenshots / goldens** of the new screens (gate, banner, steps) not produced here (`full=false` in CI) | Owner cannot see them yet | Run the full screenshots workflow at merge |
| D3 | geolocator's iOS permission prompt must offer "While Using the App" (the always key is in Info.plist because Apple requires it for the linked API; the app never asks for Always) | If iOS shows an "Always" upgrade prompt, App Review may ask | Check in test-iphone.md L2 |
| D4 | Android background tracking needs a foreground-service notification (geolocator `ForegroundNotificationConfig`) and "Allow all the time" flow | Android only | Stage 3 |
| D5 | The notification permission is asked at first sign-in without an in-app explanation screen (drivers see one in the gate) | Some parents may refuse | Add a pre-permission screen in a later design prompt |
| D6 | Mid-run loss is detected on the run screen; if the driver is on another screen of the app, the steps show when they come back to the run screen (the server alert still goes after 2 minutes) | Small delay | Move monitoring to the app shell later |
| D7 | Route-archive trigger cost (`archiveRouteOnTripWrite` runs on every trip write) | Cost at scale | Prompt 12 review item 11; filter in the trigger |
| D8 | Anonymising stops silently at its read limits (2,000 trips, 500 memberships) | Very large accounts | Throw when a page is full (Prompt 12 review open item 4); the new trip-retention steps already do |
| D9 | `orphanTrips` reads trips with driver "deleted" each day; if more than 200 such trips are all still kept, newer ones wait | Large scale only | Add a "checkedAt" cursor |
| D10 | Android analytics manifest flag (ad ID off) | Android only | Stage 3 |
| D11 | Chat does not open offline at a cold start (needs a cached Stream token) | Offline only | Prompt 9 review #2 |
| D12 | `confirmEmail` only after a recent email change (optional hardening) | Low | Prompt 2 review N3 |
| D13 | Admin panel screens for security alerts and privacy requests (callables exist) | Admins use the console | Later admin prompt |
| D14 | Analytics events other than the privacy ones are in the catalog but not yet sent by their screens | Less usage data | One line each when the screens are next touched |
| D15 | FCM registration by Firebase Installation ID (firebase_messaging 17 deprecates tokens) | Future SDK change | Planned change with the server |
| D16 | Lockfiles (`pubspec.lock`, `package-lock.json`) not committed (no registry here) | Reproducible builds | Commit from CI |
| D17 | Website (Stage 2) and Android (Stage 3) platform work | — | Later stages |
| D18 | Lawyer's answers: all confirmed (DECISIONS.md "Legal" and "Owner updates 12:30"); the retention periods need the privacy policy text updated by the lawyer for the published page (A13) | — | Owner |
