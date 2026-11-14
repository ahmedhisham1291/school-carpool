# Workstream A: pilot feature switches and Settle up by InstaPay (F45)

Branch `improve-a-feature-switches`. Decisions: docs/DECISIONS.md
"Improvements, revised" (14 Nov 2026), items 1 and 8. The coordinator said
"go"; this file is the plan, then the report (bottom).

## Plan

### Part 1: pilot feature switches

**Data.** One server document, `config/features`, with four booleans:
`wallet`, `ratingsAndVouching`, `yearlyChecks`, `settleUp`. A missing
document or field reads as the pilot defaults: wallet OFF, ratings and
vouching OFF, yearly checks OFF, Settle up ON. Signed-in parents may read
that one document (rules); only Cloud Functions write it. Core features
(sign-in, verification, carpools, schedule, trips and alerts, chat) have no
switch.

**Server (the authority).**
- `functions/src/features/model.ts`: keys, defaults, parsing, a
  per-instance cache (30 seconds, one read at a time, a failed read keeps
  the last known value or the pilot defaults), and the list of every gated
  function (`GATED_FUNCTIONS`).
- `functions/src/features/gate.ts`: `requireFeature` (refuses with
  `failed-precondition`, `details.reason = "feature-off"`,
  `details.feature`), `featureGatedCall` / `featureSessionCall` (the switch
  is checked FIRST, before the session and device checks), `skipWhenOff`
  for jobs.
- Wallet: every callable (parents' and admins') refuses; `walletReconcile`
  does nothing.
- Ratings and vouching: `listRateable`, `rateParent`, `getTrustSummary`,
  `adminResolveRatingFlag` refuse; `getTrustOverview` keeps working with an
  empty summary and nobody to rate; `adminTrustQueue` returns no rating
  flags. Guardian links and the phone change have no switch.
- Yearly checks: `confirmSchoolYear` refuses; `trustDaily` skips the yearly
  part (no reminder, no "overdue" mark); `yearCheckOf` says "none"; the
  schedule ignores an old `yearCheckOverdue` mark (nobody is blocked).
- NOT switched: verified status, licence and car expiry (reminders,
  expiry, runs released), suspension and bans, driving pauses after an
  urgent report or a failed selfie check.
- Notifications: the one sender closes an event of a switched-off feature
  (wallet-*, year-check-due, settle-*) without a record, push or WhatsApp.
- Account deletion and export already work for a parent with no wallet
  (the wallet lock returns "no wallet"); kept, with tests.
- Admin: `adminGetFeatures` (any admin) and `adminSetFeature` (super admin
  only; audit entry `feature.on` / `feature.off` with the switch and its
  value; no reason needed, per the owner).

**App.** One Firestore listener on `config/features`
(`featureSwitchesProvider`); defaults while loading, offline or signed out.
Hidden when off: Profile rows (Wallet, Rate parents, Settle up), the yearly
check banner, the carpool's "Pay contribution" row, the wallet group in
alert settings. A deep link to a switched-off screen shows a calm "Not
available yet" state (`FeatureGate`), never an error. Contributions with
the wallet off read "paid in cash or by Settle up".

**Admin panel.** New "Settings" section: one switch per feature with a
short explanation, a confirmation dialog before each change, the result
from the server. Ordinary admins see the switches read-only.

### Part 2: Settle up by InstaPay (F45)

**Principle (never break).** The app never moves, holds or sees money and
never asks for bank or card details. It records payment requests between
two parents and shows how to pay in the InstaPay app. No fee, no
commission.

**Data model.**
- `settleUpAddresses/{uid}`: `{ uid, address, updatedAt }`. Cloud Functions
  only (rules: nobody reads it, the owner included; the owner reads it
  through `getSettleUpProfile`). Never logged, never sent to Sentry,
  Algolia or analytics.
- `settleUps/{id}`: payee, payer, first names, `parties`, carpool, amount
  in piastres, currency EGP, reason (contribution, fuel, other), short
  note, status (open, paid, closed, cancelled, declined), `notReceived`
  count, `reportedBy`, `events` (append-only history: type, side, time),
  times, `keptUntilMs`. Written only by Cloud Functions; read by its two
  parties (rules). ID = hash of creator and request ID, so a retry cannot
  duplicate.
- `settleUpLimits/{uid}`: rate-limit counters.
- `config/settleUp.maxAmount` (piastres, default EGP 5,000): server
  setting, no deploy to change.

