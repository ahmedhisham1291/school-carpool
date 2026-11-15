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
| A4 | **WhatsApp Business**: verified business (start first: the slowest item), sender number, templates approved in Arabic and English (`login_code` and the alert templates in SETUP 18.4, 20.3 incl. `cp_run_still_on` and `cp_child_not_coming`, 22.3) | Real sign-in codes on prod (prod cannot send a code without it) | **docs/meta-whatsapp-setup.md** (owner guide), SETUP.md 11.5 and 18.4 |
| A5 | **Valify** contract and keys (ID check and face match). Until then the face match is a stub: every new-phone check and phone change waits for an admin (now possible from the panel, Prompt 13) | Pilot | SETUP.md 12 |
| A6 | **Wallet partner** (CBE-licensed) contract and API; the wallet stays a fake with test money until then | Pilot with money | SETUP.md 21.5 |
| A7 | **Google Maps keys** per project (iOS, Android, web, server) with restrictions and caps | Maps on staging | SETUP.md 15.2 |
| A8 | ~~Stream apps, secrets, chat setup script~~ **Not needed any more:** chat is our own, on Firestore (improvement B). Only the Storage rules role for chat photos, which `tool/cloud_setup.sh` grants | Chat photos on staging | SETUP.md 19.2 |
| A9 | **Algolia** app and keys (staging/prod) | School search on staging | SETUP.md 14.4 |
| A10 | **Sentry** projects and DSNs; alert rules | Error reports | SETUP.md 6, 23.6 |
| A11 | **Email service** for the new-phone alert email (Trigger Email extension + SMTP provider, for example Resend free tier); no email is sent until it is set up | New-phone emails | SETUP.md 23.4 |
| A12 | **KMS key** for the photos bucket, Storage lifecycle, retention TTLs | Staging and prod | SETUP.md 23.2, `tool/setup_retention.sh` |
| A13 | **Public privacy policy and terms page** (App Store requires a URL) | App Store | Owner + lawyer |
| A14 | **Admin accounts** with two-step sign-in on staging (to approve verifications during the test) | TestFlight test | SETUP.md 13.1, 13.2 |
| A15 | Demo account and review code for Apple | App Store review | docs/app-review-notes.md |
| A16 | **Make the repository private again** (it is public for free CI): secret scan of the whole history, decide about `docs/reviews` and this file, set an Actions budget, switch, re-check Codemagic and the Cloud Shell clone | Before the public launch | **docs/launch-private-repo.md** |

## B. Owner decisions still open

| # | Question | Default used now |
| --- | --- | --- |
| B1 | Paid location plugin (about USD 400) for Android or if iPhone tracking is not reliable enough in the pilot | Free geolocator; decide after test-iphone.md T1 to T7 |
| B2 | Existing parents accepted the 2026-11-13 privacy policy: ask them again for the 2026-11-14 version (one-time screen) or rely on a notice | Notice (no forced screen) |
| B3 | A deletion job for transfer records at the end of the 5 years | None yet (append-only); records are kept |
| B4 | External penetration test (MASVS L2): choose and pay a tester | Not done (SECURITY.md) |
| B5 | Data protection officer and PDPC licence (Law 151 regulations) | Owner with the lawyer |
| B6 | Revenue number of families (spec section 13) | Not set |
| B7 | **Settle up records: how long to keep them.** Now: while either parent's account is active, plus 1 year after the last of the two closes (the same rule as trips; a deleted parent shows as an initial). Owner and lawyer to confirm the period and add it to the published privacy policy text (A13). The lawyer already confirmed that recording payments between parents needs no Central Bank licence (DECISIONS.md, 14 Nov 2026) | 1 year after closure (`SETTLE_KEEP_AFTER_CLOSE_MS`, `AFTER_CLOSURE_DAYS`) |
| B8 | **Settle up limits:** EGP 5,000 per request (`config/settleUp.maxAmount`), 20 new requests a day, 10 unfinished between two parents, report after 2 "Not received" | As listed (SETUP.md 21b) |
| B9 | **InstaPay link:** InstaPay publishes no link or URL scheme an app may build with a payee and an amount (the `ipn.eg/S/...` links are made inside the InstaPay app, one per user). The payer copies the address. Option for later: let a payee paste their own InstaPay share link | Copy only |
| B10 | **Feature switches after the pilot:** when to turn on ratings and vouching, and the yearly check (first checked school year is 2027-28) | Both off |

