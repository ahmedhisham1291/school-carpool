# Prompt 10: Trips and live location (F15, F16, F20, F29, F33, F34, F35, F38, F41) — progress note

Branch: `prompt-10-trips` (from `main` with Prompts 1 to 8; chat, Prompt 9,
is on another branch and is not used). Date: 14 Nov 2026. The coordinator
gave "go" on the owner's behalf.

**Status: code complete, merged with main (Prompt 9 chat). Functions unit
tests were run here (480 pass after the merge; 40 of them for trips and the
driver photo). The Flutter code, the logic, widget, one-line and screenshot
tests and the rules tests were written, not run here** (no Flutter SDK or
npm registry in this workspace; Functions were compiled with `tsc` against
the stand-in type stubs as in earlier prompts, rules tests type-checked
against a stub). `tool/patch_native.py` was run twice on a fake generated
tree (iOS and Android output checked, idempotent). Expect small analyzer
fixes on the first CI run. `lib/features/trips/background_location_tracker.dart`
(the only file that calls flutter_background_geolocation) was checked
against the plugin's 5.9.2 source.

## Plan that was followed

1. Server (`functions/src/trips/`): pure rules (`model.ts`), flows over a
   `TripStore` (`flow.ts`), Firestore store, Routes provider (fake and
   Google), callables, the HTTPS upload endpoint and the minute tick.
2. Notification types for trips in the Prompt 8 catalog (one sender).
3. Rules, Storage rules, indexes and emulator rules tests.
4. App: LocationTracker interface (plugin + fake), repository, the
   driver's run screen, the parents' live run, handover list, emergency
   contact, emergencies, today's driver card; entry points in the run
   sheet, the carpool screen and Profile; strings AR/EN; gallery; tests.
5. Driver photo (F33, F38) as an optional capture in the driver details
   of verification, kept when the case is approved.
6. Native patches (iOS background modes and texts, Android licence), docs.

## Data model (all writes by Cloud Functions)

| Record | Holds | Who reads (firestore.rules) |
| --- | --- | --- |
| `trips/{carpoolId}_{runId}` | run, date, direction, driver and first name, car (model, color, plate), status (`active`, `handover`, `ended`), start and end, `viewerUids`, `childIds`, stops (child first name, parent, state `waiting/arrived/onBoard/dropped/received/absent`, Arrived taps, times, handover names and relations), last point (cleared when tracking stops), stale alert time, token hash, quick messages, applied request IDs | `verified` and in `viewerUids` (the driver and the parents of the children on THAT run) |
| `trips/{id}/points/{id}` | lat, lng, accuracy, speed, heading, time, `expiresAt` (12 h) | same people, and only while `status == active` |
| `trips/{id}/eta/{parentUid}` | arrival per child of that parent | that parent and the driver |
| `tripStops/{id}` | EXACT stop points (shared pickup point or home; school or activity place) | nobody (Functions only) |
| `tripChecks/{id}` | selfie check of the run: `none/required/passed/failed/error` | its driver |
| `handoverAdults/{childId}` | owner, adults (name, relation, optional phone) | the child's parent |
| `emergencyContacts/{uid}` | name, E.164 phone, relation | the parent |
| `carpools/{id}/emergencies/{id}` | driver, run, point, time, `expiresAt` (24 h) | approved members of the carpool |
| `users/{uid}.drivingPaused` | `{ at, reason }` after a failed selfie | (users doc as before) |
| `reports/{id}` | `reporterId: system`, `reason: selfie-mismatch / selfie-error`, `urgent` | the admin panel's reports queue |
| Storage `selfieChecks/{uid}/{tripId}.jpg` | live selfie, deleted right after the match | driver uploads only (no reads) |
| Storage `driverPhotos/{uid}/photo.jpg` | the approved driver photo | Functions only (15-minute signed links) |

## How it works

- **Start (F15).** Only the confirmed driver (run `confirmed`, or
  `completed` once the schedule tick counted it), from 1 h before to 3 h
  after the run's time, verified and not paused. The app first shows the
  explanation screen and asks for **Always**; without it no run starts.
  `startTrip` returns a 256-bit token for THIS trip only (stored as a
  SHA-256 hash, expires after 4 h or at the last drop-off). Starting again
  (app restarted) gives a new token; the old one stops working.
