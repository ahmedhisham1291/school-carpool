# Prompt 11: Trust and yearly checks (F17) — progress note

Branch: `prompt-11-trust` (from `main` with Prompts 1 to 10 and 11B).
Date: 14 Nov 2026. The coordinator gave "go" on the owner's behalf.

**Status: code complete. Functions unit tests were run here (569 pass, 30
of them new for trust; Node 22 with stand-in type stubs as before; `tsc`
shows only the known stub gaps). The Flutter code, the logic, widget,
one-line, admin and screenshot tests and the rules tests were written,
not run here** (no Flutter SDK or npm registry in this workspace; the rules
tests were type-checked against a stub). Expect small analyzer fixes on
the first CI run.

## Plan that was followed

1. Server (`functions/src/trust/`): pure rules (`model.ts`), flows over a
   `TrustStore` (`flow.ts`), carpool effects (`carpools.ts`), the daily job
   and triggers (`jobs.ts`), the phone change (`phone.ts`), the Firestore
   store, callables; small changes in the carpool, schedule, verification,
   map, auth and notification modules (below).
2. Rules (new collections closed, storage path for the phone-change
   selfie), indexes, emulator rules tests, deny-all paths.
3. App (`lib/features/trust/`): repository over callables, Rate parents,
   Family links, School year, Change number, Profile rows and banner,
   papers notice on Driving, "Rate this trip" on a finished run, linked
   children in the join sheet, notification kinds, strings AR/EN, the star
   rating component (gallery first), tests.
4. Admin panel: Trust page (guardian links to review, rating flags), the
   suspend dialog says the driver's days open for the group.
5. Test-data commands, SETUP.md section 22, docs/COSTS.md.

## What it does

- **Ratings and vouching (F17).** Only between parents who shared a
  FINISHED trip (Prompt 10 `trips`, status `ended`) in the last 30 days:
  the driver and each parent whose child was carried (dropped or
  received; an absent child does not count; two parents on one run are
  not a pair). 1 to 5 stars, fixed tags (on time, safe driving, friendly,
  clear; late, unsafe driving, rude), and "I vouch" (only with 4+ stars and
  no concern). **One rating per pair per month** (record ID
  `{YYYY-MM}_{rater}_{ratee}`, created in a transaction). No free text.
  Two stars or less, or "unsafe driving", create a rating flag for the
  admins. A parent sees their own summary; the average shows from 3
  ratings; another parent's summary only for members of a shared carpool
  (`getTrustSummary`).
- **Who may drive.** Unchanged rule of Prompt 7 (`checkArrangement` with
  the car and account read in the transaction): only a verified parent with
  an approved car and valid papers, with every other parent's consent.
  A spouse verifies separately and is **linked to the same children**:
  - the spouse asks with the other parent's **parent ID** and the relation
    (father, mother, guardian); the children's parent picks the children
    and accepts (or declines); **an admin reviews** a "guardian" link, or
    a child who already has another linked adult; at most two linked
    adults per child;
  - a linked child counts as the spouse's child on the server (carpool
    pickers, join, school groups and the map); the app's join sheet offers
    linked children; a child is in a carpool once (`child-in-carpool`);
  - either parent removes a link: the child leaves the spouse's carpools,
    and a spouse with no child left in a carpool leaves it (chat too).
- **Papers.** `trustDaily` (08:10 Cairo) reminds the driver 30, 7 and 1
  days before the earlier of the licence and car licence expiry (fixed
  event IDs, never twice), then "papers expired". Runs after the last valid
  day lose the driver (open, "driver unavailable"); planning, confirming
  and taking already refuse `car-expired` (Prompt 7, run date). Driving
  shows "Your papers expire in N days" / "expired".
- **Suspended or banned driver.** `releaseRunsOnUserBlock` (users write):
  on the change into suspended or banned, Prompt 9's pause release opens
  every future run they drive; the group hears only "driver unavailable"
  (closes Prompt 7 review item 5).
- **Re-verification of the car.** New driver details for the SAME car
  (same plate, e.g. a renewed licence) keep the approved car usable while
  the reviewer decides (`vehicles/{uid}.approved`); a rejected renewal
  keeps it, a withdrawn one restores it. A NEW car (other plate) gives no
  driving days until it is approved (seats and licences checked).
  `recheckRunsOnVehicleWrite`: when the usable car changes, members' car
  copies follow, runs the car cannot carry (gone, expired before the run,
  too many children) are released, and the creator's carpool seats come
  down to the new car (never below the children in it) — closes Prompt 6
  review item 2.
- **Re-verification of the phone.** Profile > Phone > new number (WhatsApp
  code with the sign-in limits, its own key so sign-in codes never work
  here) > code > live selfie matched to the face reference kept at
  approval. Then Firebase Auth and the account change, with an audit entry
  (no number in it) and a "number changed" notice. Mismatch: refused and a
  report for the admins; check unavailable: refused, try later. The selfie
  is deleted on every path.
