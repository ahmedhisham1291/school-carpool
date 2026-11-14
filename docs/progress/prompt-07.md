# Prompt 7: Schedule, swaps and absences (F7, F11, F27, F28, F30, F37) — progress note

Branch: `prompt-07-schedule` (from `prompt-06-carpools`, which is under
review, on top of `main` with Prompts 1 to 5). Date: 14 Nov 2026. The
coordinator gave "go" on the owner's behalf.

**Status: code complete, review fixes done (see "Review fixes" below).
Functions unit tests were run here (328 pass, 54 of them new; Prompt 6
fixes merged). The Flutter code, the widget, logic, one-line and screenshot
tests and the rules tests were written, not run here** (no Flutter SDK or
npm registry in this workspace). Expect small analyzer fixes on the first
CI run.

## Plan that was followed

1. Pure schedule model (`functions/src/schedule/model.ts`, `cairo.ts`):
   Cairo dates and DST-aware times, confirm-by deadlines, exceptions,
   rotation, drive balance.
2. Flows in one store transaction each (`schedule/flow.ts`): driving
   days, plan a week, confirm, swap request, take back, take (accept),
   child absent, exceptions, and the scheduled tick. Prompt 6's leave and
   consent-withdraw flows now release the affected runs (`release.ts`).
3. Firestore store, callables, `scheduleTick` (every 15 minutes,
   Africa/Cairo, `minInstances` from `MIN_INSTANCES` = 0), indexes, rules
   and emulator rules tests, the second-parent script commands.
4. App: week plan with a run sheet, driving days sheet, days off and
   times (two steps), drive balance; links on the carpool screen; strings
   AR/EN; gallery badges; tests and screenshots.

## Data model (all writes by Cloud Functions)

| Record | Holds | Who reads it (firestore.rules) |
| --- | --- | --- |
| `carpools/{id}/schedule/{date}_{am\|pm}` | One run: Cairo date, direction, time (after exceptions), start and confirm-by instants, status (`planned`, `confirmed`, `open`, `missed`, `cancelled`, `completed`), driver uid and first name, `fallback`, `swapped`, open `swapId` and `swapBy`, pickup list `riders` and `absent` (child id, first name, parent uid), week, term | Verified approved members of that carpool |
| `carpools/{id}/swaps/{swapId}` | F11: run, requester, previous status, status (`open`, `accepted`, `cancelled`, `expired`), accepted by, eligible members least-driven first | Same |
| `carpools/{id}/exceptions/{id}` | F30: kind (`noSchool`, `times`), reason (holiday, exams, early, ramadan, other), from and to (up to 60 days), new morning and afternoon times | Same |
| `carpools/{id}/balances/{termId}` | F37: per family first name, runs driven and received this term (`2026-t1` = Sep to Jan, `t2` = Feb to Aug) | Same |
| `scheduleEvents/{id}` | Alerts for Prompt 8's sender: type, carpool, run, date, direction, recipient uids, actor, child id, `critical`, status `pending`; IDs only (no names, no message text); TTL 30 days | Cloud Functions only |
| `memberships` / `members` `drivingDays` | Now set by members (F7) | Unchanged |

Indexes: collection group `schedule` (status, confirmBy) and (status, startAt).

## Rules the server enforces

