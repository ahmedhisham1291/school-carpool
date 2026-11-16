# App Store review audit (16 Nov 2026)

Scope: the iPhone app on branch `apple-review` (from `main` 47e102d),
checked the way Apple's App Review checks a first submission. Rules were
read from Apple's pages on 16 Nov 2026, not from memory (sources at the
end; the guidelines page says "Last updated: October 16, 2026").

**No audit can guarantee a first-time approval.** App Review is done by
people, on a real device, and they may ask for things no document lists.
This audit removes the causes we can see in the code and tells the owner
what only the owner can do. Everything marked RISK can still cause a
rejection; a rejection is answered in App Store Connect and fixed, it is
not the end.

Status words: **PASS** already right. **FIXED** changed on this branch.
**NEEDS OWNER** only the owner can do it (docs/apple-review/submission-kit.md
has the steps). **RISK** could still be questioned.

Counts over the 99 checks of sections 1 to 13 after branch `review-risks` (16 Nov 2026; a check
can carry two words, for example FIXED + NEEDS OWNER): PASS 46, FIXED 40,
NEEDS OWNER 22, RISK 3 (was RISK 13 before that branch). The three left
are not code: crashes can only be tested on a device, children's data is a
reviewer's reading of 5.1.4, and the data-source credits are a licence
condition. Section 14 says what code cannot make zero-risk.

