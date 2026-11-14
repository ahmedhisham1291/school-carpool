# Prompt 11B review: Wallet and transfers (F43, F44, F25)

Branch `prompt-11b-wallet`, head `84a71a0` (includes `main` with Prompts 1
to 9). I reviewed `git diff origin/main...HEAD` (61 files) against
CLAUDE.md (MONEY, SECURITY, PRIVACY, COST MODE), docs/spec.md (F25, F43,
F44, section 6 Wallet, Parent ID and Contributions, section 7, section 9
Wallet and Transfer rows), docs/build-prompts.md "Prompt 11B" and its
"Done when", DECISIONS.md, DESIGN.md, WORKFLOW.md and
docs/progress/prompt-11b.md.

## Verdict: CHANGES NEEDED

The server side is strong. Idempotency by request ID, daily limits inside
a transaction, integer piastres, append-only records, rules that close
every wallet record, a fake refused in prod, a partner stub that fails
closed, and admins with no money path all hold up under probing. Three
things block:

- the Android compile did not finish in CI;
- the app throws away the request ID after an unknown outcome, so a
  retry can send twice;
- amount parsing treats a decimal comma as a thousands separator.

## CI

Run 43568421189 on `84a71a0`: **failure**.

| Job | Result |
| --- | --- |
| Flutter analyze, tests and screenshots | success |
| Cloud Functions tests and rules tests (emulators) | success |
| Web, admin panel and Android compile (staging) | **failure**: web and admin built; "Build Android APK" was cancelled after about 16 minutes ("The runner has received a shutdown signal") |

The two runs before it (`5844731`, `752f5e5`) were cancelled. I did not
look at the screenshots.

What I ran here: a standalone Node 22 harness
(`--experimental-transform-types`, no npm) that drives
`functions/src/wallet/flow.ts` with the test helpers'
`MemoryWalletStore`, `MemoryLedger` and `FakeWalletProvider`. Results are
under "Probes" below. I did not run Flutter, the rules tests or the
emulators.

## Blocking

1. **CI is not green: the Android compile never finished.**
   - Where: run 43568421189, job "Web, admin panel and Android compile
     (staging)", step "Build Android APK".
   - Why it matters: this is the only check of the new `MainActivity` →
     `FlutterFragmentActivity` patch (`tool/patch_native.py:446-462`) and
     of `local_auth` on Android. The log looks like a runner problem, but
     the build is unproven.
   - Fix: re-run the job and get all three jobs green on the final head.

2. **After an unknown outcome, going back mints a new request ID, so the
   same payment can be sent twice.**
   - Where: `lib/features/wallet/send_screen.dart:81-88` (`_go` clears
     `_requestId` for every step below the review) together with `:181`
     and `:194`. Also `lib/features/wallet/money_screens.dart:112-115`
     (withdraw and add money mint a new ID when the amount changes).
   - How it happens:
     - A lost answer shows "We couldn't confirm it. Try again; it won't
       send twice."
     - The parent taps Back to check the amount or note, then Next, Next,
       Send.
     - The app sends a new UUID, so the server sees a new transfer. If
       the first request reached the server (a pending or done transfer),
       the money goes out twice. The daily limit is the only cap.
     - The same happens for withdraw if the parent retypes the amount.
   - Why this blocks: CLAUDE.md MONEY says "a retry can never send
     twice", and Done-when says "a double tap or a retry sends once". The
     server's idempotency only helps if the app keeps the ID.
   - Fix:
     - Once a send ends in `outcomeUnknown`, freeze the flow: keep
       `_requestId`, receiver, amount and note, and disable editing.
     - Back (and the app-bar back) leaves to the wallet, whose history
       shows the pending or done transfer after reconciliation.
     - Mint a fresh ID only after a definite answer (done, failed, or a
       refusal such as a limit).
     - In `_MoneyForm`, keep the ID after an unknown outcome even if the
       amount changes, and show "check your history first".
     - Add a widget test: lost answer, then Back, then Send again uses
       the same request ID.

