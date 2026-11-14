# Prompt 7 review: Schedule, swaps and absences (F7, F11, F27, F28, F30, F37)

Branch `prompt-07-schedule`, head `3cf6274`. Reviewed diff:
`git diff prompt-06-carpools...HEAD` (42 files). Validator, 14 Nov 2026.

## Verdict: CHANGES NEEDED

Most of the work is solid. Every schedule write goes through a Cloud
Function and runs in one transaction that reads everything before it
writes. Rules give read access to approved, verified members only, and
`scheduleEvents` is closed to everyone. Cairo time handling is correct
across both daylight saving changes. The cut-off never assigns a driver
who has not confirmed. `checkArrangement` now runs with the driver's car
and account read again inside the transaction on every assignment path.

Three things block the merge:
- The Android build in CI did not finish.
- A time change can put the confirm-by time after the run starts, so the
  "no driver" alert comes too late.
- The fair-share calculation in the rotation is wrong when a family
  joins mid-term or a member cannot drive.

## CI

Run 43531916220 on `3cf6274`:

| Job | Result |
| --- | --- |
| Flutter analyze, tests and screenshots | success |
| Cloud Functions tests and rules tests (emulators) | success |
| Web, admin panel and Android compile (staging) | **cancelled**: "The job has exceeded the maximum execution time of 30m0s" during "Build Android APK". Web and the admin panel built. |

The two earlier runs on this branch (`9097cb5`, `54fe54c`) were also
cancelled. The same job on `main` (`be647b2`, same time window) passed in
17.5 minutes. Prompt 7 adds no new plugin, so a slow runner is the likely
cause, but no green run of this job exists.

What I ran here (read-only, outside the worktree): Node checks against
`schedule/model.ts` and `cairo.ts`, transpiled to `/tmp`. I did not run
Flutter.

## Blocking

1. **CI: the Android compile job has no green run** (`.github/workflows`,
   job `builds`, `timeout-minutes: 30`). CLAUDE.md says Android must keep
   compiling in CI. Fix: re-run the job. If it times out again, raise
   `timeout-minutes` (for example to 45) or cache Gradle. Get a green
   "Web, admin panel and Android compile" job on the final head.

2. **A time change does not move the confirm-by time, so the missed-run
   alert can come after the run has started.**
   `functions/src/schedule/flow.ts:500-502`: `reconcile` updates `time` and
   `startMs` but keeps `confirmByMs`.
   - Example: a run planned on the same day, or released by a swap that
     morning, has `confirmBy = start - 60 min`. Take a 14:00 run with
     `confirmBy` 13:00. The admin adds an early dismissal at 11:00.
   - What happens: at 11:00 the run starts while it is still `planned` or
     `open`. The driver can no longer confirm, because `isLive` is false.
     The tick only marks the run `missed` at 13:00, and only then does
     every parent get the critical "take your own child" alert, two hours
     after pickup. That breaks the spec section 6 backups rule.
   - Fix: for `planned` and `open` runs in `reconcile`, recompute the
     deadline. Set `confirmByMs = min(old, newStart - lateLeadMin)`, or use
     `confirmDeadline`. When that time has already passed, mark the run
     missed and send the critical `no-driver` event in the same
     transaction, as `releaseRun` does.
   - Also skip, or mark missed, a `confirmed` run whose new start is
     already past. Today the tick would count it as `completed` (see
     non-blocking 7).
   - Add a unit test for an early dismissal on a late-deadline run.

