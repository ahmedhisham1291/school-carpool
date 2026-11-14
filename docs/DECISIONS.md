# Owner decisions

Decisions the owner has confirmed. Build agents follow these; ask before changing one.

## Legal (confirmed by the owner's lawyer, 14 Nov 2026)

The owner reports that the lawyer confirmed all of the following are allowed without issues:

1. **Schools list licence (ODbL):** using the OpenStreetMap / HDX schools data with the
   attribution on the About screen.
2. **Operating entity and licence:** running the parent-to-parent carpool app.
3. **Hosting abroad:** storing the data in Google Cloud `europe-west1` (Belgium).
4. **IDs and children's data:** collecting national IDs, selfies, children's details and
   locations with the consent screens in the app, and keeping ID images up to 7 days after review.
5. **Wallet:** the wallet run by a payment partner licensed by the Central Bank of Egypt.
6. **Liability:** terms of use and code of conduct as planned.

Keep the lawyer's written answers with the company records. If a later prompt changes how any of
these work (for example a new data type, a longer retention period or a new country for hosting),
check with the lawyer again.

## Product and build

- Design: direction A (teal), refreshed; every label, button, tab, chip and title on one line.
- CI checks on GitHub Actions; Codemagic only for iPhone builds.
- Bundle ID base `org.schoolcarpool.app`; Firebase region `europe-west1`.
- Always choose the best service or technology for each job, even when it is paid. Never
  swap a chosen service for a cheaper or free alternative to save money (14 Nov 2026).
- Plans: start each chosen service on its free plan and move to the paid plan when usage
  reaches the free limit.
- `shared_preferences` approved.
- Algolia (14 Nov 2026): stay on the free plan while usage fits, then switch to the
  pay-as-you-go Grow plan ($0.50 per extra 1,000 searches). The free plan's limit is
  10,000 searches a month (not users), so watch the monthly search count in COSTS.md
  and switch when it nears the limit.

## Data retention and collection (owner, 14 Nov 2026)

The owner wants to keep all photos and collect more data, with storage optimized. This replaces
the earlier "delete ID images within 7 days" rule. **The owner will confirm the new retention
periods with the lawyer** (as the legal section above requires for longer retention).

- **Photos** (national ID front/back, identity selfie, child school ID, driver's and car
  licence, driver photo, live selfie checks): kept while the account is active and deleted
  1 year after the account closes. Stored in the private bucket, encrypted with our own key
  (Cloud KMS), compressed on the phone, readable only by admins through a logged reason.
  The identity selfie is the face reference for the random driver selfie checks.
- **Usage analytics:** collected (screens, features used, crashes) without names, phone
  numbers, IDs, message text or coordinates; parents can switch it off in Settings.
- **Trip history:** run summaries (who drove, date, times, on time or late, children counted)
  kept while the account is active + 1 year.
- **Location history:** live points are still deleted from the live collection within 24 hours,
  but each run's route is archived as one compressed, down-sampled track (about 1 point per
  30 s) in cold storage, kept 1 year, readable only by admins with a logged reason
  (safety investigations). Never shown to other parents after the run.
- **Chat history:** messages kept for the life of the chat + 1 year (was 180 days).
- **Storage optimization:** photos resized and re-encoded (WebP/JPEG, long edge about 1600 px)
  before upload, small thumbnails for the admin panel, Cloud Storage lifecycle rules (Nearline
  after 30 days, Coldline after 180 days), compressed route archives, and per-collection TTLs.
- Every new data type is listed on the privacy screen, in the consent records and in the
  App Store privacy answers.

## Owner updates (14 Nov 2026, 12:30)

- **Lawyer:** confirmed everything open is OK: the new retention periods (photos while the
  account is active + 1 year, route history 1 year, chat life + 1 year), keeping the identity
  selfie as the driver face reference, WhatsApp to an emergency contact who is not an app user,
  drivers' consent to live location sharing, ratings and family links, and how long wallet
  transfer records are kept.
- **Apple Developer account:** created and paid (USD 99/year).
- **GitHub:** no paid Actions minutes for now. CI runs automatically only on `main`;
  feature branches are checked by hand when a step is ready (one run per step).
- **Point-in-time recovery:** on in prod (best option rule).

## Location tracking on iPhone (14 Nov 2026, 13:05)