3. **Amount parsing turns "12,50" into EGP 1,250 (100 times too much).**
   - Where: `lib/features/wallet/wallet_models.dart:36`. `Money.parse`
     drops every `,` (U+002C) as a thousands separator.
   - Why it matters: with `TextInputType.numberWithOptions(decimal:
     true)`, iOS shows the device region's decimal key. In many regions
     that key is a comma, and some Android Arabic keypads use one too.
     "12,50" is parsed as 1250 pounds, which is under the 2,000 EGP
     per-transfer limit, so it is not caught. Only the review screen
     catches it, and only if the parent reads it. This is the "parsing
     user input / no silent change" rule.
   - Fix:
     - Accept `,` (and U+066C) only as grouping in valid positions: one
       to three digits first, then groups of exactly three.
     - Treat a single comma followed by one or two digits as the decimal
       mark, or refuse it with "use a point for piastres".
     - Add `Money.parse('12,50')` (expect 1250 or null, never 125000) and
       `'1,2,3'` (null) to `test/wallet/wallet_logic_test.dart`.

## Probes (server logic, run here)

All of these behaved correctly:

| Probe | Result |
| --- | --- |
| Same request ID, different amount | `request-reused` |
| Same ID, other kind (top-up ID reused for send or withdraw) | `request-reused` |
| 5 concurrent sends with one request ID | one transfer at the partner, balance moved once |
| 3 parallel EGP 2,000 sends, daily limit EGP 5,000 | 2 done, 1 `over-daily-limit` (left 1,000) |
| Timeout (money moved, answer lost), then retry before and after 30 s | pending, then done from `findOperation`; moved once |
| Lost (never arrived), then reconcile | resent with the same ID; moved once; second run is a no-op |
| Self by parent ID / by uid | `self` |
| uid without a shared carpool | `not-in-carpool` |
| Amounts 100.5, "1000", -5, 0, 1e12, NaN | all `invalid-request` |
| Suspended receiver; suspended sender; claim missing | `receiver-cannot-receive`; `suspended`; `not-verified` |
| 22 lookups in an hour | 20 answered, then `rate-limited`; a send by parent ID after that is also limited |
| Frozen: send, add, withdraw, be paid | all refused |
| Insufficient funds | failed; the daily counter was given back |

## Non-blocking