3. **Rotation fairness is wrong for new members and for members who
   cannot drive.** `functions/src/schedule/model.ts:283-287` (`driveDebts`)
   and `:453`, used the same way in `leastDrivenFirst` (`:290-295`) and
   the app's `driveDebts` (`lib/features/schedule/schedule_logic.dart:91-100`).
   Each family's fair share is its share of all the runs driven this
   term, counted over every member. Simulated with the real `proposeWeek`,
   with each week's runs counted as completed:
   - **New member mid-term.** Families A and B drive 5/5 for four weeks.
     Then N joins (1 child, all days, consents done). N gets **all 20
     runs in weeks 5 and 6**, every morning and afternoon, because N is
     "behind" by a third of the whole term's history. Joining in week 10
     would mean about six weeks of driving every run.
   - **A member who cannot drive** (no car, or consents not done yet)
     still takes a fair share. That changes the split between the
     drivers. With 1 child against 2 children, plus a non-driving family
     with 3 children, 20 weeks give **83:117 (1:1.4) instead of 1:2**. This
     happens in every carpool with a parent who does not drive.
   - The prompt asks for fair turns with uneven numbers of children. The
     1-against-2 case alone does give 34:66.
   - Fix: build the fair share up run by run. When a run counts in the
     balance (`addToBalance`), add `children_i / children on eligible
     driving families` to each eligible family's `share`. Store it in
     `balances/{term}.families[uid].share`, and use `debt = driven -
     share`. That gives new members a share only from the day they join,
     and families who cannot drive take no share. Add unit tests for
     "joins in week 5" and "one family has no car".

## Non-blocking

1. **Re-confirming after a time change** (owner question 2). A confirmed
   driver stays confirmed when Ramadan times or an early dismissal moves
   the run, and the only notice is a group `schedule-changed` event with
   no run ID. Until the owner answers, send a `schedule-changed` event per
   run to its driver. Consider asking the driver to confirm again when the
   time moves by more than about 30 minutes.
2. **Planning several weeks ahead adds up unevenly.** `proposeWeek` counts
   only completed runs (the balance) and this week's confirmed runs.
   Planned or confirmed runs in other weeks are not counted. Planning 3
   weeks on one day with three 1-child families gives 12/9/9, because the
   uid tie-break sends the odd run to the same family every week. It
   corrects itself as runs complete. Pass the planned and confirmed runs
   of the other plannable weeks into `driven`.
3. **New members' children block the whole week until consents are
   done.** Planning puts every member's children on every run
   (`ridersOf`). If a new parent has not yet accepted any driver, no
   driver passes `checkArrangement`. Every run becomes "Needs driver", is
   missed at 21:00, and sends critical alerts to everyone. Even planned
   runs that already had a driver lose it on re-plan. This is safe but
   harsh. Consider leaving such children off the riders list until their
   parent has accepted the drivers, and showing "Waiting for consent".
   Alternatively, tell the admin why the runs are open.
4. **Car validity is checked against today, not the run date**
   (`runProblem(..., cairoDate(nowMs))` in `confirmRun`, `takeRun`,
   `planWeek`). A licence that expires on Friday still passes on Thursday
   for Saturday's run. Pass `run.date`.
5. **Confirmed runs are not released when the driver's car expires or the
   account is suspended.** Only leaving and consent withdrawal release
   them. This belongs with the urgent-report pause from spec section 6.
   Record it for Prompt 11 or 12.
6. **The balance term for the plan.** `planWeek` reads
   `termOf(today)`. Planning the first week of February in late January
   uses the old term's balance. Use `termOf(weekStart)`.
7. **A time change into the past** on a confirmed run lets the tick count
   it as `completed` (see Blocking 2).
8. **Event fan-out.** One consent withdrawal or one leave can write up to
   about 50 `driver-unavailable` events (one per run, five weeks). Prompt
   8's sender should group them by carpool and recipient.
9. **The tick** handles at most 200 due runs and 200 finished runs per
   15 minutes, in sequence. That is fine at pilot size. The cost is about
   5.8k reads a month for empty queries, and `minInstances` comes from
   `MIN_INSTANCES` (0). Log when a page is full, so a backlog is visible.
10. **The data model differs from spec section 9.** The spec has
    top-level "Schedule entry" records with status planned, swapped,
    completed or missed. The code uses `carpools/{id}/schedule` with
    `swapped` as a flag and adds `confirmed`, `open` and `cancelled`.
    `deny_all.test.ts` still lists `scheduleEntries/e1`. Record the change
    in `docs/DECISIONS.md` or update section 9.