- **Plugin:** start with the free `geolocator` behind `LocationTracker`; the paid
  flutter_background_geolocation licence (USD 400) is deferred to the Android stage or to the
  pilot if tracking proves unreliable. Switching back is a one-file change.
- **Permission:** "While Using the App" + Precise Location, background location mode on, blue
  indicator shown. We do not ask for "Always". (Updated 13:44: "Always" is offered once to drivers as an
  OPTIONAL step for run recovery; the gate never requires it. See below.)
- **Gate (owner chose option 1):** a driver cannot start a run without Location Services on,
  app permission granted and Precise Location on (plus notifications). A full-screen blocking
  sheet shows the steps (Arabic and English) and an "Open Settings" button, and re-checks on
  return. Other parents can use the rest of the app; they see a banner with the same steps.
  The whole app is NOT blocked (App Store guideline 5.1.1).
- **During a run:** losing permission or precise location shows the steps at once and alerts
  parents. No point for 2 minutes → server pushes the driver "Run still on, open the app" and
  alerts parents. Points are buffered offline.
- **Settings:** automotive navigation, best accuracy, ~15 m distance filter, automatic pausing
  off.
- **App Review:** localized purpose strings, a reviewer note on background location, and a
  short run recording from the owner's iPhone.
- **Built in Prompt 13:** `lib/features/trips/geolocator_tracker.dart` (tracker),
  `location_gate.dart` (gate, banner), `reportTrackingLost` and the `run-still-on` push.
  The paid plugin, its licence (`BG_GEO_LICENSE`) and its native settings were removed so
  the iOS release build needs no licence.
- **How to bring the paid plugin back** (if the Android stage or the pilot shows tracking is
  unreliable): buy the v5 licence for `org.schoolcarpool.app` (+ `.stg`, `.dev`); add
  `flutter_background_geolocation: ^5.x` to pubspec; restore
  `lib/features/trips/background_location_tracker.dart`, `patch_bggeo_ios()` and
  `patch_bggeo_android()` in `tool/patch_native.py`, the `fetch`/`processing` background
  modes and `com.transistorsoft.fetch`, and SETUP.md 20.5 from git (the commit before
  Prompt 13's "remove the paid location plugin"); swap the tracker in `lib/bootstrap.dart`
  (one line); add `BG_GEO_LICENSE` to Codemagic's `staging_defines`/`dev_defines`. The
  server (`tripLocation`) accepts both plugins' upload bodies. The gate stays as it is.

## Owner answers (14 Nov 2026, 13:29)

1. **Wallet transfer records: kept 5 years** (confirmed; no longer a placeholder). Still
   append-only; any deletion job at the end of the 5 years needs the owner's go.
2. **Trips of a closed carpool are not deleted as a whole 1 year after the carpool closes.**
   Each parent's trip data is kept while that parent's account is active + 1 year (the
   retention rule above). The closed-carpool purge keeps a trip while any parent who took part
   (driver or a parent of a child on it) still has an account, or closed theirs less than
   1 year ago; a parent's part is anonymised 1 year after their account closes (deleted
   parents already show as initials); the trip is deleted only when every participant's
   account has been closed for more than 1 year.
3. **Chat connection up to 60 minutes after sign-out** (Stream token lifetime): accepted for
   now, not a bug (docs/open-items.md).

## Owner answers (14 Nov 2026, 13:44): run recovery on iPhone

The driver's location must keep reaching parents when the driver switches
apps, takes a phone call, or iOS closes the app (memory, swipe away). No
paid plugin, no new third-party dependency.

- **Switching apps, calls, lock screen:** covered by the geolocator settings
  (background updates, `location` background mode, no auto pause, blue
  indicator); nothing in the app stops tracking on inactive/hidden/paused.
- **App closed by iOS:** our own small plugin `packages/run_recovery` (Swift,
  path dependency): during a run a background activity session (iOS 17+),
  a service session (iOS 18+) and, with "Always", significant location
  change monitoring so iOS relaunches the app in the background. At start
  the app reads a local run marker (IDs and start time only), checks the
  run on the server, resumes tracking if it is still on and younger than
  3 hours, sends the points waiting on the phone and shows "Tracking
  resumed". The marker is cleared at the end of the run and on sign-out.
