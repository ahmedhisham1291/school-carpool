# Prompt 11B: Wallet and transfers (F43, F44, F25) — progress note

Branch: `prompt-11b-wallet` (from `main` with Prompts 1 to 9; Prompt 10 is
on another branch and nothing here depends on it). Date: 14 Nov 2026. The
coordinator gave "go" on the owner's behalf.

**Status: code complete. Functions unit tests were run here (481 pass, 40
of them new in `functions/test/wallet.test.ts`; Node 22 with stand-in
stubs as before). The Flutter code, the widget, logic, one-line and
screenshot tests, and the rules tests were written, not run here** (no
Flutter SDK or npm registry in this workspace). The rules tests were
type-checked against a stub. Expect small analyzer fixes on the first CI
run, most likely around `local_auth` 3.x and the Riverpod `retry:` option on
`FutureProvider.autoDispose(.family)`.

## Plan that was followed

1. Server (`functions/src/wallet/`): `WalletProvider` interface with a fake
   (test money) and a stub for the licensed partner; transfers, top-ups and
   withdrawals through Cloud Functions with request-ID idempotency, limits
   from server settings, append-only records, reconciliation; parent ID
   lookup; carpool contacts; reports and unusual-pattern alerts; admin log,
   freeze and alerts; wallet notifications through the Prompt 8 sender.
2. Rules (every wallet record closed) and rules tests; indexes.
3. App: wallet screen (open with the partner's terms), Send (5 steps with
   a fresh Face ID / fingerprint / passcode check), Add money, Withdraw,
   transfer detail with "Report a problem", "Pay contribution" on the
   carpool; admin panel pages. Strings AR/EN, gallery, tests.

## Decisions (please confirm)

1. **Append-only records.** `transfers/{id}` is created once with status
   "pending" and never changed; the outcome is a second record,
   `transferResults/{id}`, created once (`create()` refuses a second one).
   The status the app shows is the result's, or pending. Nothing is ever
   edited or deleted (spec section 9 "Transfer"; MONEY rules).
2. **Idempotency.** The app makes one random request ID per review (UUID)
   and keeps it for every retry; the transfer ID is a hash of uid and
   request ID, and it is also the partner's idempotency key. A double tap,
   a retry after a lost answer, or two calls at once find the same
   transfer. The same request ID with another amount is refused.
3. **Unknown outcomes never lose or double money.** A partner timeout or
   outage leaves the transfer **pending** (its amount still counts against
   the day). Reconciliation (`walletReconcile` every 5 minutes, the app's
   "Check again", and opening the wallet) first asks the partner for our ID:
   known -> take its answer; unknown -> send again with the same ID (at most
   3 times, only while both wallets are open); still unknown after 24 hours
   -> failed "the partner never got it" (nothing moved). A partner that does
   not answer leaves it pending.
4. **Balance always from the partner.** `getWallet` reads the partner; when
   the partner does not answer the app shows an error with Retry, never the
   copy. `wallets/{uid}.balanceCopy` is only a copy (admin view).
5. **Limits are server settings** in Firestore `config/wallet` (piastres;
   defaults 2,000 EGP per transfer, 5,000 EGP and 20 transfers a day,
   top-ups 5,000 EGP each and 10,000 a day), clamped by hard ceilings in
   code. Withdrawals count in the daily outgoing limits. Change to the
   partner's limits after the contract (open question).
6. **Who can be paid.** By parent ID (rate-limited: 20 lookups an hour,
   counted before anything is looked up; a send by parent ID counts too), or
   a parent of one of my carpools (by uid, accepted only when we share an
   approved carpool). Paying a contribution also requires that carpool.
   The lookup returns the first name and the Verified badge only.
7. **"Photo" of the receiver.** Parents have no profile photo in the data
   model (selfies are private and deleted after review). The confirmation
   shows a letter avatar (`AppInitialAvatar`), the first name and the
   Verified badge; a photo can replace the letter when profile photos exist
   (open question).
8. **Face ID / fingerprint / passcode** (`local_auth` 3.x) before every
   transfer and every withdrawal, every time (never cached), also before a
   retry. No passcode on the phone -> nothing is sent and the parent is told
   to set one. Adding money needs no check (money comes in). The server
   cannot verify the check itself; it is the app's job (MONEY rules), and
   the server's limits, idempotency and freeze are the second line.
9. **Pay contribution (F25)** on the carpool (members only, when a
   contribution is set): opens Send with the carpool's organizer and the
   agreed amount for my children (pounds per child x my children) filled in,
   on the receiver confirmation. The parent still confirms, can change the
   amount and must pass Face ID. Nothing is ever taken automatically.