- **Live points.** flutter_background_geolocation posts each point itself
  to the `tripLocation` HTTPS function (Bearer token, `?trip=`), so points
  keep flowing with the phone locked and even when iOS pauses Flutter;
  points not sent yet wait on the phone. The server keeps only points
  inside the trip's time, at least 4 s apart, accuracy under 500 m. The
  plugin: high accuracy, a point every ~10 m of movement (5 to 10 s at
  town speeds), a heartbeat fix every 60 s while waiting, stop detection
  off during a run, hard stop after 240 minutes. A `410` answer (run over)
  stops the plugin and clears unsent points; the tracker listens from app
  start, so this works even if the driver never reopens the screen.
- **Never outside a run.** The tracker starts only from the driver screen
  after `startTrip`; it stops when the trip is no longer active (last
  drop-off), on `410`/`401` from the server, and after 4 hours by itself.
  The website and tests use the fake tracker.
- **Arrival times.** One Routes request (traffic aware, legs' durations
  only) covers every stop ahead, at most once a minute per run, only while
  the run is tracked (COST MODE). Morning: homes not picked up yet, then
  school; afternoon: homes of children on board. Each parent gets only
  their own children's times. Exact points stay on the server.
- **Location stopped.** `tripTick` (every minute, minInstances 0) sends
  `location-stopped` (urgent: sound, ignores quiet hours, WhatsApp on by
  default) to the run's parents and the driver once when no point came for
  120 s; a new point re-arms it.
- **Stops (F16, F41).** Morning: Arrived (optional, repeatable) → Picked up
  → At school. Afternoon: Picked up at school → Arrived home (repeatable) →
  Handed over → the parent confirms. Each tap is a trip event and a
  notification to that child's parent; Arrived is urgent (sound) and goes
  to WhatsApp by default; each tap has a new event ID, so a second tap
  repeats it. Taps carry a request ID: an offline tap waits on the phone
  and is sent again with the same ID; the server applies it once.
- **Handover (F29, F34).** Parents keep a list of allowed adults per child
  (Profile > Who can receive); the driver sees names and relations on the
  afternoon stops (never phone numbers), updated on live trips at once.
  After the last afternoon drop-off the trip waits in `handover`; if the
  receiving parent does not confirm within 10 minutes, `child-not-confirmed`
  (critical, the Prompt 8 alarm and WhatsApp) goes to that parent and the
  driver. This is the producer Prompt 8 left for trips.
- **Quick buttons (F35).** Running late, At the gate, All children in: one
  tap, no typing, to the run's parents (same message at most every 2 min),
  and as a system message in the carpool chat.
- **Emergency (F20).** Asks first, then alerts every member of the carpool
  (critical) and sends the saved emergency contact a WhatsApp template with
  a Google Maps link to the car's point. The point goes only to the
  emergency record (members, 24 h) and that message; never to logs or push
  text. The group's Emergencies screen shows it on a map with "Call
  ambulance 123".
- **Today's driver card (F33).** `getTodayDriverCards`: approved members of
  the carpool, today only (Cairo date): first name, car model, color and
  plate, and a 15-minute link to the photo approved during verification.
- **Pause.** A failed selfie check uses Prompt 9's driving pause
  (`drivingPaused: true`, `pauseDriverRuns`), so the admin's "lift" clears
  it too.
- **Selfie check (F38).** For drivers with an approved photo, 20 percent of
  runs (decided once per run on the server, also when the app skips the
  prepare call) ask for a live selfie first. Match: start. Mismatch: the
  driver's driving is paused (`users.drivingPaused`; the schedule then
  treats the car as unusable for plan, confirm and take), every future run
  they drive is released the Prompt 7 way (open or missed with the critical
  alert; the group is told only that the driver is unavailable) and an
  urgent report goes to the admin queue. Provider error: the run may go
  on, a non-urgent report is filed. The selfie is deleted at once.

## Screens and states

