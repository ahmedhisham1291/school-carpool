# Review: workstream A (pilot feature switches, Settle up by InstaPay, F45)

## Round 2 verdict: PASS

Re-review of `00e67d4` (commits `6b07cd0`, `72d6811`, `02142f7`,
`00e67d4`), 14 Nov 2026, by the same validator. Blocker B1 is closed and
the findings the builder took on are fixed correctly; nothing regressed in
what I re-checked. No blocker remains.

What was run here: the functions unit tests (759 pass, 0 fail, on this
head) and a temporary probe test of every address path (removed, not
committed). CI run 43637019273 (analyze, Flutter tests, functions, rules)
was reported green by the coordinator; Flutter and rules tests were not
run here.

### B1: closed

`getAddressFor` (`functions/src/settle_up/flow.ts`) now requires, in this
order: caller verified (claim and record), not suspended or banned; a
party; the payer; **the record was created by the payee**; status open;
nobody reported it; the payee still a party, verified, not suspended or
banned; no block either way; then the rate limit. `createdBy` is set only
by the server from `kind` (extra fields in the create input are ignored).
The record page shows the address block only for the same case and a
one-sentence "ask the parent" note otherwise.

Probe results (memory store, through the real flows):

| Path | Result |
| --- | --- |
| Payer-created record: paid; re-opened by "Not received"; re-opened twice; reported; declined | refused (`not-allowed`) in every state |
| Payee asks for an address on a payer-created record | refused |
| Payee-created request, payer, open | address (intended) |
| Same, re-opened after "Not received" | address (intended: the payee asked) |
| Same, paid, closed, cancelled, declined | refused (`invalid-state`) |
| Same, reported by either side | refused |
| Payee on their own request (payer's address) | refused |
| Other member of the carpool, stranger | `not-found` |
| No account, uid "deleted" | `no-account` |
| Payer without the verified claim, unverified, suspended, banned | refused |
| Payee suspended or banned | refused |
| Block in either direction | refused |
| Payee deleted the account | refused (record ended; address document deleted) |
| Forged `createdBy`, `payeeUid`, `payerUid` in the create input | ignored; roles follow `kind` |

Rules: collection-group reads of `settleUpAddresses`, `settleUpLimits` and
`settleUps` are now asserted as refused (N10).

### Other fixes checked

- **N1** eligibility and block checks on the address: done (above).
- **N2** atomic report: `update` writes the "reported" mark and the report
  document in one transaction (`store.ts`); a failed write leaves neither
  (tested with `failNextWrite`).
- **N3** `removeAddress` takes no limit any more.
- **N4** cap per pair: new field `pair` (the two uids sorted, joined by
  "|") on every record; `create` counts `pair == x && finished == false`
  inside the create transaction, so two requests at once cannot both pass.
  Index changed to `pair` + `finished`. A deleted parent reads as
  "deleted" in `pair`; those records are finished, so they never count.
  No stored records exist yet, so no backfill is needed.
- **N5** deletion loop: a damaged record is taken out of `parties`, and a
  50-page cap stops a loop without progress.
- **N6** documented, one seam (`blockedEitherWay`, `chatBlockDocId`) and a
  unit test on the ID format. Still a dependency for the own-chat branch.
- **N8** fail closed: after 3 failed reads in a row (about 60 to 90
  seconds) an instance drops its last known copy for the pilot defaults;
  a good read or an admin change resets the count.
- **N9** the switch and its audit entry are one batch.
- **N11** withdrawing the wallet consent with the wallet off uses our
  balance copy and never calls the partner; an unknown copy refuses.

### Remaining notes (none blocking)

- **R1.** `createSettleUp` takes the daily "requests" limit before the
  per-pair cap answers "too-many-open", so a refused request still costs
  one of the 20. Harmless.
- **R2.** With the wallet off and no stored balance copy, withdrawing the
  wallet consent answers "wallet-not-empty"; the wording is off for that
  rare case (only a wallet opened before the switch-off).
- **R3.** On a fresh project the two `settleUps` indexes need a few
  minutes to build after deploy; until then the list and
  `createSettleUp` fail with an index error.
- **N7, N12** unchanged (retention period to confirm and publish, B7; the
  switch is checked before the admin check).
- CLAUDE.md and AGENTS.md now say F1 to F45.

The "not verifiable without a real iPhone" list of the first review still
applies, plus: the "ask the parent" note on a payment I recorded myself
(Arabic, 320 dp, 200 percent text).

---

# First review (round 1, `bb2b571`)

Branch `improve-a-feature-switches` at `bb2b571` (main merged in), reviewed
14 Nov 2026 by the independent validator against CLAUDE.md,
docs/DECISIONS.md ("Improvements, revised", "Owner update 17:28") and
docs/progress/improve-a.md.

## Verdict: FAIL (1 blocker)

One privacy blocker in Settle up: a parent can obtain another carpool
member's InstaPay address without that member ever asking them for money.
Everything else reviewed is sound; the fix is small (one condition and one
test). The feature switches part has no blocker.

What was run here: the functions unit tests (748 pass, 0 fail, on this
head) and a temporary probe test for blocker 1 (removed afterwards, not
committed). CI run 43634448906 (analyze, Flutter tests, functions tests,
rules tests) was reported green by the coordinator; I did not re-run it.
Flutter and rules tests were not run here (no SDK, no emulator).

## Blocker

**B1. A payer can read a payee's InstaPay address through a record the
payer made themselves.**
`functions/src/settle_up/flow.ts:281-292` (`getAddressFor`), with
`functions/src/settle_up/model.ts` `TRANSITIONS.notReceived` (paid -> open).

- Steps: Bob calls `createSettleUp` with `kind: "paid"`, `otherUid: alice`
  (any verified member of a shared carpool; Alice never asked for
  anything). The record starts as `paid`. Alice sees a payment she never
  got and taps "Not received", the honest answer. The record is now
  `open`, Bob is its payer, and `getSettleUpAddress` returns Alice's
  address.
- Proven with a probe test over `MemorySettleStore`: the call returned
  `{"address":"alice.test@instapay"}`.
- Why it matters: the stated rule (spec F45, rules comment, privacy docs)
  is "only to the payer of an OPEN request from that payee". Here the payee
  made no request. The existing test
  `functions/test/settle_up.test.ts:225` ("a payer cannot use a record
  they made themselves to read an address") checks only the first state
  (`paid`), not the state after "Not received". The confirmation text for
  "Not received" does not tell the payee that the address becomes visible.
- Fix: in `getAddressFor`, reveal the address only when the payee asked:
  add `if (r.createdBy !== "payee") throw new SettleError("not-allowed")`
  (or return `{ address: null }`) before the rate limit. Extend the test at
  line 225 with the "Not received" step. On the record page, hide the
  address block for a payer-created record (the payer already paid outside
  the app, so they have the address). Docs wording already matches the
  fixed behaviour.

## Ways another parent could try to get an address

| Attempt | Result |
| --- | --- |
| Read `settleUpAddresses/{uid}` from the app (get, list, collection group) | Blocked: rules deny all; no recursive rule opens it (`firestore.rules` catch-all is deny). Rules tests cover get, list, write; no explicit collection-group test (see N10) |
| Create a request as payee and read the payer's address | Blocked: only the payer role may call, and it returns the payee's address |
| Record "I paid" (payer-created), then read | Blocked while `paid`; **open after the payee taps "Not received": B1** |
| Read after "I paid", Received, cancel or decline | Blocked (`invalid-state`) |
| Read someone else's record by ID | Blocked (`not-found`, same answer as a missing record) |
| After the payee removed the address or deleted the account | `null`; the document is deleted at once on account deletion |
| Via push text, contacts list, admin view, audit log, errors, export of another parent | Not present (checked in code and in the test at `settle_up.test.ts:243`) |
| Via logs, Sentry, analytics | Request data is never logged; both scrubbers remove `name@instapay`; analytics events carry a step name only |
| Payer suspended, banned or blocked AFTER the request was made | Still allowed while the request is open (see N1) |
| Bulk collection | Limited to 30 views per hour per parent |

## Non-blocking findings

Settle up

- **N1.** `getAddressFor` (`flow.ts:284`) uses `requireAccount`, so a payer
  who was suspended, banned, or blocked by the payee after the request was
  made can still read the address while it is open. Suggest
  `requireEligible` plus the `blockedEitherWay` check here; the payee can
  cancel today, but will not always know to.
- **N2.** `reportSettleUp` (`flow.ts:309-319`) marks the record as reported
  in a transaction and writes the report after it. If `addReport` fails,
  the retry answers "already-reported" and the report is lost. Write the
  report in the same transaction, or mark after the report exists.
- **N3.** `removeAddress` (`flow.ts:176`) takes the same daily limit as
  saving (5 a day). A parent who reached the limit cannot remove their own
  address until the next day. Removal should never be refused.
- **N4.** `unfinishedBetween` (`store.ts:192`) reads at most 200 unfinished
  records of the caller and is not in the create transaction, so the "10
  unfinished per pair" cap can be passed by a few in a race or by a parent
  with more than 200 unfinished records. Bounded by 20 new records a day.
- **N5.** Deletion loop (`privacy/firestore_store.ts:468`): if a record
  lists the uid in `parties` but not as payee or payer (corrupt data),
  `anonymiseSettleUp` returns null and a full page would loop forever. Add
  a guard (skip counter or remove the uid from `parties`).
- **N6.** `blockedEitherWay` reads `chatBlocks` directly. Workstream "own
  chat on Firestore" must keep that collection and ID format, or this
  check silently passes everyone. Add a note or a shared helper.
- **N7.** Retention: a record whose two accounts both stay active is kept
  without limit (as designed: "while either account is active + 1 year").
  Owner and lawyer still have to confirm and publish this (open-items B7).

Feature switches

- **N8.** `FeatureCache.load` (`features/model.ts:97`): when the read keeps
  failing, the instance keeps its last known value, so a stale "on" lasts
  until Firestore answers again or the instance is recycled. For the
  wallet a fail-closed choice (pilot defaults after N failed reads) is
  safer. A switch-off otherwise reaches every instance within 30 seconds
  (at once on the instance that served `adminSetFeature`).
- **N9.** `setFeature` (`features/admin.ts:47`): the switch is written,
  then the audit entry. If the audit write fails the change stands without
  a log line. Use one batch.
- **N10.** Rules tests: add a collection-group read of `settleUpAddresses`
  and `settleUps` (denied today by the catch-all, not asserted).
- **N11.** Withdrawing the wallet terms consent
  (`privacy/callables.ts:291`) still asks the wallet provider for the
  balance while the wallet switch is off. It only affects a parent who
  opened a wallet before the switch-off; harmless, listed because it is
  the one wallet path outside the gate (with account deletion and export,
  which must keep working).
- **N12.** Admin wallet and rating callables check the switch before the
  admin check, so an unauthenticated caller learns a switch state. Not
  secret (parents read the document).

## What was checked and found correct

1. **Feature switches.** `config/features`: `get` for a signed-in caller
   with a valid session, no list, no client write; the rest of `config`
   closed. Missing document or odd field reads as the pilot defaults on
   server and app (wallet, ratings, yearly checks off; Settle up on); a
   failed first read is the defaults, never "all on". Exports of
   `functions/src/index.ts` compared with `GATED_FUNCTIONS`: all 15 wallet
   callables and `walletReconcile`, `listRateable`, `rateParent`,
   `getTrustSummary`, `adminResolveRatingFlag`, `confirmSchoolYear`, and
   the 9 settle-up callables are gated, the switch first; `trustDaily`
   skips only the yearly part; `getTrustOverview` and `adminTrustQueue`
   leave ratings out; the one notification sender drops wallet-*,
   year-check-due and settle-* events of a switched-off feature. No
   Firestore trigger belongs to a switched feature. `adminSetFeature`:
   super admin by custom claim (`requireAdminCaller(..., { superAdmin })`
   and again in the flow), audit entry, confirmation dialog in the panel,
   read-only for ordinary admins. Driver eligibility with yearlyChecks
   off: verified status, bans, urgent-report and selfie pauses
   (`drivingPaused`), licence and car expiry (`papersCheck`) are untouched;
   only the `yearCheckOverdue` mark is ignored. Deletion and export work
   with no wallet (tested). The app only reads the switch; every wallet,
   rating, yearly-check and settle-up route is wrapped in `FeatureGate`.
2. **Settle up.** No money movement and no bank or card field anywhere.
   All writes through callables with App Check and the session and
   new-phone gates; verified claim and record checked for create, save
   address and contacts; both parents must be verified, not banned, not
   blocked either way, and approved members of the carpool at creation;
   one answer ("not-allowed") for all refusals about the other parent.
   State machine: each transition bound to one role and one status,
   non-parties get "not-found", updates run in a Firestore transaction
   (a second tap gets "invalid-state"), create is idempotent on a hash of
   creator and request ID with a reuse check, notification IDs are
   deterministic. Amounts: safe integers in piastres, minimum EGP 1,
   server maximum with a ceiling; the app parses text to piastres without
   floating point. Limits per parent in transactions. History append-only;
   rules deny every client write. Push texts carry no amount, name, note
   or address. Admin view: read-only, reason logged first, no address, no
   note. Deletion: address and counters at once, records anonymised;
   export has the parent's own address and records; retention task runs
   whatever the switch says.
3. **UI and strings.** Every key is in both ARB files with matching
   placeholders (checked by script); the two values that are the same in
   both languages are the address hint and a format string. "The app does
   not move money" is present in both languages (home, review step, record
   page). No hard-coded sizes, colours or durations found in the new
   screens; `TextDirection.ltr` is used only for the address and amount
   fields, which is right.
4. **Docs.** Spec F45 and sections 6, 9, 10, 12; app-store-privacy
   (Financial Info: the InstaPay address and the records, no payment
   processing); app-review-notes; test-iphone 9 and 9b; open-items B7 to
   B10 and D19 to D22; SETUP 21b; COSTS. The five new params are in all
   three `.env` files with defaults in `config.ts`. CLAUDE.md on this
   branch (from main) already describes the switches and Settle up; only
   "Feature IDs (F1 to F44)" is out of date (D20, the owner's file), and
   the progress report's remark that it still describes the wallet as the
   payment feature no longer holds.
5. **Staging deploy.** No new secret; every new param has a value in each
   env file and a default, so `firebase deploy` will not prompt; two new
   composite indexes on `settleUps` (both used: the list and the
   per-pair count) deploy with the existing step; the retention query uses
   an automatic single-field index. `tool/cloud_setup.sh` needs no change.
   Until the indexes finish building (minutes), the list screen and
   `createSettleUp` fail with an index error on a fresh project.

## Not verifiable without a real iPhone

- Copy to the clipboard and the "Copied" feedback, then pasting into the
  real InstaPay app; whether real InstaPay addresses pass the shape check
  (3 to 50 characters, letters, digits, dot, hyphen, underscore).
- Push delivery of the three settle notices, quiet hours, and the tap
  opening Profile > Settle up.
- A switch change from the admin panel reaching an open app (entry points
  disappear, a deep link shows "Not available yet") and the server
  refusing within 30 seconds.
- App Check enforcement on the new callables in staging.
- Arabic layout at 320 dp and text at 200 percent on the device, light and
  dark, VoiceOver labels, reduce motion (goldens cover the layout in CI
  only).
- Offline behaviour of the list (Firestore cache) and of the action
  buttons.