1. **Same request ID with a different receiver or note is replayed as
   the earlier transfer.**
   - Where: `functions/src/wallet/flow.ts:297-299` and `:326-330`. The
     early check passes `toUid = null`.
   - Probe: send to Hoda, then the same ID to Sam. The second call
     answers "done, Hoda", and Sam gets nothing. No money is doubled, but
     the answer is about a different request.
   - Fix: compare the resolved receiver (uid, or the parent ID's uid),
     `carpoolId` and the note, and answer `request-reused` on any
     difference.
2. **"Failed" can be recorded while the partner may still execute the
   request.**
   - Where: `reconcile` (`flow.ts:553-566`) settles as failed
     (`sender-frozen`, `receiver-frozen`, or `not-received` after 24 h)
     when `findOperation` returns null.
   - Why it matters: `null` can also mean "still in flight" at a real
     partner. If a frozen-on-our-side wallet was not frozen at the
     partner (the partner freeze failed, `flow.ts:667-671`), a late
     execution would move money while our record says failed and the day
     is credited back.
   - Fix: before settling failed, ask the partner to cancel or void that
     request ID (put it in the partner checklist in SETUP.md 20).
     Otherwise keep it pending and raise a `walletAlerts` entry for an
     admin.
3. **Concurrent reconciles of one transfer** can run at the same time:
   the scheduled job, "Check again" and `getWallet` → `reconcileMine`.
   `touchPending` is not transactional, so two `p.send` calls with the
   same ID can happen. This is safe only if the partner's idempotency is
   strict. Take a short lease on `walletPending/{id}` in a transaction
   before resending.
4. **Freeze is not re-checked inside the `startTransfer` transaction**
   (`firestore_store.ts:279-303`). `requireOpenWallet` and
   `resolveReceiver` read outside it, so an admin freeze that lands in
   between still sends. Read `wallets/{from}` and `wallets/{to}` in the
   transaction and refuse if either is frozen.
5. **The partner freeze is never retried.** "Not me" and admin freeze
   only log when the partner call fails. Have `walletReconcile` re-apply
   the freeze to the partner for wallets frozen on our side. "Not me"
   also writes no audit entry and no `wallet-frozen` event.
6. **Parent ID lookup returns the first name of suspended or banned
   accounts** (`flow.ts:210-212`, probe: `{"firstName":"Hoda","verified":false}`).
   Consider `receiver-not-found` (or no name) for banned and suspended
   accounts.
7. **`transfers/{id}.status` is "pending" forever** in Firestore
   (`firestore_store.ts:133`). The real status is in
   `transferResults/{id}`, which is fine for append-only, but anyone
   reading the console, an export or BigQuery will be misled. Rename it
   to `initialStatus`, or drop it. Owner decision 1 in the progress note.
8. **"Pay contribution" is shown to the organizer too**
   (`carpool_detail_screen.dart:199`, `:474`).
   - For the organizer, `_autoPick` (`send_screen.dart:226-236`) can
     pre-fill the only other member as the receiver.
   - `Money.contribution` uses `max(children, 1)`
     (`wallet_models.dart:87`), so a member with no children in the
     carpool gets one child's amount.
   - Hide the row for the organizer and for members with no children.
9. **WhatsApp for wallet messages is ON by default**
   (`functions/src/notifications/catalog.ts` `WHATSAPP_DEFAULTS.wallet:
   true`). That contradicts COST MODE ("codes and critical alerts by
   default; everything else push-only"), and it means up to two paid
   templates per transfer. **Owner decision.** The texts themselves carry
   no amount, name or note, which is good.
10. **Admin freeze and resolve are audited after the change**
    (`admin.ts:180`, `:210`). If the audit write fails, the change is
    unlogged. Write the audit entry first, or in the same batch.
11. **Pending incoming and failed incoming transfers** show in the
    receiver's history with the sender's name (`transferView`). Consider
    hiding failed incoming rows from the receiver.

## Checked and fine

- **Money rules:**
  - Integer piastres throughout, on the server (`amountField`,
    `limitsFrom` with hard ceilings) and in the app (`Money`).
  - No fee anywhere.
  - Limits come from `config/wallet`. Daily counters live in the same
    transaction as the transfer create, and a failure gives the day back
    in the settle transaction.
  - Append-only: `create()` only for `transfers` and `transferResults`.
- **Rules:** every wallet collection is `if false`, with rules tests for
  owner, receiver, unverified user, admin and signed-out user, and
  `deny_all` paths. The app cannot write a balance or a transfer.
- **Device check:** `local_auth` runs before every send and withdraw,
  also before a retry. It is never cached and allows the passcode
  fallback. No passcode on the phone means nothing is sent, and errors
  fail closed (`device_auth.dart`).
- **Provider:** the fake is refused in prod (`walletConfigProblem`;
  `.env.prod` sets `APP_ENV=prod`). The partner stub refuses every call.
  `attempt()` treats any unexpected error as unknown, so the transfer
  stays pending.
- **Admins:** `AdminWalletPort` gives admins only freeze, balance and
  list, with a test. Every view and change is audited, and the admin log
  never shows notes.
- **Alerts:** unusual patterns create one alert per hour bucket and block
  nothing.
- **Riverpod:** every wallet and admin wallet `FutureProvider` has
  `retry` set to none, with its own Retry button.
- **Notifications:** texts without amounts, routed to `/profile/wallet`
  (allow-listed).
- **ARB:** Arabic and English have the same keys.
- **Design:**
  - `AppInitialAvatar` and `AppAmount` are in the gallery and DESIGN.md.
  - One-line tests at 320 dp, x1 and x2, Arabic and English.
  - Transfer badges and amounts scale down instead of being cut off.
- **Logs:** no amounts, names or notes; Sentry gets only unexpected
  errors.
- **Costs:** `minInstances` is 0 (`MIN_INSTANCES_WALLET`), and COSTS.md
  is updated.

## Done-when coverage

- Add test money, send by parent ID and from a carpool, both histories
  match: covered by Functions and widget tests and progress steps 2 to 5.
- A double tap sends once: covered.
- A retry sends once: covered only when the parent retries from the
  review screen, not after going Back (blocking 2).
- Above the limit is refused, both as the parent types and on the
  server: covered.
- A frozen wallet cannot send: covered on the server and in the app.
- Rules tests prove the app cannot write a balance or a transfer:
  `tests/rules/wallet.test.ts` passed in CI.
- The iPhone check itself is still the owner's (progress steps 1 to 10).
