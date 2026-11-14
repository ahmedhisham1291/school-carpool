# Prompt 10 review: Trips and live location (F15, F16, F20, F29, F33, F34, F35, F38, F41)

Branch `prompt-10-trips`, head `3978d2c` (includes `main` with Prompts 1 to
9). I reviewed `git diff origin/main...HEAD` (71 files) against CLAUDE.md,
docs/spec.md (Flow C; section 6 Live location, Arrival time, Handover; F15,
F16, F20, F29, F33, F34, F35, F38, F41; section 7 location control and
retention), docs/build-prompts.md "Prompt 10" and its "Done when",
DECISIONS.md, DESIGN.md (driver rule), WORKFLOW.md and
docs/progress/prompt-10.md.

## Verdict: CHANGES NEEDED

There are six blocking items:

- CI did not finish green.
- Any verified parent can block a run's start, or skip its selfie check.
- Live selfies can stay in Storage with no deletion.
- A child who does not come leaves no way to end tracking.
- Tracking keeps going after sign-out or suspension.
- The selfie check is opt-out.

## CI

Run 43566808024 on `3978d2c`: **failed**.

| Job | Result |
| --- | --- |
| Cloud Functions tests and rules tests (emulators) | success |
| Flutter analyze, tests and screenshots | success |
| Web, admin panel and Android compile (staging) | **failure**: web and admin built; "Build Android APK" was cancelled at 06:52 with "The runner has received a shutdown signal" |

The failure looks like an infrastructure problem rather than a code error.
There was no Gradle error, and the job stopped well inside its 45-minute
limit. Still, this prompt adds a native plugin, and the Android compile with
flutter_background_geolocation 5.9.2 has not been shown to work. The two
earlier runs on this branch (`dc4e480`, `7a4bda2`) were cancelled.

I ran no compiler or tests here, because this workspace has no Flutter SDK.
I did not look at the screenshots. Nothing ran on a real iPhone: not the
plugin, the background modes, the heartbeat or the release licence.

## Blocking

1. **CI is not green.**
   - Where: run 43566808024, job "Web, admin panel and Android compile
     (staging)".
   - Fix: re-run the job and get all three jobs green on the head commit.
     If the Android step fails again, fix it. The new plugin's Gradle setup
     is the likely cause.

2. **The selfie check record is written before the caller is checked as
   the driver, so any verified parent can block a run's start or skip its
   check.**
   - Where:
     - `functions/src/trips/flow.ts:361-367`: `startTrip` calls
       `ensureCheck` with `driverUid: caller.uid`. The driver check
       (`startProblem` / `existing.driverUid`) only comes at lines 373-379.
     - `functions/src/trips/flow.ts:300`: `submitSelfieCheck` calls
       `ensureCheck(..., status: "required", driverUid: caller.uid)` with
       no run or driver check at all.
     - `ensureCheck` (`store.ts:343`) creates the record only once per
       trip ID.
   - Attack: a verified parent who knows `carpoolId` (visible in search)
     and the predictable run ID (`YYYY-MM-DD_am|pm`) calls
     `submitSelfieCheck` first. That stores `{driverUid: attacker, status:
     required}`. Then for the real driver:
     - `prepareTrip` says a selfie is needed.
     - `startTrip` answers `selfie-required`.
     - `submitSelfieCheck` answers `not-driver` (line 301).
     - The run can never start, so there is no live location and no
       alerts for that run.
   - The reverse also works: a caller with no driver photo calls
     `startTrip` first, which stores `status: "none"`, and the real driver
     then never gets the F38 check.
   - Legitimate case: a swap after `prepareTrip` hits the same problem,
     because the check stays tied to the first driver.
   - Fix:
     - Load the run and refuse anyone who is not `run.driverUid` before
       any `ensureCheck`, in `startTrip`, `submitSelfieCheck` and
       `prepareTrip`.
     - Key the check by trip and driver (`{tripId}_{uid}`), or decide again
       when the stored `driverUid` is not the run's driver.
     - Tests: a non-driver calling `startTrip` or `submitSelfieCheck` first
       changes nothing for the driver; after a swap, the new driver gets
       their own decision.

3. **Face images can stay in Storage with no deletion.**
   - Where: the app uploads `selfieChecks/{uid}/{tripId}.jpg` before the
     call (`lib/features/trips/trip_repository.dart:157-165`). But
     `submitSelfieCheck` deletes it only on the match path
     (`flow.ts:304-316`).
   - These paths leave the image behind:
     - the rate limit (`take`, line 298, before anything else);
     - `not-driver` (301);
     - status already `passed`/`none` (302) or `failed` (303);
     - `requireVerified` refusals;
     - the call failing or the phone going offline after the upload.
   - `storage.rules:36` also accepts any `{name}.jpg`, not only a real trip
     ID.
   - No job or lifecycle rule sweeps `selfieChecks/`. CLAUDE.md PRIVACY
     says selfie images "are deleted by the scheduled job".
   - Fix:
     - Delete the live file on every exit path (`try/finally` around the
       whole function).
     - Add a sweep of `selfieChecks/` objects older than 1 hour to
       `tripTick`, or a bucket lifecycle rule with the steps in SETUP.md.
     - Test: a rate-limited or refused submit leaves no file.