- **Yearly check.** From 21 days before `SCHOOL_YEAR_START` (1 Sep) to 14
  days after it, verified parents with children confirm each child:
  "Stays" (new grade, next grade preselected) or "Left school". A child who
  left becomes `left`: it leaves the parent's and linked parents' carpools
  (and future pickup lists), its guardian links end, and the map and chat
  triggers take the school and area groups away; a parent left with no
  child in a carpool leaves it and its chat. Reminders on the opening day,
  the first day and the day before the deadline; after it, no new driving
  days (`users.yearCheckOverdue`) until the parent confirms. A parent
  verified after the check opened counts as done. Checks start with
  `YEAR_CHECK_FIRST_YEAR` (2027), so nobody is blocked at once.

## Data model (all writes by Cloud Functions)

| Record | Holds | Who reads |
| --- | --- | --- |
| `ratings/{YYYY-MM_rater_ratee}` | stars, tags, vouch, trip, carpool, time (append-only) | nobody (functions) |
| `trustSummaries/{uid}` | count, sum, voucher uids | nobody (via `getTrustSummary`) |
| `ratingFlags/{ratingId}` | low or unsafe ratings, status, outcome | admins via functions |
| `guardianRequests/{owner_guardian}` | relation, status, first name | nobody (via `getFamily`) |
| `guardianLinks/{child_guardian}` | child, owner, guardian, relation, status `review/active/rejected/removed` | nobody (via `getFamily`) |
| `trustLimits/{uid}` | rate limits | nobody |
| `users/{uid}` + `schoolYearConfirmed`, `yearCheckOverdue`, `phoneChangedAt` | yearly check, phone change | owner (as before; not writable) |
| `children/{id}.status` + `left` | yearly check | owner (as before) |
| `vehicles/{uid}.approved` | the approved car kept during a same-car renewal | owner (as before) |
| Storage `phoneChecks/{uid}/selfie.jpg` | live selfie of a phone change, deleted at once | upload by its verified owner only |

New notification types (server and app, same order): `licence-expiring`
(with the date), `licence-expired`, `year-check-due`,
`guardian-requested`, `guardian-linked`, `guardian-declined`,
`phone-changed`, in the new WhatsApp group "Papers and family" (off by
default, COST MODE).

## Screens and states

| Screen | Layout | Loading | Empty | Error | Offline |
| --- | --- | --- | --- | --- | --- |
| Rate parents (`/profile/ratings`) | Own rating card; rows "Hoda · Drove your child · date"; sheet: stars, tags, vouch switch, admin note for concerns, Send rating | Skeleton | "Nobody to rate" | Error view + retry; errors in the sheet | Offline view + retry |
| Family links (`/profile/family`) | Sentence, **Link to a parent** (sheet: parent ID checked as typed, relation chips, Send request); sections: requests for you (sheet: children check rows, Accept / Decline), your requests (Cancel), your children shared, shared with you (In review), remove asks first | Skeleton | Sentence, action and "No links yet" | Error view; errors in sheets | Offline view |
| School year (`/profile/school-year`) | "School year 2027/28", deadline or overdue warning, a card per child (Stays / Left school, new grade), **Confirm** (asks first when a child left) | Skeleton | "Nothing to confirm" | Error view; inline error | Offline view |
| Change number (`/profile/phone`) | Step bar; 1 new number + Send code; 2 code + Next / Use another number; 3 selfie; done | Button spinners | n/a | Inline error under the step (a used-up code returns to step 1) | Short offline message |
| Profile | School-year card (warning after the deadline); Phone row opens Change number; Rate parents and Family links rows | (rows show helpers) | — | rows still work | — |
| Driving | Papers soon / expired note in the car card | — | — | — | — |
| Live run | "Rate this trip" after the run ended | — | — | — | — |
| Admin > Trust (`/trust`) | Family links to review (Approve / Reject, asks first); rating flags (Close with an outcome; tap opens the rated parent) | Skeleton | Quiet lines | Error + retry | Offline + retry |

## Decisions (please confirm)

1. **Who rates whom:** the driver and the parents whose children were
   carried on a finished trip, both ways; not two passengers' parents.
2. **Ratings window 30 days**, one per pair per calendar month (Cairo).
3. **Ratings are private:** a parent sees their own; another parent's only
   inside a shared carpool, with the average from 3 ratings.
4. **Flags:** 1-2 stars or "unsafe driving" go to admins; ratings never
   pause a driver (Report does that, Prompt 9). The rating sheet says so.
5. **Guardian links:** the spouse asks, the children's parent accepts; an
   admin reviews only "guardian" links or a third adult. Linked children
   can be brought to carpools by the spouse; a child is in a carpool once.
6. **Same car, new papers:** the old approval stays usable until the
   reviewer decides; a new plate waits for review.
7. **Phone change only for verified parents** with a face reference;
   others sign in with the new number (new account) or ask support.
8. **Yearly check from 2027-28** (`YEAR_CHECK_FIRST_YEAR=2027`), opening
   21 days before 1 Sep and closing 14 days after; overdue blocks new
   driving days only (not the app).
