# Prompt 12: Privacy and security hardening

Branch `prompt-12-hardening` (from the Prompt 11 trust branch, with
`prompt-11-trust`'s review merged). The owner said "go" through the
coordinator; plan, decisions and questions are recorded here.

Done as written in docs/build-prompts.md "Prompt 12", plus the owner's
data-retention decision (DECISIONS.md, 14 Nov 2026), plus every item
deferred "to Prompt 12" in the progress notes and reviews (table at the
end), plus the Prompt 11 review's non-blocking items 1 to 4 and 9.

## What was built

### Server (functions/src/privacy/, new)

- `retention.ts`: one retention rule per data type (22 types, `DATA_TYPES`,
  same ids and order as the app's privacy screen), the owner's periods as
  constants (photos, trip summaries, consents: account open + 1 year; route
  archives 1 year after the run; chat: life of the chat + 1 year; live
  points within 24 h; privacy requests 3 years; audit log 2 years), and
  what is kept after deletion (`KEPT_AFTER_DELETION`).
- `account_deletion.ts`: `deleteMyAccount`. Refused with money in the
  wallet, a pending transfer, or a run being driven. At once: live runs stop,
  the parent leaves every carpool (`removeFromCarpool`: an admin hands the
  carpool to the longest-standing member; the last one out closes it; future
  runs released), the Stream user is cut off and private chats end, linked
  parents' carpools lose the child, vouches are removed from others'
  summaries, the national-ID claim is released (the ban list stays), the
  wallet is closed (not deleted), then 44 record targets (homes, map
  records, memberships, notification records, chat records, trust records,
  children, car, devices, sign-ins, live uploads ...), the user record and
  the Auth user. 1 year later `retentionDaily` purges photos (cases, face
  reference, driver photo, selfie archive, thumbnails), verification
  records, the run summaries the parent drove and their route archives,
  consents, and the Stream user with its messages. Kept: ban-list hash (if
  banned), open reports, transfer records, audit log, the reserved parent
  ID, `closedAccounts/{uid}` (dates and the deletion report only). Every
  step runs on its own; failures are stored and retried daily and reported.
  A test parses `firestore.rules` and fails if any collection is neither
  deleted, purged nor kept with a stated reason.
- `export.ts`: `exportMyData`, one JSON with a section per data type,
  including the parent's own Stream messages (`ChatServer.userMessages`) and
  the wallet history (transfers and results). Internal keys and hashes are
  removed; received ratings show as a summary only; reports about the parent
  as a count. Written to `exports/{uid}/`, 1-hour signed link, deleted after
  a day; 3 a day.
- `requests.ts` and callables: `getPrivacyOverview` (consents and the
  parent's last 30 requests), `setConsent` (analytics, map visibility and
  WhatsApp switch on and off; the wallet terms close an empty wallet;
  terms, privacy, conduct, ID, face and child data say "delete the account"
  or "remove the children" and withdraw nothing half way),
  `requestCorrection` (email, children, home, car ... are edited on their
  screens; name and ID details open a request for an admin),
  `requestPhotoCopy`. Every request is logged in `privacyRequests` (3 years).
- `devices.ts`: every sign-in recorded (`users/{uid}/devices`, `logins`;
  keyed hash of the install ID, platform, times). A new phone (never used
  by this account, and the account was used before) signs the other phones
  out (sessions revoked), emails the parent (mail outbox, SETUP 23.4),
  pushes `new-device` (reaches the old phone) and, for a verified parent
  with a face reference, sets `newDeviceCheck`: chats (`getChatToken`), the
  wallet (all wallet callables) and child records (rules) stay closed until
  `confirmNewDevice` matches a fresh selfie. `touchDevice` (start and
  resume), `listDevices`, `signOutDevice` (one or all others; the asking
  phone gets a fresh custom token).
- `abuse.ts`: scraping alerts (opening profiles, chat requests, area
  searches, parent ID lookups; distinct targets per hour) on
  `getTrustSummary`, `sendChatRequest`, `searchNearbyParents`,
  `searchCarpools`, `lookupParentId`. Never blocks; one `securityAlerts`
  entry per account, kind and hour.
- `jobs.ts`: `retentionDaily` (replaces `purgeVerificationImagesDaily` and
  `chatRetentionDaily`): closed accounts (retries and purges), route
  archives, chats of closed carpools frozen and ended, ended chats deleted
  on Stream after 1 year, handled reports' message copies cleared after 1
  year, trip stops, audit log, exports, handled security alerts; the
  pending-upload purge. Report in `retentionRuns/{date}`; failures to Sentry
  and a "retentionFailed" security alert.
- `route_archive.ts` and `archiveRouteOnTripWrite`: when tracking stops,
  the live points become one gzipped track (about 1 point per 30 s, Google
  encoded polyline, seconds since start) in `routeArchive/{year}/{trip}.json.gz`
  written as COLDLINE, record in `routeArchives/{tripId}`, purged after a
  year. `adminOpenRouteArchive` needs a reason and logs first.
- `photos.ts`: access reason codes, `thumbs/{uid}/{hash}.webp` paths,
  selfie archive paths. `makePhotoThumbnail` (Storage trigger, sharp): 320 px
  WebP of every kept photo. `adminOpenUserPhotos` (reason, logged first,
  thumbnails unless `full`). `openVerificationCase` now needs a reason for a
  decided case ("review" is implied for the queue) and returns thumbnail
  links.
- Admin: `adminListSecurityAlerts`, `adminResolveSecurityAlert`,
  `adminListPrivacyRequests`, `adminClosePrivacyRequest` (all logged).

### Server changes elsewhere

- Verification (owner decision): decided cases keep their images (no purge
  date); an old purge date from before is cleared, not acted on; withdrawn
  cases are still deleted. Trip selfie checks and phone-change selfies are
  copied to `selfieArchive/{uid}/` before the upload folder is emptied.
- Chat: `ChatServer.deleteChannel`, `deleteUser`, `userMessages`;
  `ChannelRecord.endedAtMs`; the nightly truncation is gone.
- Sign-in: App Check replay protection on `requestCode`
  (`consumeAppCheckToken`, limited-use token in the app); a device where the
  number signed in before is never closed by the daily cap
  (`knownDeviceDays` 90); `OTP_MAX_FAILURES_PER_DAY` param; `verifyCode`
  records the sign-in; `acceptConsents` checks the email step on the server
  and records nothing twice.
- Wallet: "stuck" alerts keep their kind (`ALERT_KINDS`), outcome
  `settledWithPartner`, `settleStuckTransfer` and
  `scripts/settle_stuck.ts` (SETUP 21.6).
- Trust (Prompt 11 review): grade changes reach linked parents' carpools
  (item 2); the overdue mark is cleared when nothing is left to confirm
  (item 3); one rating per trip and pair (item 4).
- Sentry: mechanism data, frame variables, device names and custom
  contexts scrubbed; `function` and `area` tags for alert rules.
- Consent versions: privacy policy and ID/face/child consents to
  `2026-11-14` (the texts now describe the kept photos, the route archive,
  analytics and chat history).
- Notification kind `new-device` (same position in app and server lists).
- Rules: child records closed while `newDeviceCheck` is set; storage path
  `deviceChecks/{uid}/selfie.jpg` (verified owner, JPEG, < 3 MB); every new
  collection and path stays closed (deny by default). Emulator tests:
  `tests/rules/privacy.test.ts`. Indexes for the new queries.

### App

- Profile > **Privacy** (`/profile/privacy`): download my data, every data
  type with what it holds, who sees it and how long it is kept (sheet),
  consents (switches for statistics, map and WhatsApp; withdraw for the
  others), correct (links to the edit screens; ID details as a request),
  copy of photos, phones and sign-ins, your requests, delete account.
- **Phones and sign-ins** (`/profile/privacy/devices`): this phone, others
  with Sign out, Sign out others, recent sign-ins (a new phone marked).
- **Delete account** (`/profile/privacy/delete`): two steps (what is
  deleted now, kept 1 year, kept after), "I understand", a confirm dialog,
  Face ID, then the server; wallet refusals link to the wallet.
- **New phone** (`/profile/privacy/new-device`): fresh selfie; a banner on
  Profile; chats, wallet, children, handover, family links and carpool pages
  redirect there while the check is open.
- **App lock** (Settings): Face ID, fingerprint or passcode; opens locked;
  covered in the app switcher; locked again after 30 s away.
- **Usage statistics** (Settings and the privacy screen): firebase_analytics,
  on by default, no user ID, no ad IDs (Info.plist keys); route-pattern
  screen tracking; a filter that drops any parameter value that could be
  personal. Catalog: docs/analytics-events.md.
- Device guard: a phone signed out elsewhere signs itself out at start or
  resume.
- Offline: run confirmations made offline wait on the phone (IDs only) and
  are sent once when back online; today's schedule and the pickup list come
  from Firestore's offline cache.
- Photos: long edge at most 1600 (the short side is computed from the real
  size), JPEG about 80 for verification and selfie checks, WebP for chat
  photos on the phone.
- `child-in-carpool` has its own message (Prompt 11 review item 1).
- Admin panel: "Outcome unknown" label for stuck wallet alerts.

### Docs

SECURITY.md (MASVS checklist with done/open, outside services and the data
each receives, incident plan with the 72-hour PDPC report),
docs/analytics-events.md, docs/privacy/app-store-privacy.md,
docs/restore-test.md, SETUP.md 21.6 and 23, COSTS.md "Privacy and security
(Prompt 12)", tools: `tool/setup_kms.sh`, `tool/setup_retention.sh`,
`tool/storage_lifecycle.json`.

## New dependencies (CLAUDE.md "tell me why")

- **firebase_analytics ^13.0.0** (app): the owner asked for usage analytics
  with Firebase; part of Firebase (free), FlutterFire BoM 5.1 line.
- **sharp ^0.34.3** (functions): server-side thumbnails for the admin panel
  (the owner asked for server-made thumbnails). The standard Node image
  library, prebuilt for Cloud Functions' Linux.
- **Trigger Email from Firestore** (Firebase extension, not installed):
  needed only to actually send the new-phone email; the code writes the
  outbox. Owner to approve and pick an SMTP provider (SETUP 23.4).

## Decisions taken here (tell me if any is wrong)

1. Photos are kept 1 year after closure even when the parent deletes the
   account (owner decision is newer than the prompt's "only the ban-list
   hash and transfer records remain"); the privacy screen and the delete
   screen say so.
2. Withdrawn verification cases are still deleted by the job (the parent
   took them back); decided ones (approved and rejected) are kept.
3. A new-phone selfie the face check cannot decide (Valify stub, no
   contract) lets the parent in and files a non-urgent report for an admin
   to compare the kept selfie by hand; a clear mismatch keeps everything
   closed and files an urgent report.
4. Firebase can only end every session of an account at once: signing out
   one phone signs out all others too, and the asking phone signs in again
   with a fresh token at once (the screen says other phones need a new
   code).
5. Unverified parents on a new phone get no selfie step (no face reference
   yet); they are still signed out elsewhere and emailed.
6. Chat photos are WebP; verification photos stay JPEG (the ID check, the
   face match and storage.rules take JPEG).
7. Group-chat messages of a deleted parent stay in those chats until the
   purge (1 year), with the Stream user deactivated; then the user and its
   messages are hard-deleted.

## Questions for the owner

1. **PITR:** decided by the owner (14 Nov 2026): ON in prod, daily
   backups kept (SETUP 23.7, `tool/setup_retention.sh <prod-id> --prod`,
   COSTS). The coordinator updates the CLAUDE.md cost line.
2. **Lawyer** (DECISIONS.md requires a check for longer retention and new
   data): the new periods (photos and run summaries 1 year after closure,
   route archives 1 year, chat life + 1 year), usage analytics, the selfie
   archive, **ratings and vouches, guardian links** (Prompt 11 review item
   9), the emergency contact who never opted in, the driver's live-location
   consent (not yet a consent record), and **how long transfer records stay
   after deletion** (kept for now).
3. **Email provider** for the new-phone email (Trigger Email extension).
4. Existing parents accepted the 2026-11-13 privacy policy. Ask them to
   accept the new version (a one-time screen), or rely on the notice?

## Tests

- Functions: **run here, 602 pass** (`node --test lib/test/*.test.js` with
  the workspace's type stubs; `npm` registry not available, so `tsc`
  reports only the known stub noise; the one real type the stubs lack is
  `sharp`, which ships its own types). New: `privacy.test.ts` (28 tests:
  retention dates, route archive encoding and down-sampling, scraping
  counts, devices and the new-phone rule, the deletion cascade against
  firestore.rules, export contents and redaction, consents, the retention
  job report, photo paths), and additions to otp_flow, trust, wallet,
  verification_flow, trips, chat and scrub tests (Sentry: no phone, ID,
  coordinate or message text gets through).
- Rules: `tests/rules/privacy.test.ts`, **written, not run here** (no
  emulators); CI runs it.
- Flutter: `test/privacy/privacy_logic_test.dart` (analytics never
  receives PII, screen names, app lock, offline queue, photo sizing,
  new-phone gate, models, Sentry areas), `test/privacy/privacy_screens_test.dart`
  (privacy, phones, delete, new phone; one line at 320 dp and 200 percent in
  Arabic and English), Sentry scrubber test additions, screenshots of the 4
  new screens in Arabic and English, light and dark. **Written, not run
  here** (no Flutter SDK). `flutter analyze` not run here.

## iPhone test steps

SETUP.md 23.8 (export, a second phone listed and signed out, the new-phone
selfie, app lock with Face ID, deleting a test account and checking what
remains in the console).

## Deferred items ("to Prompt 12") and their state

| Source | Item | State |
| --- | --- | --- |
| Prompt 1 #11, review R4 | Dart scrubber: contexts and exception mechanism | Fixed (app and functions, with tests) |
| Prompt 1 R1 | Lockfiles | Still open: no package registry here; commit from CI |
| Prompt 2 #5, review N4 | App Check replay protection on `requestCode` | Fixed (limited-use token consumed) |
| Prompt 2 #7 | `acceptConsents` order on the server, repeated calls | Fixed |
| Prompt 2 review N1 | Device-ID rotation locks the parent out for a day; cap as a param | Fixed (known devices pass; `OTP_MAX_FAILURES_PER_DAY`) |
| Prompt 2 review N2 | Cold starts on blocking functions | Documented (COSTS: raise `minInstances` if sign-ins time out); no warm instance (COST MODE) |
| Prompt 2 review N3 | `confirmEmail` only after a recent email change | Still open (optional hardening, not in Prompt 12's list) |
| Prompt 2 not done | New-phone risk, active devices | Fixed |
| Prompt 2 not done | Audit log entry for a daily lock | Still open (low value; keyed hashes only, no uid at that point) |
| Prompt 2 not done | Withdrawing consents (privacy screen) | Fixed |
| Prompt 3 review N1 | Soft delete keeps deleted images 7 more days | Superseded: photos are kept now; 7-day soft delete kept on purpose (SETUP 23.3) |
| Prompt 5 #5 | Deleting `homes`, `mapLimits`, `newParentEvents` with the account | Fixed |
| Prompt 6 | Memberships, members, requests, consents, pickup points, `carpoolWanted` | Fixed (`removeFromCarpool` + targets) |
| Prompt 7 | Remove from future runs and balances | Future runs fixed (released); per-term balances keep the parent's counts (group statistics), deleted with the carpool. Still open if the lawyer wants them cleared |
| Prompt 8 #11 | `notificationSettings`, `pushTokens`, `notificationLimits`, `users/{uid}/notifications` | Fixed |
| Prompt 9 | Stream user and chat records on deletion | Fixed (cut off at once, private chats ended, user and messages hard-deleted after 1 year) |
| Prompt 9 review #3 | Retention job truncates every channel nightly | Fixed (removed; chats end and are deleted a year later) |
| Prompt 9 review #7 | Handled reports keep message copies forever | Fixed (cleared 1 year after handling) |
| Prompt 9 review #13 | A closed carpool keeps its chat | Fixed (frozen and ended by `retentionDaily`) |
| Prompt 9 review #2 | Chat does not open offline at a cold start | Still open (needs a cached Stream token; not in Prompt 12's list) |
| Prompt 9 | New-device selfie before chats open | Fixed |
| Prompt 10 | `handoverAdults`, `emergencyContacts`, `tripLimits`, driver photo | Fixed (driver photo kept while the account is open, purged 1 year after closure) |
| Prompt 10 review #12 | Trip docs never expire | Fixed (purged 1 year after the driver's account closes; `tripStops` within a day) |
| Prompt 10 follow-up 1 | KMS key for kept photos | Done as a setup script (code cannot create keys) |
| Prompt 10 follow-up 2 | Deletion 1 year after closure; on ban or rejection | Fixed for closure; on a ban or a later rejection photos stay while the account exists (owner decision; investigations) |
| Prompt 10 follow-up 3 | Admin access only with a logged reason | Fixed (case view, photos, routes) |
| Prompt 10 follow-up 4 | Live selfie checks: kept or deleted | Fixed: kept in the selfie archive (owner decision) |
| Prompt 10 review #8b, #8c | Emergency contact opt-in; driver location consent record | Still open (lawyer; question 2) |
| Prompt 11 review #1 | `child-in-carpool` generic error | Fixed |
| Prompt 11 review #2 | Grade change not copied to linked parent's carpools | Fixed |
| Prompt 11 review #3 | Overdue mark stuck | Fixed |
| Prompt 11 review #4 | Two ratings across a month boundary | Fixed |
| Prompt 11 review #9 | Ratings and links: privacy screen, export, deletion, lawyer | Fixed (lawyer: question 2); phone-change selfie kept (archive) |
| Prompt 11 | Ratings, summaries, flags, links, requests, `trustLimits` on deletion | Fixed (open flags stay like reports) |
| Prompt 11B #5 | Transfer records after deletion | Kept; lawyer to set the period (question 2) |
| Prompt 11B | App lock for the whole app; wallet export and deletion | Fixed |
| Prompt 11B review new #1 | Stuck alerts mislabeled | Fixed |
| Prompt 11B review new #2 | Nothing settles a stuck transfer | Fixed (script, SETUP 21.6) |
| Prompt 11B review new #3, #4 | Cancel reason after a freeze; lease not released | Still open (cosmetic, harmless) |

## Not done

- Admin panel screens for security alerts, privacy requests (ID-detail
  corrections, photo copies), user photos and route archives: the
  callables exist and are logged; the panel UI is the next admin pass.
- Feature events other than the privacy ones are in the analytics catalog
  but not yet sent from their screens (screens are tracked).
- The email extension (owner decision) and the outside penetration test
  (owner). PITR is switched on by the owner's setup step (SETUP 23.7).
- The driver's in-run queue of stop actions stays in memory (Prompt 10);
  only run confirmations are kept on the phone.
- Not verified here: `flutter analyze`, `flutter test`, the rules tests,
  the iOS build with firebase_analytics, the deploy with sharp.

## CI fixes (run 43585030380)

- `new_device_screen.dart`: missing import of `CaptureKind`
  (verification_models.dart).
- `analytics.dart`: the field is `_collecting` (no private named
  initializing formal; no prefer_initializing_formals).
- `privacy_logic_test.dart`: `const` on the outermost literal passed to
  `fromMap` (no nested const).
- PITR on in prod (owner decision): SETUP 23.7, COSTS, restore test,
  `tool/setup_retention.sh --prod`.