4. **A child who does not come (or a mistaken stop) keeps the driver
   tracked for up to 4 hours.**
   - Where:
     - `allDropped` (`functions/src/trips/model.ts:349`) is the only way
       tracking stops before the 4-hour cap (`flow.ts:751`).
     - `applyAction` has no "not coming" / skip action, and
       `lib/features/trips/trip_logic.dart:45-48` offers none.
     - Children marked absent after the start are not taken into the
       trip.
     - A run whose riders are all absent can still be started
       (`startProblem` does not check the riders). Nothing ever stops it
       before 4 hours.
   - Effect: a morning no-show means the driver's location (going on to
     work, and so on) stays visible to the run's parents for hours.
   - This breaks spec section 6: "from the start until the last child is
     dropped … off outside runs". It also breaks the prompt's "never runs
     outside a run", and it drains the battery.
   - Fix:
     - Add a large driver action "Not coming" (from `waiting`/`arrived`).
       It needs a confirmation, notifies that parent and counts as done in
       `allDropped`.
     - Or add an "End run" with a confirmation when no child is on board.
     - Refuse `startTrip` when there are no riders.
     - Tests for both.

5. **There is no stop on sign-out, account deletion or suspension.**
   - Where:
     - `lib/features/onboarding/sign_out.dart:29-36` unregisters push but
       never calls `locationTrackerProvider.stop()`.
     - `uploadPoints` (`flow.ts:656-683`) checks only the token and the
       trip status, never the driver's account.
     - Nothing in the Prompt 9 suspend, ban or pause paths ends the
       driver's live trips.
   - Effect: after the driver signs out (or another person signs in on the
     phone), or after an admin suspends or bans the driver, the plugin
     keeps posting with the stored token. Parents keep seeing that phone
     until the last drop-off, which can no longer be tapped, or until the
     4-hour cap.
   - Fix:
     - Stop the tracker (and `destroyLocations`) in `confirmAndSignOut` and
       in the forced sign-out path. Confirm first when a run is live.
     - On the server, refuse uploads (410) when the driver's account is
       not `verified` or the driver is banned. Also end or stop tracking
       of the driver's live trips from the suspend, ban and delete hooks,
       and alert the run's parents through `location-stopped`.
     - Tests for both.

6. **The F38 selfie check is opt-out.**
   - Where:
     - `selfieRequired` returns false without a reference
       (`model.ts:307-309`).
     - The driver photo is optional (`verification/submission.ts`
       `DRIVER_PHOTO_FILE`, "Optional").
     - Every driver verified before this prompt has no photo.
   - Effect: a driver who does not want checks just skips the photo, so
     the safeguard against someone else driving never runs. Spec F38 and
     the prompt ("Random live selfie check before some runs; a mismatch
     pauses driving") do not allow an opt-out.
   - Fix (choose one):
     - Make the driver photo required in the driver details. Ask drivers
       without one to add it before their next run: `startTrip` refuses
       with a clear "Add your driver photo" state, and there is a SETUP
       note for existing drivers.
     - Or have the owner explicitly accept the gap in DECISIONS.md. This
       is open question 1, and per CLAUDE.md it needs an answer before
       merge.

## What I checked (holds)

- **Start (F15):**
  - Only `run.driverUid`, with the run `confirmed`/`completed`, from 1 hour
    before to 3 hours after, verified (claim and record), not paused or
    suspended, and rate-limited (30 a day). The ordering problem above is
    the exception.
  - The app shows the explanation first and requires "Always". Without it
    the tracker refuses to start (`background_location_tracker.dart:128`).
- **Upload token:**
  - 256-bit random (`randomBytes(32)`), stored only as a SHA-256 hash, and
    compared with `timingSafeEqual`.
  - It works for one trip ID only: another run gets 401.
  - It expires at start plus 4 hours and is cut at once by `stopTracking`
    (`tokenExpiresAtMs = now`). After the run the answer is 410.
  - A restart rotates it and the old token gets 401 (tested).
  - It is sent in the `Authorization` header, not the URL, and is not
    logged.
  - On the phone it sits in the plugin's persisted HTTP config and is
    cleared on `stop()`.
- **Points:**
  - Accepted only while the trip is `active` and from that token. They
    must fall inside the trip's time (start minus 1 minute to now plus 1
    minute), be at least 4 s apart, have accuracy of 500 m or better, and
    come at most 50 per upload.
  - Firestore rules let only viewers read points, and only while the
    status is `active`. The trip's `last` point is cleared when tracking
    stops.