10. **Frozen** wallets cannot send, withdraw, add or receive (also at the
    partner). Admin freeze writes our side first, so it works even if the
    partner does not answer; unfreeze needs the partner's answer. "Not me"
    (someone else sent it) reported by the sender freezes their own wallet
    at once.
11. **Notifications** through the Prompt 8 sender: `wallet-received` and
    `wallet-sent` for every done transfer (both parents), `wallet-failed`
    and `wallet-updated` when a pending one settles later, `wallet-frozen`
    / `wallet-updated` on freeze and unfreeze. No amount, name or note in
    any text (lock screen). WhatsApp group "Wallet" is **on by default**:
    money moving is a security signal (a stolen phone). This departs from
    COST MODE "critical alerts only"; the prompt asks for push and WhatsApp.
    Parents can switch it off; see COSTS.md.
12. **Admins cannot move money.** The admin flows get only the partner's
    freeze, balance and transaction list (`AdminWalletPort`); a test checks
    that the admin module exports no money path and never calls send, add
    or withdraw. Every view and change is in the audit log; transfer notes
    never appear in the admin log.
13. **Unusual patterns** create admin alerts (`walletAlerts`), never block:
    3 or more first-time receivers within an hour, or 10 or more transfers
    within an hour (settings). Transfer problem reports go to the same
    queue ("Wallet" in the admin panel).
14. **The partner stub** (`PartnerWalletProvider`) refuses every call; with
    `WALLET_PROVIDER=partner` and `WALLET_PARTNER_ENABLED=false` the app
    says "Wallet not open yet". The fake is refused in prod.

## Data model

| Record | Holds | Who reads / writes |
| --- | --- | --- |
| `wallets/{uid}` | partner wallet ref, status (active, frozen), balance copy, terms version, freeze reason, admin note | Cloud Functions only |
| `transfers/{id}` | kind (transfer, topup, withdraw), request ID, from, to, parties, first names, amount (piastres), EGP, note, carpool, Cairo day, created at; status "pending" | Created once by Cloud Functions; never changed |
| `transferResults/{id}` | done or failed, reason, partner ref, settled at | Created once by Cloud Functions |
| `walletPending/{id}` | transfers waiting for the partner (work list) | Cloud Functions only |
| `walletDaily/{uid}_{day}` | amount and count sent today, amount added | Cloud Functions only |
| `walletLimits/{uid}` | lookup and report counters | Cloud Functions only |
| `walletAlerts/{id}` | unusual patterns and transfer reports | Cloud Functions only (admins through functions) |
| `config/wallet` | limits (server settings) | Console / Cloud Functions |
| `config/walletFake`, `fakeWalletAccounts`, `fakeWalletOps` | the fake partner's mode and test money | Cloud Functions only (dev, staging) |
| `users/{uid}/consents/{id}` | + type `walletTerms` with its version | Cloud Functions write; the parent reads (Prompt 2 rule) |
| `notificationEvents` | + wallet types | Cloud Functions only |

Indexes: `transfers` (parties + createdAt desc; uid + createdAt; uid +
toUid + createdAt), `walletAlerts` (status + createdAt desc),
`fakeWalletOps` (refs + at desc).

## Functions (new)

Callables: `getWallet`, `openWallet`, `lookupParentId`, `walletContacts`,
`sendMoney`, `addMoney`, `withdrawMoney`, `listWalletHistory`,
`getTransfer`, `reportTransfer`; admin: `adminListTransfers`,
`adminGetWallet`, `adminSetWalletFrozen`, `adminListWalletAlerts`,
`adminResolveWalletAlert`. Scheduled: `walletReconcile` (every 5 minutes).
Params: `WALLET_PROVIDER`, `WALLET_PARTNER_ENABLED`, `MIN_INSTANCES_WALLET`.

## Screens and states