- **One driver per run, never unconfirmed (spec section 6, backups):** the
  rotation only proposes (`planned`). A run has a confirmed driver only
  when that driver confirms (`confirmRun`) or takes it (`takeRun`, which is
  the confirmation). At the cut-off, the tick turns every `planned` or
  `open` run into `missed`, removes the proposed driver, expires the open
  swap and writes a critical `no-driver` alert to every member ("take your
  own child"). Nothing ever moves a run to another driver by itself.
- **Cut-off (F28):** the evening before at `SCHEDULE_CONFIRM_BY` (21:00
  Cairo). A run planned or released later (a swap asked on the morning)
  gets `SCHEDULE_LATE_LEAD_MIN` (60) minutes before it starts; when that
  has passed too, it is missed at once and the alert goes out.
- **Cairo time:** dates are Cairo dates; instants come from the
  Africa/Cairo ICU zone (DST from the last Friday of April to the last
  Thursday of October), so 07:30 is 05:30 UTC in winter and 04:30 UTC in
  summer, and an evening deadline before a change uses that evening's
  offset. Tested across both 2026 changes.
- **Rotation (F7, F37):** for each run in time order, candidates are the
  members who may carry every child on that run's pickup list (Prompt 6's
  `checkArrangement`: valid approved car, enough passenger seats, every
  parent's consent). Members who chose that weekday come first; a day
  nobody chose goes to every eligible member (Flow B, "the app proposes the
  remaining days"; marked `fallback`). The family with the largest deficit
  (fair share - runs driven) wins. Shares are built run by run for the
  families eligible for each run, in proportion to their children (see
  "Review fixes"), so uneven numbers of children are fair (1 and 2
  children: about 1:2), late joiners owe nothing for the past and families
  that cannot drive take no share. Ties: fewer runs that day, then uid. Confirmed runs are kept;
  planning again fills open runs and refreshes riders.
- **Driving days (F7):** carpool days only; choosing any needs
  `driverStatus().canDrive` (car, seats, every parent's consent), so a
  member is never offered runs they may not drive.
- **Swaps (F11):** only the run's driver asks; the run is open at once
  (no driver); members are alerted. Any eligible member except the
  requester takes it; the transaction re-checks status, cut-off, seats,
  car and consent, so two members accepting at once get one winner
  (`run-taken`). The requester can take it back while it is open.
  Suggested order: least driven first (stored for Prompt 8's alerts).
- **Child absent (F27):** a parent marks their own approved child away for
  the morning, afternoon or both runs of a date; the child moves from
  `riders` to `absent` and the driver and group get a `child-absent` event.
  Bringing a child back re-checks the driver (consent, seats). Started,
  missed and cancelled runs do not change.
- **Exceptions (F30):** the group admin only. No-school days cancel runs
  (and their open swaps); time changes (Ramadan ranges, one-off early
  dismissal) move run times, latest change wins, no-school beats times.
  Removing one reopens cancelled runs without a driver (plan again or
  take). Ranges up to 60 days, from yesterday to a year ahead, at most 60
  exceptions per carpool.
- **Drive balance (F37):** a confirmed run counts once its start time has
  passed (driven for the driver, received for each other family with a
  child on it). One transaction per run that checks the status again, so a
  retried or overlapping tick never counts twice.
- **Carpool changes:** a member who leaves leaves every future pickup list
  and their future runs lose their driver; a parent who withdraws consent
  from a driver releases that driver's future runs carrying their
  children. Both alert the group.
- **Every driver assignment re-checks the driver (Prompt 6 review,
  non-blocking 1 and 2):** plan, driving days, confirm, swap suggestions,
  take back, take and bringing a child back run `checkArrangement`
  (consent and seats) against the driver's car and account **read again
  inside the transaction** (`vehicles/{uid}`, `users/{uid}`), not the copy
  in `members`. The creator's days chosen at creation give no run until
  every other parent consents. A car re-verified with fewer seats or
  expired papers, or a suspended account, stops that member driving at
  once; planning refreshes the members' copy of the car. Seats per run are
  always checked against the driver's current car.
- **Limits:** 20 plans a day, 100 other schedule changes a day per parent.

## Screens and states

| Screen | Layout | Loading | Empty | Error | Offline |
| --- | --- | --- | --- | --- | --- |
| Week plan (`/carpools/:id/schedule`) | Chips This week / Next week; "You have N runs to confirm"; a section per day; a row per run (To school 07:30, driver and number of children, status badge); Plan the week (admin, primary), My driving days | Skeleton rows | "Not planned yet": admin gets Plan the week, members get My driving days | Error view + retry | Offline view + retry |
| Run sheet | Day and badge; driver; "Confirm by Sat 21:00"; fallback note; missed note; pickup list (away children marked); "Away: Adam" switch for the parent's own children; one large action: Confirm drive (plus Can't drive), Can't drive, I'll drive after all, or I'll drive it | n/a | "No children on this run" | Inline message (how to fix: consent, too late, taken) | Inline message |
| My driving days (sheet) | Day chips (carpool days only), Save | Button progress | n/a | Inline (for example "Every parent must accept you as a driver first.") | Inline |
| Days off and times (`/carpools/:id/exceptions`) | Rows: reason, dates, times or "No school"; admin: delete icon (asks first) and Add day off or time (primary) | Skeleton | "No days off or changes" (+ Add for the admin) | Error view | Offline view |
| Add day off or time (sheet) | Step 1 of 2: type and reason chips; step 2: From, To, new times ("As usual" or a time), Save / Back; checks range and times as the admin picks | Button progress | n/a | Inline per field and from the server | Inline |
| Drive balance (`/carpools/:id/balance`) | Intro (fair shares follow children); "This term"; a row per family "Drove 3 · Rode 5", "Drove least" badge | Skeleton | Families at zero with a note | Error view | Offline view |
| Carpool detail | New "Schedule" section for members: Week plan, Days off and times, Drive balance | — | — | — | — |

## Decisions

1. **Cut-off: 21:00 the evening before** (one setting per project), so
   "no driver for tomorrow" is known the night before. Late plans and
   morning swaps get one hour before the run.
2. **A time change asks a confirmed driver to confirm again** (Ramadan,
   early dismissal), with the confirm-by time moved before the new start;
   with less than an hour left the driver stays confirmed and gets a
   critical notice. (Changed after review.)
3. **New members ride from the next plan:** riders are refreshed when the
   admin plans again (confirmed runs keep their list), because each driver
   needs the new parent's consent first.
4. **Week = Saturday to Friday; school days come from the carpool's days.**
   The admin plans this week and up to three ahead.
5. **A run is "completed" when its start time passes with a confirmed
   driver** (for the balance). Trip tracking (later prompt) can refine this
   to the real drop-off.
6. **Alerts are events only** (`scheduleEvents`, status `pending`); Prompt 8
   sends them (push, and WhatsApp for critical ones). The schedule never
   blocks on sending.
7. **The app uses the phone's calendar day** for "this week"; parents are
   in Egypt, and every deadline is decided by the server in Cairo time.
8. No new dependency, service or tool.

## How to test it on the iPhone (the "Done when" check)

1. Emulators and seed as in Prompt 6 (`firebase emulators:start --project
   demo-school-carpool`, `npm --prefix functions run seed:emulator`), dev
   app on the iPhone with `--dart-define=EMULATOR_HOST=<Mac IP>`.
2. With your verified account and car, start a carpool (Prompt 6 steps
   4 to 7): Hoda joins, you approve, both accept each other as drivers:
   `npm --prefix functions run carpool:emulator -- consent <id> <your uid> --as seed-map-parent-1`
   and switch Hoda on under "Who drives my kids".
3. Hoda picks her days: `... carpool:emulator -- days <id> sun,mon,tue,wed,thu --as seed-map-parent-1`.
4. Carpool > **Week plan** > **Plan the week**. Every run shows a driver
   ("To confirm"). Tap one of yours > **Confirm drive**: the badge says
   Confirmed.
5. **Swap with the second parent:** tap one of your runs > **Can't drive**
   > Ask for swap (badge "Swap asked"). Hoda takes it:
   `... carpool:emulator -- take <id> <runId> --as seed-map-parent-1`
   (run IDs from `... -- runs <id> --as seed-map-parent-1`, for example
   `2026-11-16_am`). The run now shows Hoda, Confirmed.
6. **Mark a child absent:** tap a run > switch **Away: <child>** on. The
   child moves to "(away)" on the pickup list for both runs that day.
7. **Add a holiday:** Carpool > **Days off and times** > **Add day off or
   time** > No school, Holiday > Next > pick a day this week > Save. That
   day's runs show "No school". Try New times > Ramadan with new times too.
8. **Missed confirmation:** leave one of Hoda's runs unconfirmed, then
   after 21:00 (or set `SCHEDULE_CONFIRM_BY` earlier in
   `functions/.env.local`) run `... carpool:emulator -- tick --as any`: the
   run shows "Own trip" and the `scheduleEvents` collection (emulator UI)
   has a critical `no-driver` event for every member.
9. **Drive balance:** after a confirmed run's time, run the tick again;
   Carpool > **Drive balance** shows Drove/Rode per family.
10. Check Arabic and dark mode.

## Tests

| Test | Status |
| --- | --- |
| `functions/test/schedule.test.ts` (43): Cairo offsets and conversions across the April and October 2026 changes, deadlines on the evening before (DST), late deadlines, weeks and terms; exceptions (no school beats times, Ramadan range with a later early dismissal, no new runs); rotation (one proposed driver per run, never confirmed; 5/5; **uneven children 1 and 2**; **odd 4/3/3**; term balance; driving days and fallback; consent, seats and car; open runs; exceptions; kept confirmed runs; past runs); flows: driving days need consent, admin-only and plannable weeks, plan with riders and deadlines, re-plan keeps confirmed, confirm only by the driver and before the cut-off, consent withdrawal releases runs, missed runs alert everyone and assign nobody (idempotent), balance counted once, swap request and accept (events, suggested order), **two accepts at once**, seats and consent re-checked on take, take back, swap expiry, late swap deadline, child absent and back, started runs locked, holiday cancel and reopen, Ramadan times keep drivers, exception input checks, leaving releases runs, the Done-when flow | **Run here: pass** |
| All Functions unit tests | **Run here: 328 pass** (Node 22, `tsc` against stand-in type stubs as in earlier prompts; only the known stub gaps remain) |
| `tests/rules/schedule.test.ts`; `deny_all.test.ts` paths | Written, not run here (CI); type-checked against a stub |
| `test/schedule/schedule_logic_test.dart`: dates, run actions, grouping, own children, balance with uneven children, exception checks, parsing, server refusals | Written, not run here |
| `test/schedule/schedule_screens_test.dart`: week plan (statuses, to confirm, next week empty, admin plans), confirm, can't drive (asks first), take a swap (asks first), refusal inline, take back, no action on others' runs, missed run; child absent and back; driving days with refusal; offline and error; days off (member read-only, holiday in two steps, Ramadan times need a time, remove asks first); balance (badge, zero state); detail link; **one line at 320 dp in AR and EN at x1 and x2** for titles, buttons, chips, sections, badges, run rows and the absent switch, and every schedule label | Written, not run here |
| Screenshots `schedule_week`, `schedule_exceptions`, `schedule_balance` (AR/EN, light/dark) | Written, not run here (CI artifact) |

## Review fixes (docs/reviews/prompt-07-review.md)

- **Blocking 1 (Android CI timeout):** handled by the coordinator on `main`.
- **Blocking 2 (time changes and confirm-by):** `retimeRun`
  (`schedule/model.ts`), used by `reconcile`. Planned or open runs: the
  confirm-by time becomes min(old, new start - 60 min); when that has
  passed, the run is missed at once with the critical `no-driver` alert to
  every member (and its open swap expires). A new start in the past: missed
  at once, never counted as completed (non-blocking 7). A confirmed driver
  is asked to confirm again (status planned, driver kept, new confirm-by;
  `time-changed` event to the driver); with less than 60 minutes left the
  driver stays confirmed and gets a critical `time-changed` notice
  (non-blocking 1). Tests: early dismissal on the day (missed and
  alerted), deadline moved before the new start, re-confirm.
- **Blocking 3 (fairness):** `balances/{term}.families[uid].share` is
  built run by run: each completed run adds children / children of the
  eligible families to every family eligible for it (approved member then,
  a child on the run, able to drive it: car on the run date, seats,
  consent, account). The rotation proposes by deficit = share - driven
  (accrued the same way for this week's runs and for the other plannable
  weeks' planned and confirmed runs), ties by runs that day, then uid.
  Tests (simulated weeks with real `proposeWeek` and balance updates): a
  family joining in week 5 drives 3 or 4 of 10 runs a week and a third
  overall from then on; 1 child vs 2 children with a 3-child family that
  cannot drive gives 67:133 over 20 weeks (1:2); planning three weeks
  ahead on one day gives 10/10/10. The app orders the balance by driven -
  share and gives "Drove least" only to a driving family.
- **Non-blocking done:** 1 (re-confirm and per-run notice), 2 (other
  weeks count), 4 (car validity on the run date in plan, confirm, take,
  take back, swap suggestions, child back, balance), 6 (plan uses
  `termOf(weekStart)`), 7 (moved into the past = missed), 9 (the tick
  logs a warning when a page of 200 is full).
- **Non-blocking still open (later prompts or the owner):**
  - 3: a new member's children block runs until their parent accepts the
    drivers (safe, harsh). Option: leave them off the pickup list with
    "Waiting for consent", or tell the admin why runs are open. Owner
    question 6 below.
  - 5: confirmed runs are not released when a car expires or an account
    is suspended (confirm and take re-check; the plan drops them). Belongs
    with the urgent-report pause (Prompt 11 or 12).
  - 8: one leave or consent withdrawal can write many events; Prompt 8's
    sender should group them by carpool and recipient.
  - 10: the data model moved from spec section 9's top-level "Schedule
    entry" (planned, swapped, completed, missed) to
    `carpools/{id}/schedule` with `confirmed`, `open`, `cancelled` and a
    `swapped` flag. Owner question 7 below (record in DECISIONS.md or
    update section 9). `deny_all.test.ts` keeps `scheduleEntries/e1` as a
    closed path.
  - 11: from the Prompt 6 review, `carpool.seats` is never lowered when a
    car loses seats (runs always check the current car); `searchCarpools`
    with `parentUid` and membership limits outside the transaction remain.
  - 12: times use the phone's time zone; label "Cairo time" if parents
    travel.

## Learned from earlier reviews

- Every new collection has rules tests with forged, requested, declined
  and left memberships, missing claims, signed-out users and the admin
  claim; `scheduleEvents` closed to everyone; the app writes nothing.
- Limits on every write-like call, counted on the server.
- Concurrency: the accept race is tested; every check is inside the
  transaction that writes.
- Analyzer habits: private providers (no inferred public types), no
  redundant default arguments, const literals, imports sorted, no bidi
  literals; widget tests use tall views, `scrollUntilVisible` with an
  explicit scrollable, bring buttons fully on screen, and keep one
  ProviderScope shape (the schedule fake and a fixed clock are part of
  `carpoolOverrides`).

## Open questions for the owner

1. **Cut-off:** 21:00 the evening before, and one hour before the run for
   late changes. OK?
2. **Time changes ask the driver to confirm again** (review fix; with
   less than an hour left the driver stays confirmed and is told). OK?
3. **Who plans:** only the group admin plans the week. Should the plan
   happen automatically each Thursday instead (or as well)?
4. **Fair share by number of children** (a family with two children drives
   twice as often). OK, or one share per family?
5. **Terms:** September to January and February to August. Do your
   schools use other dates?
6. **New members before consent:** keep their children on every run
   (runs stay open until they accept the drivers), or leave them off the
   pickup list with "Waiting for consent"?
7. **Data model:** OK to record the schedule's per-carpool records and
   statuses (above) as a decision and update spec section 9?

## Not done / known gaps

- Sending the alerts (push and WhatsApp), reminders the evening before and
  one hour before, the in-app alarm for critical alerts: Prompt 8 reads
  `scheduleEvents`.
- Swap requests as messages in the carpool chat (Prompt 10).
- Trip tracking and "completed" on real drop-off (Phase 4).
- Today's trips on the Home tab; offline cache of today's pickup list
  (spec section 11) beyond Firestore's own cache.
- Urgent reports pausing a driver's days (spec section 6): later prompt;
  `releaseRun` is ready for it.
- Account deletion must also remove the parent from future runs and
  balances (Prompt 12, with the earlier lists).
- Not verified here: `flutter analyze`, `flutter test`, the rules tests,
  the iOS build.