What was run here: `python3 -m unittest discover -s tool` (48 pass),
Functions tests (856 pass, with the workspace's stub typings), `bash -n`,
`ruby -c`, YAML parse. **Not run here:** Flutter analyze/tests/goldens
(no SDK: the new Dart code and widget tests are written, not run), the
rules tests (no rule changed), any iOS build, CocoaPods, and
`tool/ios/configure_xcode.rb` on a real project. The first Codemagic
staging build is the real test of the native changes.

**Branch `review-risks` (16 Nov 2026), owner instruction "remove every
remaining risk":** notifications never block a run (4.5.4, 5.1.2(i)); no
"Always" location (5.1.1); prompt deletion of photos, face reference,
messages, address and routes (5.1.1(v)); usage statistics opt-in
(5.1.1(ii)); a new account can look around before the ID check (2.1); a
friendly "This demo account can't do that"; `review-access -- on` seeds the
demo data and a daily job keeps the demo runs fresh; UIScene life cycle;
the prod build stops for an Apple-listed SDK without a privacy manifest.
Run there: Functions tests (881 pass), tool tests (66 pass). Written, not
run there: the Flutter tests, any iOS build. Plan and notes:
docs/progress/review-risks.md.

## 1. Guideline 2.1 App completeness

| Item | Status | Evidence and change |
| --- | --- | --- |
| Developer screens in the store build | PASS | The gallery route exists only when `showDevTools` (dev flavor): `lib/router/app_router.dart:589`, `lib/config/flavor.dart` (`showDevTools`). `PlaceholderTabScreen` ("Coming soon") is not in the router (dead code). |
| "Draft text" note on the terms sheet | FIXED | It was shown to every parent (`termsDraftNotice`). Now testers only: `lib/features/onboarding/terms_screen.dart:70` (hidden when the flavor is prod). Test: `test/about/about_legal_test.dart`. |
| Wallet switched off shows nothing | PASS | Profile row only when `features.wallet` (`lib/features/profile/profile_screen.dart:247`); routes behind `FeatureGate`; default off on the server (`functions/src/features/model.ts`, `PILOT_DEFAULTS`). A deep link shows "Not available yet" with a way back, which only a notification or link could reach while it is off. |
| Ratings / yearly check off | PASS | Same switches, default off. |
| Fake providers in prod | PASS | Fake WhatsApp, fake KYC and fake wallet are refused when `APP_ENV=prod` (`functions/src/whatsapp/sender.ts:170`, `functions/src/verification/kyc.ts:151`). |
| Demo account without an Egyptian WhatsApp number | PASS | Already there: one allow-listed number with a fixed code, off by default, at most 30 days, keyed hashes only, all sign-in limits apply (`functions/src/auth/otp_flow.ts`, `functions/scripts/review_access.ts`). The code is not in Secret Manager: only its keyed hash is stored (in `config/reviewAccess`, closed to the app), keyed with `OTP_HMAC_KEY`, which is in Secret Manager. That is safer than storing the code. |
| Second demo account ("the other side") | FIXED | Optional second allow-listed number with its own code: `functions/src/auth/otp_flow.ts:123` (`extra`), `REVIEW_PHONE_2`/`REVIEW_CODE_2` in `functions/scripts/review_access.ts`. Tests: `functions/test/review_demo.test.ts`. |
| Demo sign-ins audited | FIXED | Each demo sign-in writes `auth.reviewAccess.signIn` to the admin audit log (no number, no code): `functions/src/auth/callables.ts:122`. A failed audit write never blocks the reviewer. |
| Demo data in the submitted project | FIXED | `functions/scripts/review_demo_lib.ts` (run by `review-access -- on`, or `review-demo -- seed|status|remove`): two verified demo parents (fake data), a demo school hidden from search, one carpool, a child each, the driver's car, consent, runs planned and confirmed. Refuses numbers not on the allow-list or owned by a real account. Plan: `functions/src/auth/review_demo.ts`. |
| **Reviewer was blocked after sign-in** (blocker found) | FIXED | On Apple's phone the demo parent is "a new phone": with a face reference it opened the new-phone selfie check (everything closed until an admin acted); without one the driver could not start a run (`no-reference`). Now the two demo parents carry `reviewDemoUntilMs` (written only by the script, ends with the review window, at most 30 days): no new-phone selfie (`functions/src/privacy/devices.ts:201`) and the demo driver starts a run without a reference or a random selfie (`functions/src/trips/flow.ts:340`, `:425`). The app cannot write that field (rules allow only `language` on `users/{uid}`). Tests in `privacy.test.ts`, `trips.test.ts`. **Tightened by the validator review** (docs/reviews/apple-review.md, B1 and B2): the date alone is no longer enough. The exemption needs the account to be one of the two listed in `config/reviewAccess.demoUids` while that access is on (`reviewDemoState`, `functions/src/auth/review_access.ts`), so `review-access -- off` ends it at once. |
| Demo accounts are no way around the ID check | FIXED (validator review) | A demo parent is "verified" without an ID check and its code is known outside the team. The server now confines it (`functions/src/privacy/device_gate.ts`): no driving schools, no joining or searching outside the demo school, no invite links, no "looking for a carpool" post, no new child or documents, no guardian link, no phone change, no wallet; outside the window every function refuses it except Delete account; `review-demo -- remove` takes "verified" away and signs it out. The mark `reviewDemo` on the account is permanent. Tests: `functions/test/review_demo.test.ts`, `tests/rules/users.test.ts`. |
| Reviewer sign-in depended on WhatsApp settings | FIXED | The sender was built before every code request, so a missing WhatsApp setting failed the demo number too. Now built on first use: `functions/src/auth/callables.ts:105`. |
| Demo refusals say why | FIXED (review-risks 6) | A refused demo action showed "Something went wrong". All 13 failure types now say "This demo account can't do that. It works only with the demo school and carpool." (or that the demo has ended), Arabic and English (`lib/features/auth/demo_refusal.dart`, test `test/auth/demo_refusal_test.dart`). |
| Chat in the demo | NEEDS OWNER | The carpool chat is made by the deployed triggers when the carpool is written. Send one message from each demo account before submitting so the chat is not empty (kit, step 9). |
| A reviewer who makes a NEW account | FIXED (review-risks 5) | Was a dead end (Profile only). Now a new account opens every tab and its own pages; only what involves another family (carpools, runs, chats, parents nearby, ratings, family links, Settle up, wallet) opens one screen that explains the ID check (child safety) with "Later" back to the tab, and a card on Home, Carpools and Chats says the same (`needsVerification`, `lib/router/session_redirect.dart`; `VerifyAccountScreen`). The server refuses the same actions (`functions/test/verification_scope.test.ts`). The notes still ask the reviewer to use the demo account. |
| Backend on | NEEDS OWNER | Prod Firebase options are still the placeholder (`lib/firebase/firebase_options_prod.dart:1`): the app would open on the error screen (`lib/bootstrap.dart:38`). The new `ios-prod` workflow refuses to build until it is replaced (`codemagic.yaml:129`). |
| Crashes, stability | RISK | Not testable here. Run docs/test-iphone.md on the prod build with the demo accounts before submitting. |

## 2. Guideline 5.1.1 Privacy: data collection and storage

| Item | Status | Evidence and change |
| --- | --- | --- |
| Purpose strings present, specific, Arabic and English | PASS | `tool/patch_native.py` and `tool/ios/{ar,en}.lproj/InfoPlist.strings`: camera, photo library, location when in use, Face ID. No "Always" text since review-risks 2. Checked by `tool/test_patch_native_review.py` and, on the built app, `tool/check_ios_app.py` (an Always key is a problem). |
| Face ID text said "every wallet transfer" while the wallet is off | FIXED | Now "unlocks the app when you turn on App lock, and confirms money transfers". |
| "Developer builds connect to test servers" text and local networking in staging/prod | FIXED | `NSLocalNetworkUsageDescription` and `NSAllowsLocalNetworking` only in dev: `tool/patch_native.py:149` (`review_info`). |
| No permission the app does not use | PASS | No contacts, microphone, tracking, motion, Bluetooth or calendar keys (test `test_no_permission_we_do_not_use`). Photos use the system picker. |
| Permission asked only when needed | PASS | Location: "use my location" on the home screen (`lib/features/maps/location_service.dart`) or when starting a run (`lib/features/trips/location_gate.dart`). Camera: at the ID step. Never "Always" (review-risks 2). |
| App works when location is denied | PASS | Address search and manual pin instead; only starting a run needs it (DECISIONS.md, 13:05). Matches 5.1.1(iv). |
| Notifications required to start a run | FIXED (review-risks 1) | Owner decision 16 Nov 2026. The driver gate is location only; with notifications off the driver sees one warning ("You may miss alerts") with Open Settings and Start anyway (`lib/features/trips/location_gate.dart`). Guideline 4.5.4 and 5.1.2(i) met. |
| Notification prompt without an explanation first | PASS | Asked at first sign-in (`lib/features/notifications/notification_center.dart`); allowed, and a refusal now blocks nothing. A pre-permission screen stays a design wish (open item D5). |
| Privacy policy link in the app | FIXED | Was only on the sign-up step. Now About > Legal and support always shows the privacy policy, terms and code of conduct, with the public page when the build has one: `lib/features/about/about_screen.dart:96`, `lib/features/about/legal_links.dart`. |
| Privacy policy URL for App Store Connect | FIXED + NEEDS OWNER | Pages built by `tool/links_site.py:74` from `hosting/links/privacy.html` (Arabic and English): data, purposes, third parties, retention, rights, deletion, place of processing. The owner deploys them with a real support address and legal name, and the lawyer approves the wording. |
| Account deletion in the app (5.1.1(v)) | PASS | Profile > Privacy > Delete account (`lib/features/privacy/privacy_screen.dart`, `delete_account_screen.dart`), done by the app, no email or call. The screen says what is deleted now and the short list of minimised records kept. |
| Data kept after deletion | FIXED (review-risks 3) + NEEDS OWNER | Owner decision 16 Nov 2026 supersedes the 1-year rule: ID photos, selfies, the face reference, case records, the parent's chat messages, home address and pin, children, car and archived routes are deleted with the account (`functions/src/privacy/account_deletion.ts`). Kept, minimised and without name, phone, photo or address: shared run summaries (an initial), consent records, Settle up and transfer records, reports, audit log; a 30-day hold only while a report about the parent is open. Screen, public pages and privacy answers say so. **The lawyer confirms the list** (open item B13). |
| Public account-deletion page | FIXED | `/delete-account` on the links site (also needed by other stores). |
| Data export | PASS | Profile > Privacy > Download my data (`privacy_screen.dart:196`). |
| Consent for ID, selfie, children's data | PASS | Separate consent records at submission (`lib/features/auth/legal_documents.dart`, `functions/src/verification/submission.ts:51`); withdraw on the privacy screen. |
| Data minimisation (5.1.1(iii)) | PASS | ID and selfie only for verification (child safety), justified in the review notes; national ID number stored as a keyed hash; no address book; photos through the system picker. |
| Legal entity for sensitive data (5.1.1(ix)) | NEEDS OWNER | "Apps ... that require sensitive user information should be submitted by a legal entity that provides the services, and not by an individual developer." The app requires national IDs and face images. If the Apple Developer account is an Individual account, convert it to an Organization (needs a D-U-N-S number) before submitting. |
| Children's data (5.1.4, 2.3.8) | PASS + RISK (low) | Not a Kids Category app; the users are adult parents; children do not use it. Parents enter a child's first name, age, grade and school. The store text in the kit avoids "for kids / for children". Third-party analytics is allowed because the app is not primarily for kids. |
| Analytics consent (5.1.1(ii)) | FIXED (review-risks 4) | Usage statistics are off until the parent says yes (Home card asked once, never blocking; switch in Settings and on the privacy screen; consent record on the server). No IDFA, no advertising, no ATT prompt needed. Sentry error reports (scrubbed) stay on and are disclosed. |

## 3. Privacy manifest and third-party SDKs

| Item | Status | Evidence and change |
| --- | --- | --- |
| App privacy manifest | FIXED | There was none. `tool/ios/PrivacyInfo.xcprivacy`: no tracking, no tracking domains, required-reason APIs (UserDefaults CA92.1, file timestamp C617.1, system boot time 35F9.1, disk space E174.1), collected data types as in docs/app-store-privacy.md. Copied by `tool/patch_native.py:229`, added to the Runner target by `tool/ios/configure_xcode.rb`. The file-timestamp, boot-time and disk-space reasons are declared for the Dart/Flutter runtime as most Flutter apps do; our own code uses UserDefaults only. |
| Reason codes checked | PASS | Validator review: CA92.1 (UserDefaults, the app's own data), C617.1 (file timestamps inside the app container), 35F9.1 (boot time, to measure elapsed time), E174.1 (disk space, to check there is room to write) are the standard codes of their categories. Apple's article "Describing use of required reason API" was opened (it now keeps the code list on the pages of the two manifest keys, which this workspace could not open). |
| Our own plugin | FIXED | `packages/run_recovery` uses UserDefaults: manifest in `ios/Resources/PrivacyInfo.xcprivacy`, shipped through the podspec's `resource_bundles`. |
| Third-party SDK manifests | FIXED (review-risks item 10) | Apple's list of commonly used SDKs (86 names, read 16 Nov 2026) is in `tool/check_ios_app.py` (`APPLE_LISTED_SDKS`, with the framework names they take in the app and the repackaged plugins). On the built app, a listed SDK without a privacy manifest (in its framework or its resource bundle) now **stops the prod build** (`ios-prod`, `--flavor prod`) and is a warning on staging; an SDK that declares tracking stops every build. Tests: `tool/test_check_ios_app.py`. The listed SDKs we link are in the table below. |
| Collected data matches the nutrition label | PASS | The manifest test compares the types with docs/app-store-privacy.md section 2. |

Listed SDKs in the app (Apple's name; where it comes from; version locked
in `pubspec.lock` on 16 Nov 2026). Native pod versions (Firebase iOS SDK
and its Google dependencies) are the ones the Flutter plugin pins; read
them in `ios/Podfile.lock` after a build. Every one of these has shipped a
privacy manifest since 2024; the prod build now proves it per build.

| Apple-listed SDK | Comes from | Locked version |
| --- | --- | --- |
| Flutter | Flutter engine | Flutter 3.50.0 (`codemagic.yaml`) |
| FirebaseCore, FirebaseCoreInternal, FirebaseCoreExtension, FirebaseInstallations | firebase_core | 5.1.0 (pods: as pinned by the plugin) |
| FirebaseAuth | firebase_auth | 7.0.1 |
| FirebaseFirestore, Abseil, grpcpp, BoringSSL / openssl_grpc, leveldb | cloud_firestore | 7.1.0 |
| FirebaseMessaging | firebase_messaging | 17.0.1 |
| GoogleUtilities, GoogleDataTransport, nanopb, FBLPromises, Promises, GTMSessionFetcher | Firebase dependencies (also firebase_storage 14.0.1, firebase_analytics 13.0.1, firebase_app_check 0.5.1, cloud_functions 7.0.1) | as pinned by the plugins |
| connectivity_plus | connectivity_plus | 7.3.1 |
| device_info_plus | device_info_plus | 13.3.0 |
| flutter_local_notifications | flutter_local_notifications | 19.5.0 |
| geolocator_apple | geolocator 14.1.2 | 2.4.3 |
| image_picker_ios | image_picker 1.2.4 | 0.8.13+15 |
| package_info_plus | package_info_plus | 10.2.2 |
| path_provider (repackaged as path_provider_foundation) | path_provider 2.1.6 | 2.6.0 |
| shared_preferences_ios (repackaged as shared_preferences_foundation) | shared_preferences 2.5.6 | 2.6.2 |
| url_launcher_ios | url_launcher 6.3.3 | 6.4.2 |

Not on Apple's list but linked (checked for tracking only): Sentry
(sentry_flutter 10.4.0), Google Maps (google_maps_flutter_ios 2.18.7),
local_auth_darwin 2.0.5, camera_avfoundation 0.11.1, flutter_image_compress
2.5.1, screen_protector 1.5.3, sqlite3_flutter_libs 0.5.42 (stream_chat_persistence
10.7.0, Stream chat on main), FirebaseAnalytics, FirebaseAppCheck,
FirebaseStorage, our run_recovery (own manifest).

## 4. Background location (2.5.4, 5.1.5)

| Item | Status | Evidence and change |
| --- | --- | --- |
| Background modes only what is used | PASS | `location` and `remote-notification` only (`tool/patch_native.py:294`); `fetch` and `processing` removed. Checked on the built app. |
| Visible indicator, stops with the run | PASS | `showBackgroundLocationIndicator` and background updates only during a run (`lib/features/trips/geolocator_tracker.dart:231`); stopped at the end (`:417`), server limit of hours per run. |
| Explained in the app before asking | PASS | Gate sheet with steps before the system prompt. |
| Justification for review | PASS + NEEDS OWNER | Text in the kit; Apple often asks for a video: the owner records it (docs/app-review-notes.md section 4). |
| "Always" permission | FIXED (review-risks 2) | Never asked: the optional screen, the request, significant-change monitoring and the purpose text are gone; geolocator is built without its Always request (`BYPASS_PERMISSION_LOCATION_ALWAYS=1`). A run closed by iOS resumes from the local marker when the driver opens the app; the server's "Run still on" push and the parents' alert stay. |

## 5. Guideline 1.2 User-generated content

| Item | Status | Evidence and change |
| --- | --- | --- |
| Report a message, a parent, a chat | PASS | `lib/features/chat/chat_sheets.dart`, `conversation_screen.dart:224`; "An admin reviews it within 24 hours" (`app_en.arb:1190`). |
| Block abusive users | PASS | `blockChatUser` (`functions/src/chat/callables.ts:145`), blocked list in chat settings. |
| Filter objectionable material | PASS + NEEDS OWNER | Stream block lists and auto-moderation set to block (`functions/src/chat/setup_plan.ts:50`, `:149`). They exist only after `npm run chat:setup` on the prod Stream app. |
| Terms with no tolerance for objectionable content | FIXED | The code of conduct accepted at sign-up now says so (`app_en.arb:128`, version 2026-11-16 in `legal_documents.dart` and `functions/src/auth/consents.ts`; deploy functions and app together). Same in the public terms. |
| Published contact information | FIXED | Support address in About (`about_screen.dart:115`) and on `/support`; set by `SUPPORT_EMAIL`. |
| Act on reports within 24 hours | NEEDS OWNER | The admin panel has the queue; someone must watch it every day. |
| Other UGC | PASS | School names typed by parents are reviewed before they are listed; ratings are off; profile shows first names only. |
| Chat moves to our own Firestore chat | FIXED on branch `chat-review-safe` (review-risks 9) | That branch (the Firestore chat merged with main) adds the objectionable-word filter on the server (Arabic and English list in server config, admin-editable, applied on send), keeps report and block, and makes the public pages and privacy answers follow the active chat provider from one setting. It applies when that branch merges; main still ships Stream with its block list (row above). |

## 6. Payments (3.1, 3.2)

| Item | Status | Evidence and change |
| --- | --- | --- |
| Settle up is not a purchase | PASS | Records requests between two parents for real-world shared costs; "The app does not move money" (`app_en.arb:2077`); no card or bank number; nothing digital is sold; guideline 3.1.3(e) covers goods and services used outside the app, and here the app does not even take the payment. |
| No in-app purchase, no external purchase link for digital content | PASS | No IAP code; the only money wording is Settle up. |
| Wallet | PASS | Off, hidden, refused by the server. If switched on later it is money management (3.2.1(viii): by the licensed institution): ask the lawyer and tell App Review before turning it on. |
| No licence claims | PASS | The app does not call itself a bank or wallet. Lawyer's note: DECISIONS.md, 14 Nov 2026, 17:28. |

## 7. Login (4.8, 5.1.1(v))

| Item | Status | Evidence and change |
| --- | --- | --- |
| Sign in with Apple not required | PASS | No third-party or social login; the app uses its own phone-number account with a one-time code (WhatsApp only delivers the code). 4.8: "not required if your app exclusively uses your company's own account setup and sign-in systems". |
| Personal data relevant to the core function | PASS | ID and selfie are for verifying parents before they meet other families' children; said in the notes. |
| Account needed | PASS | Every feature is account-based (carpools of verified parents). |

## 8. Design and metadata (4.0, 2.3)

| Item | Status | Evidence and change |
| --- | --- | --- |
| "School Carpool Stg" cannot ship as prod | FIXED | Prod name is "School Carpool" / "مشوار المدرسة" (`tool/bootstrap.sh`); a prod name with Stg, Dev, test or beta now stops the build (`tool/patch_native.py:130`) and the built-app check. |
| App icon | FIXED + NEEDS OWNER | The build shipped the Flutter placeholder icon. Now `tool/ios/AppIcon/icon_1024.png` (1024, no alpha) is installed (`tool/patch_native.py:211`); wrong size or alpha stops the build. The drawing (`tool/make_app_icon.py`) is a plain default: the owner approves it or replaces the file. |
| Launch screen | PASS | Flutter's plain launch storyboard (white). Not branded; acceptable. |
| iPad | FIXED | The target included iPad with phone layouts. Now iPhone only (`TARGETED_DEVICE_FAMILY = 1`, `tool/patch_native.py:139`), portrait only. It still runs on iPad in iPhone mode, where reviewers may test: phone layouts are correct there. |
| Dark mode, right-to-left, Dynamic Type | PASS (not run here) | Design rules and golden tests cover them; goldens are produced in CI. |
| Other platforms mentioned | PASS (FIXED review-risks 11) | No store text mentions Android. The phones list called a parent's own non-iPhone device "Android"; it now says "Other phone" (`deviceAndroid`, Arabic and English). |
| Beta/test wording in prod | PASS | Demo data is named "Demo"; no "beta" strings in the parent app. |
| Support, marketing, privacy URLs | FIXED + NEEDS OWNER | `/support`, `/`, `/privacy` on the links site; owner deploys. |
| Screenshots | NEEDS OWNER | One set at 6.9" (1320 x 2868, or 1290 x 2796) is enough; 6.5" (1284 x 2778 or 1242 x 2688) only if no 6.9" set. No iPad set (iPhone only). List in the kit. |
| Store text in Arabic and English | FIXED (text) + NEEDS OWNER | Ready to paste in the kit. |
| Age rating | NEEDS OWNER | Answers in the kit (new questionnaire: in-app controls, capabilities, medical, violence). |
| App name unique, 30 characters | NEEDS OWNER | App Store Connect tells you when you create the record. |

## 9. Technical (2.5)

| Item | Status | Evidence and change |
| --- | --- | --- |
| Xcode / SDK requirement | FIXED | Apple: uploads must be built with Xcode 26 or later (iOS 26 SDK), since 28 Apr 2026. `codemagic.yaml` used `xcode: latest`; now `xcode: 26.4` in all workflows (`codemagic.yaml:50`). |
| **UIScene life cycle** (launch crash) | FIXED (review-risks 8) | The Runner now uses UIScene as in Flutter's "UIScene adoption" guide: plugins registered in `didInitializeImplicitFlutterEngine`, `FlutterSceneDelegate` (or the template's subclass) in the scene manifest (`tool/patch_native.py`). Possible because nothing needs a background relaunch any more (no Always). `tool/check_ios_app.py` fails any build without the manifest. Xcode stays pinned at 26.4 (`codemagic.yaml`) until one staging build on Xcode 27 is tested. `tool/ios/configure_xcode.rb` is idempotent and safe with synchronized folders. |
| Private APIs, downloaded code | PASS | Flutter and published plugins only; no code push. |
| ATS | FIXED | No ATS exception outside dev (`review_info`); all endpoints are HTTPS. |
| IPv6-only networks | PASS (not tested) | Host names only, system networking. |
| Push used properly (4.5.4) | PASS | Trip, schedule, chat and safety alerts only; no marketing. No sensitive text in pushes (PRIVACY rules). |
| Export compliance | PASS | `ITSAppUsesNonExemptEncryption = false` (`tool/patch_native.py:286`); only HTTPS/TLS and standard hashing. |
| Minimum iOS | PASS | iOS 15.0. |
| Prod build workflow | FIXED | There was no prod workflow. `ios-prod` (manual, uploads without submitting) with release checks, `codemagic.yaml:115`. |

## 10. Tracking (5.1.2)

| Item | Status | Evidence and change |
| --- | --- | --- |
| No App Tracking Transparency needed | PASS | No ads, no IDFA; Analytics ad ID, IDFV and ad signals off in Info.plist (`tool/patch_native.py:312`); Sentry `sendDefaultPii = false`, no replay or screenshots (`lib/observability/sentry_setup.dart:27`). No `NSUserTrackingUsageDescription`. |
| Sharing with third parties disclosed | FIXED | Listed on the public privacy page and in docs/app-store-privacy.md. |

## 11. Safety (1.4, 5.1.5)

| Item | Status | Evidence and change |
| --- | --- | --- |
| Emergency button does not replace emergency services | FIXED | The confirmation now says it does not call the police or an ambulance and gives 122 / 123 (`app_en.arb:1378`); "Call ambulance 123" was already on the alert (`:1318`). Also in the terms. 5.1.5: location must not be used "to provide emergency services". |
| Use while driving | PASS | Driver screen: large buttons, no typing. |
| Support contact in the app | FIXED | About > Contact support. |

## 12. Legal (5)

| Item | Status | Evidence and change |
| --- | --- | --- |
| Terms of use, privacy policy, code of conduct pages | FIXED + NEEDS OWNER | `hosting/links/{privacy,terms,support,delete-account,home}.html`, built for staging and prod by `tool/links_site.py` (`--support-email`, `--operator-name`, `--require-legal`), served at clean URLs (`firebase.json:63`). Example addresses are refused. The lawyer must approve the wording (the in-app texts are short summaries of the same points). |
| Egypt PDPL points | PASS (text) + NEEDS OWNER | Consent, purposes, processors, transfer abroad (Belgium), retention, rights, complaint to the Personal Data Protection Centre, breach notice. The licence/DPO question is open item B5. |
| Data-source credits | RISK (low) | OpenStreetMap credit is in About; Overture and ADM2 credits are still open (open items D24, D33): a licence condition, not an App Review check. |

## 13. Things that would make the reviewer's session fail

| Item | Status | Evidence and change |
| --- | --- | --- |
| Prod Firebase project and options | NEEDS OWNER | Placeholder file; build refused until replaced. |
| App Check on the reviewer's phone | PASS + NEEDS OWNER | Release builds use App Attest with DeviceCheck fallback (`lib/firebase/firebase_setup.dart:68`); works on Apple's real devices once the prod app is registered for App Attest in Firebase and the App ID has the capability. |
| WhatsApp sender live | NEEDS OWNER | Not needed for the reviewer (demo numbers get no message), needed for every real parent. |
| ID check provider in prod | NEEDS OWNER | The fake KYC is refused in prod; real parents' verification needs `KYC_PROVIDER=valify` (contract) before the public launch. The demo accounts are verified by the script. |
| Maps key | NEEDS OWNER | `MAPS_API_KEY_IOS` in `prod_defines`; the prod build refuses to start without it. |
| School search (Algolia), chat (Stream), Sentry on prod | NEEDS OWNER | Keys and `chat:setup` on the prod apps. |
| Feature switch defaults | PASS | Missing document reads as pilot defaults (wallet off, Settle up on). |
| Verification wall | FIXED | The demo accounts are verified by the seed; see section 1. |
| A run to start on review day | FIXED (review-risks 7) | `review-access -- on` with both demo numbers seeds the demo data and lists it; the scheduled function `reviewDemoDaily` (18:30 Cairo) plans this week and the next and confirms the demo driver's runs while the access is on (demo carpool only, at most 2 plans and 20 confirmations). Friday and Saturday have no school run: the notes say so. |

## 14. What code cannot make zero-risk

| Item | Status | Why, and who acts |
| --- | --- | --- |
| Reviewer judgement | RISK (cannot be removed) | App Review is done by people on a real device; they may ask for the run video, a demo call, wording changes or something no guideline lists. A rejection is answered in App Store Connect (section H of the kit) and fixed; it is not final. |
| Individual vs Organization account (5.1.1(ix)) | NEEDS OWNER | The app requires national IDs and face images, so Apple expects a legal entity, not an individual developer. Convert to an Organization account (D-U-N-S number) before submitting (kit step 1, open item A18). |
| Lawyer confirmation | NEEDS OWNER | The deletion rule and the short list of records kept (open item B13) and the public pages (A13). |
| Crashes on Apple's devices | NEEDS OWNER | Run docs/test-iphone.md on the prod build with the demo accounts; the UIScene launch, push taps and universal links are first exercised by the next staging build. |

## Sources (read 16 Nov 2026)

- App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- Account deletion: https://developer.apple.com/support/offering-account-deletion-in-your-app
- Third-party SDK requirements (privacy manifests): https://developer.apple.com/support/third-party-SDK-requirements
- Minimum SDK (Xcode 26): https://developer.apple.com/news/upcoming-requirements/?id=04282026a
- Age ratings update: https://developer.apple.com/news/?id=ks775ehf
- Screenshot sizes: https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications
- Codemagic Xcode images: https://docs.codemagic.io/specs-macos/xcode-26-4
- UIScene requirement with the iOS 27 SDK (Apple forum and a third-party write-up; the April 2027 date is from the write-up, not confirmed on Apple's page): https://developer.apple.com/forums/thread/840957 , https://ecorpit.com/flutter-ios-27-launch-crash-uiscene-app-store-rejection/
- Required-reason API codes (as listed by Microsoft's summary of Apple's list; Apple's own page could not be opened from this workspace): https://learn.microsoft.com/dotnet/maui/ios/privacy-manifest
