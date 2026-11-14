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
  indicator shown. We do not ask for "Always".
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