11. **Items carried from the Prompt 6 review:**
    - Done: 1 (checkArrangement for every driver, the creator included,
      with the car and account read again in the transaction), 5, 6, 9
      and 10.
    - Partly done: 2. Runs check the driver's current car, but
      `carpool.seats` is never lowered, so search can still advertise
      seats that do not exist.
    - Still open: 3 (`searchCarpools` with `parentUid`) and 8 (membership
      limits checked outside the transaction).
    - Planned: 7 belongs to Prompt 11.
12. **App: the week and the confirm-by text use the phone's time zone**
    (decision 7, `deadlineText` uses `toLocal()`). This is fine for
    Egypt. Label it "Cairo time" if parents travel.

## Checked and fine

- **Transactions.**
  - Two parents accepting the same swap: both read the run, one wins,
    the other gets `run-taken` (tested).
  - Confirming against the cut-off: `confirmRun` rejects at
    `now >= confirmBy` inside its transaction. The tick re-reads the
    status and `confirmBy` in its own transaction, and both touch the
    same document.
  - Taking a run against a child coming back: both re-read the run.
  - Writes are buffered until all reads are done.
- **Never assigns a driver who has not confirmed.**
  - The plan only proposes (`planned`).
  - Taking a run, or taking it back after a confirmed swap, is the
    driver's own confirmation.
  - At the cut-off the tick removes the proposed driver, expires the swap
    and sends a critical event to every member.
  - A late release past the deadline is marked missed at once.
- **checkArrangement on every path**, with the car and account read
  again: plan (all members, and the member copy is refreshed), driving
  days (`driverStatus`), confirm, swap suggestions, take back, take, and a
  child coming back. Leaving and consent withdrawal release the affected
  future runs.
- **Cairo time.** Checked in Node:
  - 07:30 is 05:30Z in winter and 04:30Z in summer.
  - A deadline on the evening before uses that evening's offset. For a
    run on Sat 25 Apr, Fri 21:00 local is 18:00Z. For Fri 30 Oct (the
    evening before the clocks go back), it is 18:00Z. For Sat 31 Oct, it
    is 19:00Z.
  - Times in the spring gap resolve to the later offset, as the doc says.
  - Ramadan ranges (up to 60 days) and a later early dismissal inside one
    work (the latest change wins). No school beats new times.
- **Exceptions:** saving and removing are for the group admin only,
  checked on the server. The app shows the controls to the admin only.
- **Child absent:** only the parent's own approved child, live runs only.
  The driver and group get an event. Bringing a child back re-checks
  seats and consent.
- **Rules:** members-only reads, requested, declined, left or forged
  memberships rejected, the verified claim required, no cross-carpool
  collection-group reads, no app writes. `scheduleEvents` is closed, and
  `deny_all` has the new paths.
- **Events** hold only IDs (no names or text) and expire after 30 days
  (TTL field).
- **Indexes:** `(status, confirmBy)` and `(status, startAt)` on the
  `schedule` collection group.
- **UTC handling:** the server stores Timestamps, and the app parses them
  with `toUtc()`.
- **Labels and design:**
  - Run rows use the time as the title, with the badge beside it.
  - Status badge words are short.
  - Driver actions are large buttons with one primary action, and a
    confirmation is asked before Can't drive, Take and Remove.
  - Every screen has skeleton, empty, error and offline states.
  - The one-line tests at 320 dp in AR and EN (x1 and x2) passed in CI.
- **ARB:** the same keys in AR and EN, with no empty values and no bidi
  control characters.

## Done-when coverage

| Item | Status |
| --- | --- |
| This week's plan with a driver for each run | Covered (Plan the week, Week plan screen, emulator script steps 2 to 4) |
| Swap one run with the second fake parent | Covered: Can't drive in the app, then `carpool:emulator -- take` as Hoda (step 5) |
| Mark a child absent | Covered (Away switch in the run sheet) |
| Add a holiday | Covered (Days off and times, two steps) |
| Unit tests for rotation and swaps, including uneven numbers of children | Present and passing in CI (1 and 2 children; 4/3/3; two accepts at once). They miss the new-member and non-driver cases (Blocking 3). |
| On the iPhone | Not verifiable here. The iOS build is not part of this CI run. |