| Screen | Layout | Loading | Empty | Error | Offline |
| --- | --- | --- | --- | --- | --- |
| Driver run (`/carpools/:id/trip/:runId/drive`) | Steps: location explanation + "Turn on location" (or Open Settings), quick selfie, ready (run, number of children, **Start run**). Running: location badge and "2 of 4 done", one large card per child (state, allowed adults in the afternoon, large Arrived / Picked up / At school / Handed over), Quick messages (3 large buttons), Emergency (danger, asks first). Done: "Run finished" | Skeleton cards | n/a | Error view + retry; inline refusals | Offline view + retry; taps queued with a count |
| Live run (`/carpools/:id/trip/:runId`) | Map with the car (while tracking), location badge, "Car in about 6 min" per own child, driver card, Open driver view (driver), **Child is home** (afternoon, asks first), children with states, driver's messages | Skeleton | "Not started" (also for parents not on the run) | Error view | Offline view; "Location stopped" warning; "sharing ended" note |
| Who can receive (`/profile/handover`, `/:childId`) | Children → adults (name, relation), Add adult (sheet: name, relation chips, optional phone, checked as typed), remove asks first | Skeleton rows | "Only you" | Error view | Offline view |
| Emergency contact (`/profile/emergency-contact`) | Intro, name, mobile, relation chips, Save; Remove contact (asks first) | Skeleton | Empty form | Error view | Offline view |
| Emergencies (`/carpools/:id/emergency`) | Card per alert: who, when, small map, Open in Maps; Call ambulance 123 | Skeleton | "No emergencies" | Error view | Offline view |
| Carpool detail | New "Today" section: driver cards (tap opens the live run), Emergencies row | Skeleton card | "Nobody drives today." | One quiet line | One quiet line |
| Run sheet | **Start run** (driver, today) or **Follow run** (parent with a child on it) | — | — | — | — |
| Driver details (verification) | New optional capture: Driver photo (front camera) | — | — | — | — |

## New package (CLAUDE.md rule 3)

- `flutter_background_geolocation: ^5.9.2` (latest tag, 29 Oct 2026) — in
  the STACK list ("Live location on the phone: flutter_background_geolocation
  (paid license)"). The tracker uses v5's compound config (`GeoConfig`,
  `AppConfig`, `HttpConfig`, `ActivityConfig`, `PersistenceConfig`), checked
  against the plugin's source at that tag. Debug builds need no licence;
  **v5 checks the new JWT licence on iPhone and Android release builds**
  (`BG_GEO_LICENSE`, SETUP.md 20.5): needed before the first TestFlight
  build with trips. CocoaPods needs static framework linkage (patched).

## Decisions

1. **Points through an HTTPS function with a per-trip token**, not
   Firestore writes from Dart: the plugin's native uploader keeps working
   when iOS suspends the Flutter engine, and only the run's driver ever
   holds a token for an active trip.
2. **One Routes request per minute per run** (all stops as waypoints)
   rather than one per stop: fewer calls, same freshness.
3. **The afternoon handover is two-sided; morning drop-offs at school are
   not** (the receiving side is the school; parents get "dropped off").
4. **Trip state lives in `trips/`**, not on the schedule run, so Prompt 7's
   status and drive balance stay as they are.
5. **Driver photo = an optional live photo in the driver details** of
   verification, approved by the reviewer and kept (other images are still
   deleted). It is the face reference of the selfie check; drivers without
   one get no selfie check and an initial on the card.
6. **Quick messages go to the run's parents as notifications and into the
   carpool chat** (after merging Prompt 9): a system message from the
   carpool system user with the driver's first name and the message in
   Arabic and English, a fixed message ID (no double post), no location,
   no Stream push (our sender already told the parents). A chat failure
   never fails the tap.
7. **Emergency contact gets a WhatsApp template** with a maps link; it is
   not an app user, so it is sent directly, not through the notification
   outbox.
8. **Points kept 12 hours** (deleted by the minute tick; TTL as backup),
   inside the 24-hour rule.

## How to test it on the iPhone (the "Done when" check)