9. **A parent left with no child in a carpool leaves it** (and its chat)
   after a child left school or a link ended; the carpool's admin stays.

## How to test it on the iPhone (the "Done when" check)

SETUP.md section 22.4, step by step:
1. `carpool:emulator -- finishtrip <carpoolId> <runId> --as any`, then
   Profile > Rate parents > Hoda > stars > Send ("Thanks for rating").
2. `carpool:emulator -- expire <yesterday> --as seed-map-parent-1`: her runs
   after that day are open; taking or planning her refuses "car expired".
3. Admin panel > Users > Hoda > Suspend: her runs open in the carpool's
   schedule; the alert says only that the driver is unavailable.

## Tests

| Test | Status |
| --- | --- |
| `functions/test/trust.test.ts` (30): rating rules, shared trips, summary, guardian review rule, papers notices, invalid runs, school-year window/state/stages, answers, same-car approval; rate once per month (next month again), refusals (no trip, self, unverified, suspended, old trip), flags and admin resolve with audit, summary visibility; guardian request/accept/review/admin/decline/cancel, linked child joins once, link removal takes the child out and the parent leaves; yearly check (left child out of both parents' carpools, links end, empty parent leaves), daily reminders once, overdue and clearing, first year; papers reminders once, expired releases runs, fewer seats, new car, suspension opens runs once; phone change (code to the new number, own key, selfie match, same number, missing/old selfie, number taken, mismatch reported, no reference, check unavailable) | **Run here: pass** |
| All Functions unit tests | **Run here: 569 pass** |
| `tests/rules/trust.test.ts`, `deny_all.test.ts` paths, storage | Written, not run here; type-checked against a stub |
| `test/trust/trust_logic_test.dart` | Written, not run here |
| `test/trust/trust_screens_test.dart` (rate, concern, already rated, empty, offline; link request, wrong ID, accept with children, remove asks first, empty; year confirm with a left child, overdue, Profile banner and rows; phone change happy path and mismatch, Profile phone row; one line at 320 dp AR/EN x1/x2) | Written, not run here |
| `test/admin/admin_trust_test.dart` (lists, approve asks first, close a flag, open the parent, one line) | Written, not run here |
| `notification_logic_test.dart` updated (kinds in the server's order, routes) | Written, not run here |
| Screenshots `trust_rate`, `trust_family`, `trust_school_year`, `trust_phone` (AR/EN, light/dark) | Written, not run here (CI artifact) |

## Learned from earlier reviews

- Every write in a function; new collections closed and in `deny_all`;
  rules tests for the parents named in the records too.
- Fixed event IDs (daily reminders never twice), triggers act only on the
  change (a retried trigger frees nothing twice), limits on the server.
- Analyzer habits: imports sorted, `Override` from `misc.dart`, no
  redundant defaults, const outermost, no nullable receivers, no name
  clashes (`GuardianRelation`, `guardianRelationLabel` beside the trip
  handover `Relation`); tests use tall views, one ProviderScope shape,
  explicit dates; app and server notification kinds in the same order.

## Open questions for the owner

1. The decisions above (especially 3, 5, 8 and 9).
2. **Lawyer (DECISIONS.md, new data):** ratings (stars, tags, vouches)
   and guardian links are new personal data: add them to the privacy
   screen and the App Store answers; retention (proposal: ratings 2 years,
   links while active + 1 year).
3. **Phone change without a face reference** (parents verified before
   Prompt 10 kept no identity selfie): support process, or allow an admin
   review instead of the automatic match?
4. WhatsApp templates `cp_licence_*`, `cp_year_check`, `cp_guardian_*`,
   `cp_phone_changed` to submit to Meta (SETUP.md 22.3), or keep push only.

## Not done / known gaps

- Prompt 6 review item 7 (report path for the free-text activity label and
  contribution note): not in this prompt; still open.
- The create-carpool and "looking" pickers list only the parent's own
  children (linked children are offered in the join sheet only).
- A linked parent cannot edit the child, its handover list or its school
  (the children's parent does); the linked parent does not confirm the
  yearly check.
- Other parents' summaries are not shown in carpool screens yet (the
  function exists: `getTrustSummary`).
- Account deletion must also remove ratings, summaries, flags, links,
  requests and `trustLimits` (Prompt 12 list).
- Valify face match for the phone change (fake until the contract; the
  Valify stub answers "error", so phone changes wait for the contract in
  prod).
- Not verified here: `flutter analyze`, `flutter test`, the rules tests.

## CI fixes (run 43579130520)

- Admin rail: with the Trust page a super admin's rail (10 sections) was
  taller than an 800 px window; the rail now scrolls (fixed height from
  the number of sections, never less than the window).
- Family links: the "Your requests" row uses an icon button (Take back
  request) so the row fits at 320 dp and 200 percent text; English header
  "Shared by you" (fits 320 dp).
- Test: the sample parent ID had an "I", which parent IDs never contain.