**State machine.**
open --payer "I paid"--> paid --payee "Received"--> closed;
paid --payee "Not received"--> open (counted);
open --payee "Cancel"--> cancelled; open --payer "Decline"--> declined.
A payer may record a payment first (starts as paid). After N "Not
received" marks (param, default 2) either side may report it once, into
the existing reports queue.

**Functions** (all App Check, all behind the `settleUp` switch):
`getSettleUpProfile`, `saveInstaPayAddress`, `removeInstaPayAddress`,
`settleUpContacts`, `createSettleUp`, `settleUpAction`,
`getSettleUpAddress` (the payee's address, only to the payer of an OPEN
record), `reportSettleUp`, `adminListSettleUps` (read only, logged reason).
New params (all three env files): `SETTLE_UP_REQUESTS_PER_DAY`,
`SETTLE_UP_CHANGES_PER_DAY`, `SETTLE_UP_ADDRESS_CHANGES_PER_DAY`,
`SETTLE_UP_ADDRESS_VIEWS_PER_HOUR`, `SETTLE_UP_REPORT_AFTER`. No new
secret, so `tool/cloud_setup.sh` needs no change.

**Notifications.** Push only (no WhatsApp template, no WhatsApp switch):
`settle-requested` to the payer, `settle-paid` to the payee,
`settle-updated` to the other side on Received, Not received, Cancel,
Decline. No amount, name, note or address in the text; quiet hours apply.

**Privacy.** Export: a "Settle up" section (own address, own records, the
other parent by first name only). Deletion: address and counters at once;
in each record the parent becomes an initial and leaves `parties`, an
unfinished record ends. Retention: while either party's account is active
+ 1 year (same rule as trips), enforced by `retentionDaily`.

**Screens** (Arabic first, RTL; design tokens; one primary action each).

1. *Settle up home* (`/profile/settle-up`, also from the carpool screen
   with that carpool pre-chosen). Top: the line "The app does not move
   money" as an info message. Then "My InstaPay address" row (shows the
   address or "Add your address"). Then a summary card per person: name,
   "You owe" and "Owes you" amounts, "waiting for confirmation". Then two
   sections: Open and Closed, each a list of rows (name, amount, state
   badge). Primary action: "New request".
   - Loading: skeleton card and rows. Empty: icon, "No requests yet", the
     primary button. Error: full-screen error with Retry. Offline: the
     cached list with an offline banner; actions disabled with the reason.
2. *InstaPay address sheet*: one field (`name@instapay`, checked as the
   parent types, error says the form expected), helper "Find it in the
   InstaPay app under your profile", Save, and Remove (asks to confirm).
   States: saving (button busy), error message under the field, offline
   message.
3. *New request* (`/profile/settle-up/new`), three short steps with a
   progress indicator: (1) Who: carpool parents list (loading skeleton,
   empty "No parents in your carpools yet", error with Retry) and a choice
   "Ask for a payment" / "I already paid"; (2) How much and why: amount in
   EGP (checked as typed, the maximum from the server), reason chips
   (Contribution, Fuel, Other), optional note (80 characters); (3) Review:
   the summary, the line "The app does not move money", Send. A payee
   without a saved address is asked for it first. Errors say how to fix
   (limit reached, not in the same carpool any more, offline).
4. *Request detail* (`/profile/settle-up/r/:id`): amount, person, reason,
   note, state badge; for the payer of an open request the payee's address
   in a copy field (Copy with "Copied" feedback) and the steps "1. Copy the
   address 2. Open InstaPay and send 3. Come back and tap I paid", then the
   line "The app does not move money"; primary button by state and side (I
   paid / Received), secondary (Not received, Cancel, Decline, each with a
   confirmation), Report after N bounces, and the history list.
   - Loading: skeleton. Not found or not yours: empty state. Error and
     offline: message with Retry; buttons disabled offline.
5. *Feature off* (any deep link): icon, "Not available yet", one line, Back.
6. *Admin user page*: "Settle up" section, opened with a reason like
   photos; read-only table (role, other parent, amount, state).
7. *Admin Settings*: the switches (above).

**InstaPay link.** Only if an official link or URL scheme that opens the
app with the payee can be verified; otherwise Copy only (see findings).

### Open questions (decided as below unless the owner says otherwise)

1. Admin wallet pages while the wallet is off: the functions refuse
   ("feature off"); the panel keeps the menu entry and shows the reason.
2. "Blocked" parents: read as suspended or banned accounts AND parents who
   blocked each other in chat (either way).
3. A payee must save an InstaPay address before asking; a payer who
   records a payment needs none.