SETUP.md section 20.6 step by step: start a run on the iPhone after
allowing Always, lock it, follow the car and the arrival time on a second
device (Simulator signed in as Hoda), Arrived / pickup / drop-off reach
her, Airplane mode for 2 minutes then `carpool:emulator -- triptick` sends
"Location stopped", another parent sees "Not started", and after the last
drop-off the status bar's location arrow goes and `carpool:emulator --
trip` shows `ended` with no new points.

## Tests

| Test | Status |
| --- | --- |
| `functions/test/trips.test.ts` (35): start rules, viewers (absent child's parent excluded), token stored as hash, restart rotates the token, paused / unverified / planned refused; selfie decided once, match, mismatch (pause, release, urgent report, selfie deleted), provider error, **start without prepare still asks**; upload format, point filters, wrong/other-trip token 401, after the run 410, **ETA at most once a minute and per parent only**, route order, Google request shape; Arrived to that parent with a new ID per tap (urgent + template), pickup/drop-off events, last drop-off stops tracking and clears the point, wrong order / other parents / retried request IDs; handover not confirmed in 10 min to both (critical, once), only the child's parent confirms; staleness rule, location stopped once and re-armed, forgotten run ends after 4 h, points deleted; quick messages and their rate; emergency to every member and the contact with a maps link, no coordinates in push text; handover list (owner only, no phones on trips); driver cards (members only, today only); release of a paused driver's runs | **Run here: pass** |
| `verification_flow.test.ts` (+3): driver photo kept on approval, not on rejection, optional | **Run here: pass** |
| `notifications.test.ts`: catalog (emergency critical, defaults on: no driver, child not confirmed, trip alerts, emergency) | **Run here: pass** |
| All Functions unit tests | **Run here: 419 pass** |
| `tests/rules/trips.test.ts`, `deny_all.test.ts` paths and Storage | Written, not run here; type-checked against a stub |
| `test/trips/trip_logic_test.dart`: start/follow windows, stop buttons, current stop, handover rule, staleness with UTC instants, minutes, request IDs, names, parsing, failures, fake tracker | Written, not run here |
| `test/trips/trip_screens_test.dart`: location explanation before any start, refused → Settings, selfie step, mismatch pauses, offline/paused on open, Arrived and repeat with new request IDs, last drop-off stops the tracker, afternoon handover names, offline tap sent again with the same ID, quick buttons, emergency asks first, 64 dp buttons; live run (map, arrival time, card, stale warning, finished, not on the run, confirm home); run sheet entry points; handover add/remove; emergency contact; emergencies; **one line at 320 dp AR/EN x1/x2** and every trip label | Written, not run here |
| `notification_logic_test.dart` updated (kinds, groups, routes) | Written, not run here |
| Screenshots `trips_drive`, `trips_live`, `trips_handover` (AR/EN, light/dark) | Written, not run here (CI artifact) |

## Learned from earlier reviews

- Every new collection has rules tests (other parents of the same carpool,
  absent child's parent, other carpools, left members, no claim, signed
  out, admin claim) and closed collections are in `deny_all.test.ts`.
- Limits counted on the server (starts, taps, selfie checks, emergencies,
  handover saves, contact changes, driver cards).
- Analyzer habits: private providers, explicit types, no redundant
  defaults, const literals; widget tests use tall views, explicit
  scrollables, one ProviderScope shape (the trip fakes and a fixed clock
  are part of `carpoolOverrides`), close fakes' streams, no pending timers.

## Open questions for the owner

1. **Selfie check on 20 percent of runs** (for drivers with a photo). OK, or
   another share? Should a driver without a photo be asked to add one
   before driving?
2. **Location stopped after 2 minutes** without a point. OK?
3. **Morning drop-offs at school** are one-sided (no parent confirmation).
   OK?
4. **Emergency contact by WhatsApp**: the contact is not an app user and
   never agreed to messages; the driver is asked to tell them. OK with the
   lawyer? Should the emergency also call the contact (no: the app cannot
   call by itself)?
5. **Driver photo kept** after approval (a new kept image of a face; the
   ID and selfie are still deleted). Spec F33 says the photo is approved
   during verification; please confirm with the lawyer (DECISIONS.md asks
   for a check when a new data type is kept).

## Not done / known gaps

- Swap requests as messages in the carpool chat (quick messages are
  posted since the Prompt 9 merge).
- Android: permission flow for "Allow all the time", the foreground
  notification text and the licence (Stage 3).
- Website: parents can follow a run (the live run screen works on the web
  with the Google map in Stage 2); drivers cannot start runs there (spec).
- Valify face match for the selfie check (stub answers "error" until the
  contract: the run goes on and an admin is told).
- Lifting a pause after a selfie mismatch uses Prompt 9's lift path
  (`drivingPaused` cleared); the report reason is `selfie-mismatch`.
- Battery test on low-end phones (spec section 11) needs real devices.
- Account deletion must also remove `handoverAdults`, `emergencyContacts`,
  `tripLimits` and the driver photo (Prompt 12 list).
- Not verified here: `flutter analyze`, `flutter test`, the rules tests,
  the iOS build with the new plugin.
