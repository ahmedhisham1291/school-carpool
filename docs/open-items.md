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
| A8 | **Stream** dev/staging/prod apps, secrets, chat setup script | Chat on staging | SETUP.md 19 |
| A9 | **Algolia** app and keys (staging/prod). Staging: sign up, then give the Application ID, Write and Search-only keys to `tool/cloud_setup.sh` when it asks (keys hidden; never in chat); commit the three printed non-secret lines. Until then the real schools list makes the app say "search unavailable" | School search on staging (real list loaded by step 12) | **docs/algolia-setup.md**, SETUP.md 14.4 |
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
| C1 | **Chat stays connected up to 60 minutes after sign-out** on a signed-out phone (Stream token lifetime, `CHAT_TOKEN_TTL_MIN`) | Accepted by the owner (14 Nov 2026, 13:29). Firebase data closes at once. Fix later: call `chat.revokeTokens(uid)` in `revokeSessions`. |
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
| D11 | Chat does not open offline at a cold start (needs a cached Stream token) | Offline only | Prompt 9 review #2 |
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
| D23 | **Real schools list (branch schools-osm):** Flutter tests of the search fallback written, not run here; the OpenStreetMap download and the Algolia sync not run against the real services from this workspace (no internet here) | First real run is in Cloud Shell | Owner runs `tool/cloud_setup.sh`; send the developer the "Schools import summary" it prints (not secret) |
| D24 | OpenStreetMap attribution ("(c) OpenStreetMap contributors", ODbL, required), a "Wikidata" credit (CC0, asked, not required) and the Overture Maps line (required by CDLA Permissive 2.0 / Apache 2.0: "Overture Maps Foundation, overturemaps.org", plus the provider lines: Meta, Microsoft, PinMeTo, Krick, RenderSEO, DAC, BrightQuery, Birdeye, Uberall, OpenTravel Alliance under CDLA Permissive 2.0; Foursquare (c) Foursquare Labs, Inc., Apache 2.0, with its NOTICE link; AllThePlaces CC0; full text in `fetch_overture_schools.ATTRIBUTION`) not yet shown in the app; schools from the list carry OSM names, which can be wrong or missing an Arabic/English form (the import fills one from the other) | Licence condition before the public launch; quality of school names | Licences/about screen before launch; admins fix names in the panel (an edited school is never overwritten) |
| D26 | **Places and F46 (branch places-address):** Flutter widget, golden and rules tests written, not run here; the OSM places download and the admin-level measurement not run on real data yet (first run is the owner's Cloud Shell run; the report shows the coverage per level) | CI may show small fixes; the Area/District levels are known only after that run | One CI run (coordinator); owner runs step 12 and sends the "Places" lines of the summary |
| D27 | F46 street name is plain text (no suggestions): OSM street names per district are not in our data yet | Parents type the street | Add a street download per area if parents ask for it |
| D28 | Carpool search and suggestions do not filter by place area or district yet (the public record has the fields) | None today | Add the filter with the next matching change (F46 note in the spec) |
| D29 | CLAUDE.md still says "Feature IDs (F1 to F45)"; F46 (home address) is in docs/spec.md section 4 | Wording only | Owner updates CLAUDE.md |
| D30 | **schools-sources:** the per-governorate OSM download, the Overture query (DuckDB on Overture's S3) and the names check have not run on real data (no network to those services here); the Overture confidence threshold (0.5) is a first guess | Counts and threshold known after the owner's step-12 run | Owner runs step 12 and sends the "Overture", "per governorate", "per source" and "Names check" lines; raise or lower `--min-confidence` with `--from-raw` (no new download) |
| D31 | University switch (`data/schools/categories.json`) is off; if it is ever switched on, the app and admin panel need a type filter and a label for kind `university` (server and search index already accept it) | None while off | Owner decision first |
| D25 | Sample schools hidden on staging stay in Firestore (`searchHidden`) and still appear in the admin panel's school list as active | Admins only | Delete them later if no test data points at them |
| D18 | Lawyer's answers: all confirmed (DECISIONS.md "Legal" and "Owner updates 12:30"); the retention periods need the privacy policy text updated by the lawyer for the published page (A13) | — | Owner |