## C. Accepted limitations (decided, not bugs)

| # | Item | Decision |
| --- | --- | --- |
| C1 | ~~Chat stays connected up to 60 minutes after sign-out~~ **Gone with our own chat (improvement B):** there is no chat token; the rules check the session and the member document on every request, so a signed-out, removed or suspended parent loses chat at once | Closed |
| C2 | **Swiping the app away stops location on iPhone** (free plugin) | Without the optional "Always": accepted, the server pushes the driver "Run still on" after 2 minutes and tells the parents. With "Always": our run_recovery plugin resumes the run after iOS relaunches the app (owner, 13:44) |
| C3 | Transfer records kept 5 years | Confirmed (owner, 13:29) |
| C4 | Trips of a closed carpool | Kept per parent: active + 1 year; built in Prompt 13 (`trip_retention.ts`) |

## D. Known bugs and gaps (not done)

| # | Item | Impact | Plan |
| --- | --- | --- | --- |
| D1 | **Flutter and rules tests not run in this workspace** (no Flutter SDK, no emulators). Prompt 13's widget, golden and screen tests are written, not run | CI may show small analyzer or test fixes | One CI run on the branch (coordinator) |
| D2 | **Screenshots / goldens** of the new screens (gate, banner, steps) not produced here (`full=false` in CI) | Owner cannot see them yet | Run the full screenshots workflow at merge |
| D3 | The gate's first location prompt (geolocator) must offer "While Using the App"; "Always" comes only from the optional screen (run_recovery plugin) | If iOS shows "Always" first, App Review may ask | Check in test-iphone.md L2 |
| D3b | **Run recovery verified only on a real iPhone:** the app is patched to the classic app delegate (no UIScene) so a background relaunch runs Dart; must be revisited when Apple requires UIScene. The Swift plugin and the AppDelegate are compiled only in CI; relaunch after a swipe needs Always and movement (iOS decides when, usually after about 500 m); a relaunched app has seconds of background time to sign in, call the server and restart tracking; iOS may not relaunch after a force quit on some versions, and never with Background App Refresh or Location Services off | Recovery may be slower than the 2-minute fallback, or not happen | test-iphone.md T5 to T8; if unreliable, the paid plugin (B1) |
| D4 | Android background tracking needs a foreground-service notification (geolocator `ForegroundNotificationConfig`) and "Allow all the time" flow | Android only | Stage 3 |
| D5 | The notification permission is asked at first sign-in without an in-app explanation screen (drivers see one in the gate) | Some parents may refuse | Add a pre-permission screen in a later design prompt |
| D6 | Mid-run loss is detected on the run screen; if the driver is on another screen of the app, the steps show when they come back to the run screen (the server alert still goes after 2 minutes) | Small delay | Move monitoring to the app shell later |
| D7 | Route-archive trigger cost (`archiveRouteOnTripWrite` runs on every trip write) | Cost at scale | Prompt 12 review item 11; filter in the trigger |
| D8 | Anonymising stops silently at its read limits (2,000 trips, 500 memberships) | Very large accounts | Throw when a page is full (Prompt 12 review open item 4); the new trip-retention steps already do |
| D9 | "Run still on" is not sent to the driver in a gap the app already reported (`reportTrackingLost` shares `staleAlertedAtMs`); if the driver then swipes the app away nobody reminds them until the next point | Small | Separate driver flag (review finding 7) |
| D9b | On-phone point buffer and run token in shared_preferences (NSUserDefaults) up to a day, cleared at the end of the run (the cap-trim bug the review found is fixed) | Low | Move to a protected file (NSFileProtectionComplete) later (review finding 9) |
| D9c | `packages/run_recovery` has no Package.swift (CocoaPods only) | Fine while a Podfile is generated | Add SPM support later |
| D10 | Android analytics manifest flag (ad ID off) | Android only | Stage 3 |
| D11 | ~~Chat does not open offline at a cold start~~ Fixed by our own chat (improvement B): no token is needed, Firestore's cache opens the chats offline. Left: a chat PHOTO cannot be sent offline (it shows "not sent", tap to retry) | Offline only | docs/progress/improve-b.md |
| D12 | `confirmEmail` only after a recent email change (optional hardening) | Low | Prompt 2 review N3 |
| D13 | Admin panel screens for security alerts and privacy requests (callables exist) | Admins use the console | Later admin prompt |
| D14 | Analytics events other than the privacy ones are in the catalog but not yet sent by their screens | Less usage data | One line each when the screens are next touched |
| D15 | FCM registration by Firebase Installation ID (firebase_messaging 17 deprecates tokens) | Future SDK change | Planned change with the server |
| D16 | Lockfiles (`pubspec.lock`, `package-lock.json`): written by the manual CI job and committed on branch `improve-e-docs` (workstream E), all four files; builds on `main` use them once that branch is merged | Reproducible builds | Coordinator: merge `improve-e-docs`. Later updates: docs/WORKFLOW.md "Package versions" |
| D17 | Website (Stage 2) and Android (Stage 3) platform work | — | Later stages |
| D19 | **Workstream A (feature switches, Settle up): Flutter and rules tests written, not run here**; goldens of the new screens not produced here | CI may show small analyzer or test fixes | One CI run on the branch (coordinator); docs/progress/improve-a.md |
| D20 | `CLAUDE.md` still says "Feature IDs (F1 to F44)" and names the wallet as the payment feature; F45 (Settle up) and the feature switches are in docs/spec.md and DECISIONS.md | Wording only | Owner updates CLAUDE.md (the builder does not edit the rules file) |
| D21 | Admin panel: the Wallet menu entry and the wallet row on the user page still show while the wallet is switched off; the pages then say "This feature is switched off" | Admins only | Hide them from the switch later |
| D22 | Settle up shows the newest 100 records on the phone; older finished ones stay on the server (and in the data export) | Very active parents only | Paging later |
| D18 | Lawyer's answers: all confirmed (DECISIONS.md "Legal" and "Owner updates 12:30"); the retention periods need the privacy policy text updated by the lawyer for the published page (A13) | — | Owner |
| D19 | **Own chat (improvement B): no automatic image moderation** (Stream's add-on is gone). Photos are only in private and carpool chats; reports and admin removal handle them | Low for the pilot | Later: Cloud Vision SafeSearch in the photo upload trigger (paid per image), if reports show a need |
| D20 | **Own chat: a blocked term removes the message a second or two after it shows**, without telling the sender why (it simply disappears) | Low | Later: a "message removed" note for the sender |
| D21 | **Own chat: a busy school group costs one read per online parent per message** (docs/COSTS.md "Chat"); group heads could be updated at most once a minute | Cost at scale | When a group passes about 200 messages a day |
| D22 | **Own chat: messages cached on the phone by Firestore stay there after sign-out** (as other Firestore data does; protected by iOS Data Protection and the app lock; SECURITY.md STORAGE-1) | Low | Clear Firestore's cache on sign-out in a later hardening pass |
| D23 | **Own chat is not merged yet:** branch `improve-b-firestore-chat` waits for the first TestFlight build on the owner's iPhone (DECISIONS.md, improvements item 3). Rules tests and Flutter tests were written, not run in the build workspace: one CI run on the branch before the merge | Before merging | docs/progress/improve-b.md |
