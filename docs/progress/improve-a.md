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
   - Loading: skeleton card and rows. Empty: a short note under "Open"
     and the primary button. Error and offline: full-screen state with
     Retry (Firestore's cache shows the last list when there is one). Not
     verified: an empty state with "Verify account".
2. *InstaPay address screen* (`/profile/settle-up/address`): one field (`name@instapay`, checked as the
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
     offline: message with Retry; a refused or offline action is one
     sentence above the buttons (the phone has no connectivity check, so
     buttons are not greyed out offline).
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

## Report (builder, 14 Nov 2026)

### Built

**Part 1: feature switches**

- Server: `functions/src/features/` (model, cache, gate, admin flow and
  callables `adminGetFeatures`, `adminSetFeature`). Wallet: all 15
  callables refuse, `walletReconcile` does nothing. Ratings and vouching:
  4 callables refuse; the Profile overview and the admin trust queue leave
  ratings out. Yearly check: `confirmSchoolYear` refuses, `trustDaily`
  skips the yearly part, an old "overdue" mark blocks nobody
  (`drivingPaused` in carpools/model.ts). The notification sender drops
  wallet, yearly-check and settle-up events of a switched-off feature.
  Driving papers, suspension, bans and driving pauses are untouched.
- Rules: `config/features` readable by a signed-in parent with a valid
  session; nothing else in `config` is readable; nobody writes it.
- App: `lib/features/feature_switches/` (one listener, pilot defaults
  while loading or on an error, `FeatureGate` with a "Not available yet"
  screen). Hidden when off: Profile rows (Wallet, Rate parents, Settle up),
  the school-year card, the carpool's "Pay contribution", the wallet row in
  alert settings, the wallet and ratings lines on the privacy screen. The
  contribution text follows the switches (wallet / cash or Settle up /
  cash).
- Admin panel: new "Settings" section (one switch per feature, a
  confirmation before each change, read-only for ordinary admins); the
  audit log shows "Feature turned on / off".

**Part 2: Settle up by InstaPay (F45)**

- Server: `functions/src/settle_up/` (model with the state machine, flows,
  Firestore store, 9 callables), 5 new params in `config.ts` and in all
  three `.env` files, server setting `config/settleUp.maxAmount`, two
  Firestore indexes, rules for `settleUps`, `settleUpAddresses`,
  `settleUpLimits`. Push-only notices `settle-requested`, `settle-paid`,
  `settle-updated`. Reports go into the existing reports queue (reason
  "other", source `settleUp`, the record ID in the note). Export section
  "settleUp"; deletion removes the address at once and turns the parent
  into an initial in each record; `retentionDaily` task `settleUps`
  deletes a record when neither account is active and the last closure is
  a year old. Both Sentry scrubbers now remove `name@instapay`.
- App: `lib/features/settle_up/` (list with the per-person summary,
  InstaPay address screen, new request in three steps, record page with
  the address, Copy, the three steps and "The app does not move money"),
  entry points on Profile and on the carpool page, three notification
  kinds, a privacy data type, three analytics events (no amounts, names or
  addresses), pieces in the dev gallery. 171 new strings in Arabic and
  English.
- Admin panel: "Settle up" on the user page, read-only, opened with a
  logged reason like the photos; no address and no note.
- Docs: spec (F45 in section 4; sections 6, 9, 10, 12), app-store-privacy,
  app-review-notes, test-iphone (sections 9 and 9b), analytics-events,
  SETUP 21b, COSTS, open-items (B7 to B10, D19 to D22).
  `tool/cloud_setup.sh` needs no change: no new secret, the new params are
  in the env files, and it already deploys rules and indexes.

### InstaPay findings (sources)

- **Address format.** The Instant Payment Address is "presented in the
  form of name@instapay", and "cannot be changed once created" in the
  InstaPay app: InstaPay FAQs published by member banks of the Instant
  Payment Network, read 14 Nov 2026:
  Bank ABC Egypt,
  https://www.bank-abc.com/en/CountrySites/Egypt/Ways-to-our-Bank/Pages/InstaPay.aspx
  and ABK Egypt,
  https://www.abkegypt.com/-/media/Files/ContentPage/DigitalBanking/WaysToBank/InstantPaymentIPN/FAQs-Final-En.ashx
  (HSBC Egypt's FAQ describes the IPA the same way without the format:
  https://www.egypt.hsbc.com/ways-to-bank/instant-payment-network/faqs).
  I found **no official page with the allowed characters or length** of
  the name. The app therefore checks the shape only: Latin letters,
  digits, dot, hyphen and underscore, starting with a letter or digit, 3
  to 50 characters, then `@instapay`, stored in lower case. If a real
  address is refused in the pilot, the rule is one regular expression on
  each side (`functions/src/settle_up/model.ts`,
  `lib/features/settle_up/settle_up_models.dart`).
- **Link or URL scheme.** None verified, so the app uses Copy only and
  opens nothing. InstaPay's own share links look like
  `https://ipn.eg/S/<name>/instapay/<code>`; the only description I found
  is an unofficial community package (https://pypi.org/project/instapay-eg/),
  which says the link comes from the InstaPay app's share sheet and shows
  no way to build one from an address and an amount. No scheme was
  invented. `url_launcher` is not used by Settle up.

### Not built

- Hiding the admin panel's Wallet menu and the wallet row on the admin
  user page when the wallet is off (they show "This feature is switched
  off"); open-items D21.
- Paging of settle-up records on the phone beyond the newest 100 (D22).
- No emulator seed data for Settle up; test with two accounts
  (docs/test-iphone.md section 9).
- `CLAUDE.md` is not changed (it still says F1 to F44 and describes the
  wallet as the payment feature); the owner updates the rules file (D20).
- No package was added or bumped.

### Test status (honest)

- **Functions unit tests: run here, 748 pass, 0 fail**
  (`npm run build` then `node --test "lib/test/*.test.js"`; the build
  prints the known type-stub errors of this workspace and still emits).
  New: `test/features.test.ts` (switch document, cache, every gated entry
  point refuses or does nothing, dispatcher, admin toggle, deletion and
  export with no wallet), `test/settle_up.test.ts` (address format and
  privacy, create, idempotency, limits, membership, the whole state
  machine, notifications, reports, the switch, admin view, deletion and
  retention), additions in `test/trust.test.ts`, `test/privacy.test.ts`
  and `test/scrub.test.ts`. The gated-entry-point test calls the handlers
  through the local stubs of firebase-functions; with the real package it
  uses each function's `run`.
- **Rules tests: written, not run here** (`tests/rules/features.test.ts`).
- **Flutter analyze, widget, golden and one-line tests: written, not run
  here** (no Flutter SDK): `test/feature_switches/`, `test/settle_up/`,
  `test/admin/admin_settings_test.dart`, additions to the carpool,
  notification, privacy, scrubber and screenshot tests. I checked by
  script that every string key exists in both ARB files with matching
  placeholders, imports are sorted and used, and brackets balance; a
  first CI run may still show small analyzer or test fixes.
- **Screenshots: not produced here.** The golden names are
  `settle_<screen>_<ar|en>_<light|dark>.png` and `admin_settings_*.png`
  (CI screenshots workflow).

### How to test on the iPhone

docs/test-iphone.md section 9 (Settle up, two accounts) and 9b (feature
switches from the admin panel). The functions, rules and indexes must be
deployed to staging first (the setup script's step 11).

### Open questions for the owner

1. Settle-up records are kept while either parent's account is active
   plus 1 year: confirm the period and add it to the published privacy
   policy (open-items B7). The licence question is closed (the lawyer
   confirmed none is needed).
2. Limits: EGP 5,000 per request, 20 new requests a day, 10 unfinished
   between two parents, Report after 2 "Not received" (B8). Change?
3. Should a payee be able to paste their own InstaPay share link next to
   the address (B9)?
4. "Blocked" is read as: suspended or banned accounts, and two parents who
   blocked each other in chat. The refusal says only "you cannot create a
   request with this parent". Agree?
5. When one parent deletes the account, the short note of their records is
   removed for both sides (it is the two parents' own words). Agree?
6. With the wallet off, admins still see the Wallet menu (it says the
   feature is off). Hide it (D21)?
7. `CLAUDE.md` wording for F45 and the switches (D20).