- **Readers:**
  - `viewerUids` = the driver plus the parents of riding children. The
    absent child's parent, other members, other carpools, left members, an
    admin claim and signed-out users are refused (rules tests).
  - The `eta/{parentUid}` doc is readable by that parent and the driver
    only. `tripStops` (exact points) is closed.
  - The app writes nothing: trips, points, ETAs and checks are all
    `write: false`, and `deny_all.test.ts` was updated.
- **Retention:**
  - Points expire after 12 hours (`expiresAt`, deleted by `tripTick`, 500
    per group per minute, with TTL as backup). ETAs and `tripStops` expire
    after 12 hours, and emergencies after 24 hours.
  - The collection-group `expiresAt` overrides are in
    `firestore.indexes.json`.
  - No coordinates go to logs (`deps.log` gets counts and reasons only),
    push or WhatsApp texts (`texts.ts`, tested with a regex), Sentry
    (`reportError` gets only server errors) or the chat system message
    (tested).
  - Points go only to the emergency record (members, 24 hours) and the
    emergency contact's WhatsApp message.
- **Arrival times (COST):**
  - One Routes `computeRoutes` call per trip, at most once a minute,
    decided inside the trip transaction (`etaDue`).
  - Only while active, with field mask `routes.legs.duration` and at most
    25 waypoints. Each parent gets only their own children's times.
  - The fake provider is refused in prod. COSTS.md was updated (Pro SKU,
    5,000 free).
- **Location stopped:**
  - Sent after 120 s without a point (setting bounded 30 to 900 s), once
    per gap and re-armed by the next point. It goes to the viewers and the
    driver as urgent (time-sensitive, ignores quiet hours, WhatsApp by
    default).
- **Pickup and drop-off (F16, F41):**
  - The state machine is checked per direction. Only the trip's driver can
    act, and absent stops have no actions.
  - Request IDs make a retry apply once. Each tap notifies that child's
    parent only.
  - Arrived repeats with a new event ID per tap (`childId_arrivedCount`).
- **Handover (F29, F34):**
  - Names and relations only go into trips; phone numbers stay in
    `handoverAdults` (owner-read) and are tested. Live trips update when the
    list changes.
  - After 10 minutes without a confirmation, `child-not-confirmed`
    (critical, the Prompt 8 alarm and WhatsApp) goes to that parent and the
    driver, once. This is the producer Prompt 8 was waiting for.
  - Only that child's parent can confirm.
- **Quick messages (F35):**
  - The run's driver only, while the trip is active, at most once per 2
    minutes per kind.
  - Posted into the carpool chat once: the request ID guards a retry, and
    there is a fixed message ID with 409 treated as done.
  - The message is the first name and text only, with no location and
    `skip_push`. A chat failure never fails the tap.
- **Emergency (F20):**
  - It asks first, is limited to 5 an hour, and only the trip's driver can
    send it.
  - Every approved member gets a critical alert, and the saved contact gets
    a WhatsApp template (first name and a maps link). Push text has no
    point.
  - The Emergencies screen offers "Call ambulance 123".
- **Selfie mismatch (F38):**
  - A mismatch sets Prompt 9's `drivingPaused`, releases future runs
    through `pauseDriverRuns` and files an urgent `selfie-mismatch` report.
  - A provider error lets the run go on with a non-urgent report. The share
    of runs is 20 % (setting bounded 0 to 100), decided once per trip.
- **Driver card (F33):**
  - Approved members only, today (Cairo date) only. The photo is a
    15-minute signed link, and Storage `driverPhotos/` is closed to the
    app.
- **Plugin config:**
  - High accuracy, a 10 m distance filter, `locationUpdateInterval` 5 s
    (Android), stop detection off, `preventSuspend` and a 60 s heartbeat
    (with `getCurrentPosition(persist)`) only while a trip is set, and
    `stopAfterElapsedMinutes: 240`.
  - `stopOnTerminate: false`, with 410/401 handled in `onHttp` from app
    start. `maxDaysToPersist: 1`, and `destroyLocations` on stop. The
    background indicator is on.
- **iOS:**
  - `patch_native.py` adds the `location`, `fetch` and `processing`
    background modes, `BGTaskSchedulerPermittedIdentifiers`, motion and
    Always location texts in Arabic and English, and static pod linkage.
  - The licence comes only from `BG_GEO_LICENSE` and is never committed.
