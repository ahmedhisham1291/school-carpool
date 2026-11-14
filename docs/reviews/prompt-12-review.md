# Review: Prompt 12 (privacy and security hardening)

Branch `prompt-12-hardening`, head `749d3b4`. Scope: `git diff prompt-11-trust...HEAD`
(124 files). Checked against CLAUDE.md, docs/DECISIONS.md ("Data retention and
collection", "Owner updates": lawyer confirmed everything, PITR on in prod),
docs/DESIGN.md, docs/WORKFLOW.md, docs/spec.md sections 7 and 11,
docs/build-prompts.md "Prompt 12", docs/progress/prompt-12.md, SECURITY.md and the
four items Prompt 11's review handed on.

## Verdict: CHANGES NEEDED

The work is broad and mostly careful: a single retention table, a deletion
cascade that records every step and retries it, a test that checks the cascade
against `firestore.rules`, the analytics filter, the Sentry tests and a solid
incident plan. Three problems block it. The new-phone gate is mostly enforced
in the app, not on the server. Deleting an account can leave money arriving
in a closed wallet. A deleted parent's children's names stay in other
parents' records with no end date.

## CI

Manual run 43586002000 on `749d3b4`: **completed, success**.

| Job | Result |
| --- | --- |
| Flutter analyze, tests and screenshots | success. `No issues found!`; `+693 ~344: All tests passed!` The 344 skipped tests are the screenshot goldens, which do not run when `full=false`. |
| Cloud Functions tests and rules tests (emulators) | success. Functions `# tests 602 # pass 602 # fail 0`; `# tests 6 / pass 6`; rules `# tests 491 # pass 491 # fail 0` |
| Web, admin panel and Android compile (staging) | skipped by design (manual run, `full=false`) |

## Blocking

1. **The new-phone gate is enforced on the server only for `children`, chat tokens and the wallet.**
   Spec section 7 and Prompt 12 say: "ask for a fresh selfie before chats, the wallet and child data open".
   - `firestore.rules`: `deviceChecked()` is applied only to `children` (rules
     line 110). A new phone whose check is still open can read all of these:
     - `carpools/{id}/members` (children's names and grades), lines 258-261
     - `requests` and `pickupPoints` (exact pickup points), lines 265-286
     - `schedule` (riders), lines 294-297
     - `trips` and `trips/{id}/points` (the live location of children on a run), lines 334-345
     - `handoverAdults` (names and phone numbers), lines 369-372

     The profile redirect lives only in the app (`lib/router/session_redirect.dart`).
   - `functions/src/privacy/callables.ts:311` `exportMyData` and `:347`
     `deleteMyAccount` never call `requireNoDeviceCheck`. A SIM-swapped
     number on a new phone can download children, handover phone numbers,
     every chat message and the wallet history in one JSON file, or delete
     the account. That gets around all three gates.
   - SECURITY.md AUTH-2 says the data stays closed "(server, rules and app)".
     As things stand, that is not true.
   - Fix:
     - Put `deviceChecked()` on every rule that exposes child data or exact
       places: members, requests, pickupPoints, schedule, swaps, trips and
       points, eta, emergencies, handoverAdults.
     - Call `requireNoDeviceCheck` in `exportMyData`, `deleteMyAccount` and
       every trips, trust or carpool callable that returns children
       (handover, family links, today's cards).
     - Add rules tests for each path.
     - Correct SECURITY.md.

2. **Account deletion does not refuse incoming money, and closes the wallet late.**
   - `functions/src/privacy/firestore_store.ts:289` checks
     `walletPending where uid == <parent>`. A pending record carries only the
     sender's uid (`functions/src/wallet/firestore_store.ts:309-315`), so a
     transfer TO the parent that is still pending is not seen. The partner
     can settle it after the wallet is marked closed.
   - The wallet is closed in the 6th flow step
     (`account_deletion.ts:157`, after trips, carpools, chat, trust and
     identity). A transfer sent in that window passes `requireOpenWallet` and
     can reach the partner.
   - CLAUDE.md MONEY ("never skip"): the parent's money could be stranded in
     a closed wallet with no account to withdraw it.
   - Fix:
     - Freeze or close the wallet FIRST: one transaction that sets the status,
       then re-read the balance.
     - Refuse while any `transfers` record with the parent in `parties` has
       no `transferResults`, or store `toUid` in `walletPending` and query both
       sides.
     - Add a test for an incoming pending transfer.

3. **A deleted parent's personal and children's data stays in other records with no end date, and nothing deletes it.**
   - Other drivers' `trips/{id}.stops` keep the deleted parent's child
     `firstName`, `parentUid` and handover adults' names. The purge removes
     only trips the parent DROVE (`account_deletion.ts:106`).
   - Past `carpools/{id}/schedule` runs keep `riders`/`absent` (child first
     names) and `driverFirstName` for ever (`account_deletion.ts:137`). A
     closed carpool and its subcollections are never deleted
     (`account_deletion.ts:135`). Its `creatorFirstName` stays too.
   - `walletDaily/{uid}_{day}` is said to "expire by TTL"
     (`account_deletion.ts:123`), but it has no expiry field
     (`wallet/firestore_store.ts:316`) and no TTL in `tool/setup_retention.sh`.
   - Prompt 12 says "retention job for every data type in section 7". The
     "Done when" says only the ban-list hash and transfer records remain, or,
     after DECISIONS.md, those plus the photos and summaries for 1 year.
   - Fix:
     - At deletion, scrub the parent's stops in `trips where viewerUids
       array-contains uid` and their entries in past schedule runs: replace
       the first name and handover with a neutral marker and keep the counts.
       Or purge them with the 1-year step.
     - Add a retention task that deletes closed carpools and their
       subcollections after 1 year.
     - Add `expiresAt` to walletDaily and add it to the TTL script.
     - Extend the cascade test to subcollections.

## Non-blocking

1. **The new-phone selfie check is a formality in prod.**
   - `privacy/callables.ts:122-130` hard-codes `valify: { enabled: false }`.
     With `KYC_PROVIDER=valify` (`.env.prod`), `matchFace` always answers
     "error", so any selfie passes with only a non-urgent report. This is
     decision 3; record it as such in SECURITY.md.
   - `deviceDeps()` builds the KYC provider eagerly. `afterSignIn`
     (`:165-171`) swallows every error and returns `newDevice: false`, so a
     Firestore or KYC error turns the new-phone protections off without a
     sound.
   - Build the face matcher lazily. On failure, fail closed: set the check
     and revoke sessions.
2. **Signing out a phone is not immediate.** `revokeRefreshTokens` leaves the
   current ID token valid for up to 1 hour. Callables and rules do not check
   revocation. Say so in AUTH-2, or compare `auth_time` with a
   `sessionsValidAfter` field in the rules and callables.
3. **The export is missing some data.**
   - Not exported: `pickupPoints`, the parent's carpool join requests,
     `driverConsents`, `chatRequests` and `chatBlocks`, `guardianRequests`,
     the parent's own `privacyRequests` log, and vouches.
   - Chat photos appear only as `attachment: "image"`, with no copy.
   - The caps (500 docs, 5,000 messages) are not reported in `missing` when
     they are hit.
4. **Thumbnails.**
   - `callables.ts:483` skips a thumbnail that already exists. A replaced
     `faceRefs/{uid}/selfie.jpg` or `driverPhotos/{uid}/photo.jpg` keeps its
     stale thumbnail, because the path hash is the same.
   - `:530` serves the FULL image when no thumbnail exists (every photo from
     before Prompt 12), but audits it as `photos.view`, not `photos.view.full`.
   - Thumbnails of withdrawn cases stay until the account purge.
   - Add a backfill, overwrite on a new generation, and fix the audit action.
5. **`tool/setup_kms.sh:30`** uses GNU `date -d` and fails on macOS (the
   owner's Mac). SETUP 23.2 step 4 leaves `selfieArchive/**` and
   `thumbs/**` out of the rewrite. The rest of the script is correct:
   `service-agent --authorize-cmek`, `--default-encryption-key`, and the key
   in the same region.
6. **Lawyer and retention text is stale.**
   - DECISIONS "Owner updates" says the lawyer confirmed every period,
     including transfer records. Several places still say a lawyer check is
     pending:
     - `retention.ts:8,122,133`
     - `account_deletion.ts:19`
     - progress question 2
     - the deferred-items table (Prompt 11B #5, Prompt 10 #8b/#8c)
   - Record the confirmed transfer-record period and set `days` for it. At
     the moment it is `null`, so the records are kept for ever.
7. **App Store answers**
   (`docs/privacy/app-store-privacy.md`):
   - Device ID should also list the Analytics purpose (app instance ID).
   - Add Coarse Location (IP-based, Analytics).
   - The Phone Number row is missing the handover adults' numbers.
8. **SECURITY.md part 2** leaves out Apple Push Notification service, which
   receives the push texts through FCM.
9. **Closed carpools whose chat never ends.** `endClosedCarpoolChats`
   (`firestore_store.ts:450`) looks back only 3 days. If the job fails 3
   days in a row, those chats never end. Query for closed carpools whose chat
   has no `endedAt` instead.
10. **Scraping counters store raw keys.** They keep raw uids, parent IDs and
    school IDs, while the comments say "keyed" and "never stored as given"
    (`abuse.ts:7-8`, `wallet/callables.ts:117`). The risk is low (2-day TTL),
    but correct the comments or hash the keys.
11. **`archiveRouteOnTripWrite` runs too often.** It fires on every `trips`
    write, which means every location batch, at 512 MiB. Keep an eye on the
    free invocation quota, or trigger it from `tripTick` or the event that
    ends the run.
12. **Mail outbox.** `mail/{id}` keeps the email address for 30 days after an
    account is deleted. The Trigger Email extension does not delete sent
    mail by default, so `account_deletion.ts:153` is inaccurate.
13. **Restore test.** Add a step that re-applies `closedAccounts` deletions
    after any restore from a backup or PITR. Otherwise deleted accounts
    come back.
14. **Offline queue across accounts.** The offline confirmation queue is not
    cleared on sign-out, so another account on the same phone flushes it. The
    server refuses those calls, but clear the queue anyway.
15. **App lock re-prompt.** When the app switcher cover turns into the lock,
    the same `AppLockScreen` element stays, so Face ID is not prompted again
    on its own. Key the widget on `locked`.
16. **Android analytics.** Android has no
    `firebase_analytics_collection_enabled=false` manifest flag yet. Add it in
    Stage 3.
17. **Screenshots.** The screenshots of the 4 new screens were not produced
    (`full=false`). Run the full workflow at merge.

## Checked and fine

- **Export ownership.** The export uses only `request.auth.uid` and cannot be
  asked for someone else. It has a 3-a-day limit, a 1-hour signed link and
  is deleted after 1 day.
- **Deletion cascade.**
  - It refuses when the wallet has money, when the parent has a pending
    outgoing transfer, or while they are driving.
  - The Stream user is cut off, then hard-deleted after 1 year.
  - FCM tokens, homes, maps records, devices and other records are deleted
    at once.
  - The ban list, open reports, transfers and the audit log are kept.
  - Each step is retried and reported.
- **Consent withdrawal.**
  - Analytics, map and WhatsApp switch off.
  - The wallet terms close only an empty wallet.
  - The legal consents are refused with the reason, and every change is
    logged.
- **`retentionDaily`.**
  - It runs at 03:10 Africa/Cairo with pages of 200 items.
  - Each task runs in isolation and the job is idempotent.
  - minInstances is 0.
  - It writes a report and raises a Sentry error and a security alert when
    something fails.
- **Lifecycle JSON and TTL script.** Valid; PITR is switched on with `--prod`.
- **Route archive.** Down-sampling and the polyline encoding are correct.
  The file is written as Coldline. Opening it is admin-only, needs a reason
  and is logged first.
- **Admin photo access.** A fixed reason code, an audit entry before the
  access, and 5-minute links.
- **sharp in Functions.** 1 GiB, 60 s, loaded with a dynamic import.
- **Photos on the phone.** The long-edge sizing is correct.
- **Analytics.**
  - Only fixed events and keys.
  - Each value has to be a short word, a bool or a small number.
  - Screen names come from route patterns.
  - On iOS, collection is off in Info.plist until the saved choice is read.
- **Sentry tests.** They are real: phone numbers, national IDs, coordinates,
  message text, frame variables and the device name are all covered. The
  area tags support the alert rules.
- **SECURITY.md.** The MASVS open items are honest apart from AUTH-2 (see
  blocking item 1). The 72-hour PDPC plan is complete.
- **ARB files.** 1951 keys in each, no gaps, and the old "deleted in 7 days"
  texts are gone.
- **One line.** The one-line tests pass at 320 dp and 200 percent.
- **Prompt 11 items 1 to 4.** All fixed: the `childInCarpool` message, the
  grade copied to linked parents, the overdue mark cleared, one rating per
  trip in the transaction.
- **Deferred table spot-check.** These "fixed" claims are correct:
  - Prompt 9 #3 (nightly truncation removed)
  - Prompt 8 #11 (notification records deleted)
  - Prompt 2 #5 (limited-use App Check token, consumed)
  - Prompt 11 #2 (grade reaches linked parents' carpools)
  - Prompt 11B new #1 (`stuck` added to `ALERT_KINDS`)

  Prompt 10 #12 ("trip docs never expire: fixed") is only partly true; see
  blocking item 3.
- **Done when.** Export, second device, Face ID lock and passing rules tests
  are all covered. "Only the hash and transfer records remain" is not met
  until blocking item 3 is fixed (plus the 1-year photo hold the owner chose).