- **Permission (updates the 13:05 decision):** the gate still requires only
  "While Using the App" + Precise Location (+ notifications). Drivers get
  ONE optional screen, once per install, offering "Always" so runs resume
  by themselves; declining changes nothing else (the "keep the app open"
  hint stays). Analytics record only whether Always was granted.
- **Fallback:** the server's 2-minute "Run still on" push to the driver and
  the parents' "location stopped" alert stay.
- **Verification:** relaunch behaviour can only be checked on a real iPhone
  (docs/test-iphone.md section 7).
- **Classic iOS launch (Prompt 13 review, blocker 2):** `flutter create` now
  makes a UIScene app whose engine and plugins start only when a scene
  connects, which never happens when iOS relaunches the app in the
  background for location. `tool/patch_native.py` therefore makes the
  Runner a classic app-delegate app: the AppDelegate starts the Flutter
  engine (Dart `main`) and registers the plugins in
  `didFinishLaunchingWithOptions` (plugins get the real launch options), no
  scene manifest, the generated SceneDelegate emptied. **To be verified on
  a real iPhone (docs/test-iphone.md T6):** recovery usually resumes within
  a few minutes after the car moves. **Revisit** when Apple requires UIScene
  (announced for an SDK after iOS 26): then the AppDelegate must start a
  headless engine on a location launch instead.

## Improvements (owner, 14 Nov 2026, 17:17): "do all of them"

1. **Pilot without the wallet.** Wallet code stays, switched off by a server
   feature switch; parents settle in cash during the pilot. Turned on once the
   payment partner contract is signed.
2. **Own chat on Firestore, replacing Stream Chat.** Small carpool groups,
   text and photos; membership decided by Cloud Functions; same moderation
   (reports, removal) through the admin panel; retention: chat life + 1 year.
3. **Firebase Crashlytics (app) and Google Cloud Error Reporting / Logging
   (functions), replacing Sentry.** No personal data in crash keys, logs or
   breadcrumbs.
4. **SMS backup for sign-in codes.** Only when WhatsApp delivery fails (or the
   parent taps "send by SMS" after the WhatsApp code did not arrive in time);
   own SmsProvider behind an interface with a fake; Egyptian mobile numbers
   only; strict limits against SMS pumping fraud. Provider to be chosen by the
   owner (candidates in docs/progress/improvements.md). Never Firebase phone
   auth; Identity Platform SMS region policy stays "deny all".
5. **Xcode Cloud** as a documented backup builder (25 free hours a month with
   the Apple Developer membership); Codemagic stays the main builder.
6. **Private repository before public launch** (GitHub paid plan or checks
   elsewhere); the steps are in docs/launch-private-repo.md.
7. **Smaller first release:** pilot feature switches; on for the pilot:
   sign-in, verification, carpools, schedule, live trips and alerts, chat.
   Off: wallet, ratings and vouching, yearly re-checks (all can be turned on
   from server settings without a new build).

## Improvements, revised (owner, 14 Nov 2026, 17:24): supersedes the list above

After a second check of the code and current facts, the owner approved this
revised list ("implement all your suggestions"):

1. **Pilot feature switches; wallet off.** As above (items 1 and 7).
2. **Lock package versions.** Commit `pubspec.lock` and
   `functions/package-lock.json`; CI and deploys install exactly those.
3. **Own chat on Firestore, replacing Stream.** Built now on its own branch;
   merged only after the first TestFlight build runs on the owner's iPhone.
   Reasons: staging's fake chat is on one phone only, Stream's free account
   caps connections at 100 at once, and messages stay in our database.
4. **Sentry stays** (Crashlytics is withdrawn: its Flutter plugin has no web
   support, so the admin panel and the website would lose error reports).
5. **Xcode Cloud is dropped** (it needs the iOS project stored in the
   repository; ours is generated at build time). Codemagic stays.
6. **SMS backup is on hold.** The "No SMS anywhere" rule stands. The owner
   starts Meta business verification now; SMS is reconsidered only if Meta
   stalls.
7. **Private repository before public launch.** docs/launch-private-repo.md.
8. **"Settle up" by InstaPay replaces the wallet for the pilot.** Apple Pay
   cannot send money between people (Apple Cash is US only). The app records
   payment requests between parents of the same carpool (requested, paid,
   received), shows the payee's InstaPay address to the payer, and never
   moves, holds or sees money, so no payment partner is needed. The lawyer
   should confirm that no Central Bank licence is needed for this.