- **Driver UI:**
  - No text fields on the driver screen. Buttons are `AppButtonSize.large`
    (64 dp, tested). Emergency is the danger variant at the end and asks
    first. Offline taps are queued with the same request ID.
- **ARB:** 1,431 keys in both files, and the placeholders match. The
  differences my script found were only Arabic plural words.
- **One-line labels:** trip labels use `OneLineText`, and the one-line test
  at 320 dp covers Arabic and English at x1 and x2 (written; CI green on
  the Flutter job).
- **Done when:**

  | Check | Covered by |
  | --- | --- |
  | Start with the phone locked, a second device sees the car and the arrival time | Plugin uploader plus the live run screen |
  | Arrived, pickup and drop-off reach the other parent | Unit tests |
  | Stopping location triggers the alert | Tick, tested |
  | A parent whose child is not on the run sees nothing | Rules test and widget test |
  | No more location after the run ends | 410, `stop()`, rules close points |

  Each one still needs the owner's iPhone run (SETUP.md 20.6), and items 4
  and 5 above leave gaps in the last row.

## Non-blocking

1. **Arrived has no per-stop limit.**
   - Up to 300 actions an hour per driver, and each Arrived tap is a paid
     WhatsApp template plus a time-sensitive push that ignores quiet hours.
   - Fix: a 30 to 60 s cooldown and about 5 Arrived alerts per stop
     (counted on the server), with the button showing "Sent" until then.
2. **There may be false "Location stopped" alerts while the car is not
   moving.**
   - With a 10 m distance filter and the plugin held in the moving state
     (`changePace(true)`, stop detection off), iOS sends no points while
     the car is stuck in traffic or waiting at a gate. Only the heartbeat
     fills the gap, and on iOS I could not confirm that the heartbeat fires
     in the moving state.
   - A false alert sends WhatsApp to every parent.
   - Test on the iPhone: car still for 3 minutes, phone locked.
   - If needed, raise `TRIP_STALE_SEC`, or have the server count
     heartbeat-only gaps differently.
3. **The licence rule conflicts with CLAUDE.md.**
   - CLAUDE.md COST MODE says "no license needed for debug or iOS". The
     agent says v5 needs it for iOS release builds too.
   - `codemagic.yaml` does not pass `BG_GEO_LICENSE`, so TestFlight builds
     would track unlicensed.
   - The owner should confirm with Transistor, then update CLAUDE.md,
     COSTS.md and the Codemagic variables.
4. **`viewerUids` is fixed at the start.**
   - A parent removed from the carpool, or whose child is marked absent,
     during the run keeps reading the trip and its points until it ends.
   - There is no rules test for "in `viewerUids` but no longer an approved
     member".
   - Fix: add `approvedMember(resource.data.carpoolId, uid)` to the trip and
     points rules, or recompute viewers on leave, removal or absence. Add a
     test.
5. **`prepareTrip` with an existing trip skips `startProblem`**
   (`flow.ts:274-276`), so any verified caller learns whether the trip is
   active and what its selfie state is. Check the driver first (this goes
   with blocking item 2).
6. **`tokenHash` is in the trip doc that viewers read.** That is harmless
   for a 256-bit token, but it is not needed. Move it to `tripStops` or
   another closed doc.
7. **Emergency is accepted after the trip has ended** (no status check)
   and uses the point the client sends. Limit it to `active`/`handover`
   trips, or to a short time after the end.
8. **Legal questions for the owner's lawyer** (DECISIONS.md asks for a
   check when a new data type is kept):
   - (a) The kept driver photo is a new face image with no retention
     limit. It must be deleted on account deletion and on a later
     rejection or ban; today that is only on the Prompt 12 list.
   - (b) The emergency contact is not a user and never agreed to messages.
     WhatsApp sends that person the driver's first name and the car's
     exact location.
   - (c) Live-location consent from the driver "in writing" (spec section
     7): the explanation screen is not a recorded consent. Add it to the
     consent register.
9. **Valify `matchFace` is a stub that answers "error".** In staging and
   prod, every selected run goes on and files a non-urgent report, so F38
   does nothing until the contract. Say so in COSTS.md and SETUP.md, and
   watch the size of the report queue.
10. **`tripLocation` has no App Check** (it can't, because the native
    uploader sends the requests). Every bogus request costs one Firestore
    transaction read. A cheap format and length check runs first already.
    Consider a per-IP limit or a plain read before the transaction.
11. **`BackgroundLocationTracker()` calls `ready()` at app start for every
    user.** Check on the iPhone that parents who never drive get no
    location or motion prompt at launch.
12. **Trip docs never expire.** They hold children's first names, handover
    names and stop times. Add them to the retention schedule (Prompt 12).