| Screen | Layout | Loading | Empty | Error | Offline |
| --- | --- | --- | --- | --- | --- |
| Wallet (`/profile/wallet`, Profile > Wallet) | Balance card (from the partner, "you can still send X today"); Send money (primary); Add money and Withdraw (outlined); History rows: who or what, date and time, note, amount (+ for money in), status badge unless done; pull to refresh | Skeleton card and rows | Not open yet (partner off); "No transfers yet"; before opening: what the wallet is, partner terms checkbox, Open wallet | Error view with Retry; not verified -> "Verify first" with Verify account; suspended; frozen -> a note and the money buttons off | Offline view with Retry |
| Send (`/profile/wallet/send`) | 5 steps with progress: Who (my carpools' parents; or parent ID + Find), Confirm (avatar, first name, Verified badge), Amount (checked as typed: format, minimum, per transfer, left today, balance), Note (optional), Review (no fee, cannot be undone) -> Face ID -> result | Skeleton rows for contacts | "No parents in your carpools yet" | Inline sentence per server answer; lost answer: "Try again; it won't send twice" (same request ID) | Same inline sentence |
| Result (in Send, Add, Withdraw) | Done / In progress (Check again) / Not sent (why; nothing left your wallet); Back to wallet | Button spinner | — | Snackbar on Check again | Snackbar |
| Add money, Withdraw | Sentence, (Withdraw: balance card), amount field with the limit, "No fee", one button (Withdraw: Face ID) | Wallet skeleton | — | Inline | Offline view |
| Transfer (`/profile/wallet/t/<id>`) | Card: title, amount, status (+ reason or "checking"); When, Note, Fee "none"; Check again (pending); Report a problem | Skeleton | Not found | Error view | Offline view |
| Report sheet | Reason chips (Not received, Wrong amount, Wrong person, Not me (sent only), Other), freeze note for "Not me", optional note, Send report | Button spinner | — | Inline | Inline |
| Carpool detail | + "Pay contribution" row (amount, optional) for members when a contribution is set | — | — | — | — |
| Admin: Wallet (`/wallets`) | Open alerts (kind, count, time, Resolve with an outcome), transfer log (from -> to, amount, time, status; opens the parent's wallet) | Skeleton | No open alerts / no transfers | Error | Offline |
| Admin: Parent's wallet (`/wallets/<uid>`; link on the user page) | Status badge, balance (partner, or "copy; partner not answering"), freeze reason, Freeze (danger) or Unfreeze, alerts, our transfers, the partner's records | Skeleton | No wallet | Error | Offline |

New design-system pieces `AppInitialAvatar` and `AppAmount` are in the
gallery under "Wallet" with `BalanceCard`, `ReceiverCard` and
`TransferRow` (DESIGN.md).

## New packages (CLAUDE.md rule 3)

- `local_auth ^3.0.0` (flutter.dev official plugin, free): the fresh Face
  ID / fingerprint / passcode check the MONEY rules require before every
  transfer. Named by the prompt. iPhone: `NSFaceIDUsageDescription` was
  already in `tool/patch_native.py` and both `InfoPlist.strings` ("confirms
  every wallet transfer"). Android: `tool/patch_native.py` now makes
  `MainActivity` a `FlutterFragmentActivity` (needed by the biometric
  prompt). Flutter-team plugin, so no `KOTLIN_FIX_PLUGINS` entry. 3.x API
  checked on pub.dev (3.0.2 latest; `authenticate(localizedReason:)`,
  `LocalAuthException`; Flutter 3.38+ and iOS 13+).
- Server: none. `url_launcher` (already in the app) opens the partner's
  payment page for a top-up when the real partner returns one.

## How to test it on the iPhone (the "Done when" check)

1. Emulators and seed as in Prompts 6 to 8 (SETUP.md 20.4); `WALLET_PROVIDER`
   is `fake` by default. Dev app on the iPhone with
   `--dart-define=EMULATOR_HOST=<Mac IP>`, signed in as your verified seed
   parent; a second device (simulator) as another verified seed parent of
   the same carpool (for example Hoda). Both: Profile > Wallet > tick "I
   agree to the payment partner's terms" > Open wallet.
2. **Add test money:** Wallet > Add money > 500 > Add money: "Money added",
   balance EGP 500.
3. **Send by parent ID:** on the second device Profile > copy the parent
   ID. On the iPhone Wallet > Send money > type it > Find parent: Hoda,
   Verified > Yes, continue > 125.50 > Next > "Week 1" > Next > Send >
   Face ID: "Sent". 
4. **Send from a carpool:** Carpools > the carpool > Pay contribution:
   Hoda (organizer) and the agreed amount are filled in > Yes, continue >
   Next > Next > Send > Face ID.
5. **Both histories match:** both transfers on both devices with the same
   date, amount, note and "Done"; balances moved once.
6. **Double tap / retry sends once:** tap Send twice quickly: one transfer.
   Airplane mode on, Send: "We couldn't confirm it. Try again; it won't send
   twice." Airplane mode off, Send again (Face ID again): one transfer.
   Pending path: set Firestore `config/walletFake` = `{mode: "timeout"}`,
   send: "In progress"; set `mode` back to `"ok"`, wait 30 seconds, Check
   again: "Sent", and only one transfer at the partner.
7. **Above the limit is refused:** type 2500: "The most per transfer is EGP
   2,000" and Next stays off (`config/wallet.perTransferMax` changes it; the
   server refuses it too: `functions/test/wallet.test.ts`).
8. **Frozen wallet cannot send:** admin panel > Wallet > open your parent
   (or Users > the parent > Parent's wallet) > Freeze wallet > reason >
   confirm. On the iPhone the wallet shows "Your wallet is paused" and Send,
   Add and Withdraw are off; you get a "Wallet paused" alert. Unfreeze.
9. **Rules tests** prove the app cannot write a balance or a transfer:
   `tests/rules/wallet.test.ts` (CI).
10. Report: Wallet > a transfer > Report a problem > Wrong amount > Send
    report; it is in the admin panel > Wallet > Alerts. Check Arabic and
    dark mode.

## Tests

| Test | Status |
| --- | --- |
| `functions/test/wallet.test.ts` (40): amounts in piastres (floats refused), formatting, parent IDs, notes, transfer IDs, Cairo day, settings clamps; provider factory (fake refused in prod, partner fails closed), fake partner idempotency; opening (verified + terms + consent record, suspended, switched off), balance from the partner (outage = error, not the copy); lookup (first name + badge only, rate limit before reading); send by parent ID (both histories match), from a carpool (membership enforced), **double tap and retry send once**, request ID reuse refused, **limits per transfer and per day** (count, amount, next Cairo day, withdrawals counted), failed transfer gives the day back, **frozen cannot send** / frozen receiver, verification both sides, no fee, append-only writes; **timeout -> pending -> reconciled from the partner's record**, **lost -> resent once with the same ID**, partner down stays pending, give up after a day with nothing moved, frozen meanwhile not resent, opening the wallet settles stale pending; top-up and withdraw limits; notifications (both parents, no amount/name/note), logs without amounts/names/notes; reports ("Not me" freezes own wallet), pattern detection and one alert; admin log (no notes, audited), freeze/unfreeze (reason, audit, event), freeze without the partner, **admins cannot move money**, resolve alert | **Run here: pass** |
| All Functions unit tests | **Run here: 481 pass** (only the known stub type gaps in `tsc`) |
| `tests/rules/wallet.test.ts`, `deny_all.test.ts` paths | Written, not run here (CI); type-checked against a stub |
| `test/wallet/wallet_logic_test.dart` (piastres parsing incl. Arabic digits, no rounding, formatting, contribution, request IDs, parent IDs, request JSON, failures, wallet info) | Written, not run here |
| `test/wallet/wallet_screens_test.dart` (wallet states: data, open with terms, frozen, off, not verified, offline + retry, partner down, RTL; send by parent ID with Face ID, from a carpool, Pay contribution prefill, double tap, lost answer retry with the same ID, no Face ID / no passcode, over the limit as typed, server refusal, pending + Check again, unknown ID, unverified receiver; add money, withdraw with Face ID, report from history, "Not me"; one line at 320 dp AR/EN x1/x2) | Written, not run here |
| `test/admin/admin_wallet_test.dart` (log and alerts, no money buttons, resolve, freeze with reason after confirming, user page link, one line) | Written, not run here |
| `test/notifications/notification_logic_test.dart` (wallet group default, route); `test/carpools/carpool_screens_test.dart` (+1: Pay contribution opens Send with the carpool and 50 EGP x 1 child, nothing sent) | Written, not run here |
| Screenshots `wallet_wallet`, `wallet_open`, `wallet_send_who`, `wallet_send_confirm`, `wallet_transfer`, `wallet_add` (AR/EN, light/dark) | Written, not run here (CI artifact) |

## Open questions

1. Which CBE-licensed partner, and its API, limits, fees (ask for none
   between parents), identity checks, how add money (payment page) and
   withdraw (to which account) work, and its dispute process. The limits in
   `config/wallet` are placeholders until then.
2. WhatsApp for wallet messages on by default (decision 11): keep, or
   push only by default to save cost?
3. Profile photos: the confirmation shows a letter avatar for now. Add
   public profile photos later (would need a review and a privacy decision)?
4. Wallet terms text and version (`WALLET_TERMS_VERSION` 2026-11-14) are
   drafts until the partner's contract and the lawyer's review.
5. Retention of transfer records after account deletion: Prompt 12 asks
   the lawyer; the records are kept for now.
6. Contribution amount when the period is per trip: the prefill is one
   period's amount for my children; the parent can change it.

## Not done

- The real partner provider (`PartnerWalletProvider` is a stub that refuses
  every call) and the partner's webhooks.
- Website (Stage 2): the wallet screens compile for the web, but there is
  no Face ID there, so sending money says to set a passcode (the phone app
  is the place to pay).
- App lock with Face ID for the whole app (Prompt 12).
- Wallet export and deletion in the privacy screen (Prompt 12).
- Paging past the first 30 history rows in the app (the function supports
  `afterId`; the screen shows the first page).
