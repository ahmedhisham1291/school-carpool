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
  1 year after the account closes (**superseded 16 Nov 2026: deleted WITH the account**,
  see "Data after account deletion" below). Stored in the private bucket, encrypted with our own key
  (Cloud KMS), compressed on the phone, readable only by admins through a logged reason.
  The identity selfie is the face reference for the random driver selfie checks.
- **Usage analytics:** collected (screens, features used, crashes) without names, phone
  numbers, IDs, message text or coordinates; parents can switch it off in Settings.
  (**Superseded 16 Nov 2026: off until the parent says yes**, see "App Review risks" below.)
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

## Data after account deletion (owner, 16 Nov 2026)

Owner instruction: "All risks you're seeing, update the code and plan to be
no risk at all." This **supersedes "photos kept 1 year after the account
closes"** (and the same year for the verification records, the deleted
parent's chat messages and the routes of runs they drove) in the section
above. Reason: App Review guideline 5.1.1(v) and Apple's account-deletion
rules allow keeping only what the law requires, and the parent must be told
what is kept. **The lawyer is to confirm** the list of kept records
(docs/open-items.md B13).

- **Deleted with the account, in the same request:** profile, phone and
  email; ID, selfie, school ID, licence and driver photos; the face
  reference; the verification case records; children, car, home address and
  exact pin; every chat message the parent wrote (private and group chats);
  devices, sign-in history and push tokens; the archived routes of the runs
  the parent drove. (**R2, 16 Nov 2026:** the legal sign-in log is kept
  180 days from each sign-in, see "Legal changes R1-R15".)
- **Safety hold:** only when an open report or rating flag about the parent
  exists at deletion, the photos, case records and routes wait 30 days
  (`SAFETY_HOLD_DAYS`) so the admins can finish the case; then they are
  deleted whatever its state. Nothing else is held.
- **Kept, minimised and detached from the profile** (no name, phone,
  address, photo or ID number): run summaries shared with other families
  (the parent as an initial; their part anonymised 1 year after closure),
  the consent records (1 year; **3 years since R1, 16 Nov 2026**, see
  "Legal changes R1-R15" below), Settle up records (1 year, an initial),
  transfer records (5 years), reports about the parent, the admin audit
  log (2 years), the keyed ID hash on the ban list (banned parents only),
  the reserved parent ID.
- While an account is OPEN nothing changes: photos are kept (the face
  reference is needed for the driver checks), routes 1 year after the run,
  chat for the chat's life + 1 year.
- Accounts already closed under the older rule: run
  `npm --prefix functions run deletions:reapply` once after the deploy; the
  next daily job deletes their photos, case records, routes and messages.
- The privacy policy and the verification consent changed version
  (2026-11-16): functions and app are deployed together.

## App Review risks (owner, 16 Nov 2026)

Owner instruction (16 Nov 2026): "All risks you're seeing, update the code
and plan to be no risk at all." Decisions taken with it (branch
`review-risks`; guideline numbers from developer.apple.com, read that day):

- **Notifications are not required** (4.5.4, 5.1.2(i)): the driver gate is
  location only. With notifications off the driver sees one warning ("You
  may miss alerts") with Open Settings and Start anyway. Replaces "plus
  notifications" in the 13:05 gate.
- **No "Always" location** (5.1.1, 2.5.4): the optional Always screen, its
  request, the significant-change monitoring and the
  `NSLocationAlwaysAndWhenInUseUsageDescription` text are gone; geolocator
  is built without its Always request. "While Using the App" + Precise +
  the background mode + the blue indicator stay. A run that iOS closes
  resumes from the local marker when the driver opens the app; the
  server's "Run still on" push and the parents' "location stopped" alert
  stay. Replaces the 13:44 optional Always screen.
- **Account deletion deletes photos, the face reference, messages, the home
  address and pin, and the routes promptly** (5.1.1(v)): see "Data after
  account deletion" below. It supersedes the 1-year rule for those data.
  **The lawyer is to confirm** the short list of records kept
  (docs/open-items.md B13).
- **Usage statistics are opt-in** (5.1.1(ii)): Firebase Analytics stays off
  until the parent says yes on the Home card (asked once, never blocks) or
  in Settings; withdrawable any time; no IDFA, no advertising, no App
  Tracking Transparency prompt needed. Sentry error reports (scrubbed) stay
  on and are disclosed in the policy.
- **Look around before the ID check** (2.1): see the next section.
- **The iOS Runner moves to the UIScene life cycle** (needed with the iOS
  27 SDK): see "Location tracking on iPhone (13:44)" above.
- **What code cannot make zero-risk:** App Review is a human judgement and
  may ask for things no rule lists; the Apple Developer account must be an
  Organization, not an Individual, because the app requires national IDs
  and face images (5.1.1(ix); needs a D-U-N-S number); the lawyer must
  confirm the retention list and the legal pages. These stay owner items.

## Before the ID check: look around first (owner, 16 Nov 2026)

Owner instruction (16 Nov 2026): remove every App Review risk. A reviewer
(or a parent) who makes a new account cannot pass the ID check, so "Profile
only until verified" (spec section 3) was a dead end (guideline 2.1). This
**supersedes "Profile only"** for unverified, pending and rejected accounts:

- **Open:** the five tabs (Carpools shows the parent's own list, empty;
  Chats explains that chat opens after the check), the home address and
  pin, driving schools, children and driver details (the verification
  steps), notifications and their settings, privacy, settings, About.
- **Needs the ID check** (child safety: anything with another family):
  finding, starting, joining or opening a carpool, invite links (their
  screen explains), runs and driving, chats, parents nearby, handover
  adults and the emergency contact, ratings, family links, the yearly
  check, phone change, Settle up and the wallet.
- Opening one of those shows the verification screen: why we check (other
  families' children ride with you), what is needed, "Get verified" and
  "Later" (back to the tab). A card on Home, Carpools and Chats says the
  same. No dead end.
- One line for app and server: `needsVerification` in
  `lib/router/session_redirect.dart`; the server refuses the same actions
  with "not-verified" (`functions/test/verification_scope.test.ts`).
- Suspended accounts still see only the suspension screen.

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
  OPTIONAL step for run recovery; the gate never requires it. See below. **Superseded 16 Nov
  2026: "Always" is never asked**, see "App Review risks" below.)
- **Gate (owner chose option 1):** a driver cannot start a run without Location Services on,
  app permission granted and Precise Location on (plus notifications; **16 Nov 2026:
  notifications are a warning only, never a block**). A full-screen blocking
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
  **Superseded 16 Nov 2026:** no "Always" screen, no significant-change
  monitoring; the run resumes from the local marker when the driver opens
  the app (see "App Review risks" below).
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
- **Superseded 16 Nov 2026 (review-risks item 8): UIScene life cycle.** The
  background relaunch for location is gone with "Always" (item 2), so the
  classic launch is no longer needed. `tool/patch_native.py` now follows
  Flutter's "UIScene adoption" guide: plugins are registered in
  `didInitializeImplicitFlutterEngine`, the scene manifest names
  `FlutterSceneDelegate` (or the template's `SceneDelegate` subclass), the
  Maps key and the notification-center delegate stay in
  `didFinishLaunching` (they must be set before launch ends). A project
  patched the old way is migrated. `tool/check_ios_app.py` fails any build
  without the scene manifest. Xcode stays pinned at 26.4 until a staging
  build on 27 is tested.

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

## Owner update (14 Nov 2026, 17:28)

- **Lawyer:** confirmed that "Settle up" (recording payment requests between
  parents and showing the payee's InstaPay address, with the app never moving
  or holding money) needs no Central Bank of Egypt licence.

## Owner answers (15 Nov 2026, 05:11)

- **Emergency-contact WhatsApp:** the lawyer confirmed that sending the
  WhatsApp message to a parent's emergency contact without that person's own
  opt-in is acceptable legally. (Separate from the law: Meta's template review
  may still reject `cp_emergency_contact`; see docs/meta-whatsapp-setup.md.)
- **Settle up records:** kept while either parent's account is active, plus
  1 year (confirmed; same rule as trips).

## Owner update (15 Nov 2026, 14:53)

- **Admin panel language:** starts in English (the parents' app stays Arabic
  by default). A language button is on the sign-in and two-step setup
  screens as well as inside the panel.

## Owner decision (16 Nov 2026): automatic AI name review in Cloud Shell

- Every kept school name is reviewed by a model on Vertex AI in the owner's
  Google Cloud project during step 12 (tools/import_schools/ai_review.py):
  real school / drop / fix spelling and casing / same school as another /
  wrong kind. Applied automatically at confidence 0.8 or more (configurable),
  kept as is below; manual decisions (data/schools/review/decisions.csv)
  win. Default model gemini-3.8-flash in the "eu" multi-region (europe-west1
  does not serve it; "global" if eu answers 404); Claude Haiku on Vertex as
  an option. Only public school names, kinds, categories and governorates are
  sent, never positions or user data. Results are cached in the server-only
  Firestore collection schoolReview. Admin-edited and parents' schools are
  never dropped, renamed or merged away by it (the loader protects them);
  nothing is deleted, only hidden.

## Owner decisions (16 Nov 2026, after the first full staging run): a clean list

- **No manual duplicate review:** duplicates are merged automatically
  (tools/import_schools/dedupe.py: same name within 500 m; 85 % alike
  within 300 m; Arabic and English names alike within 300 m; one name
  inside the other within 100 m, or 300 m when the extra words are not a
  place; a school's KG section within 300 m; same name within 2 km).
  Branches of a chain with a place word in the name, different stages or
  boys/girls never merge. A common name (the same core name in 3 or more
  places of Egypt, e.g. "النور", "Al Nour", "الشهيد أحمد") merges only at
  the same site: within 150 m (100 m for one name inside the other or a
  KG and a school), never by the 2 km rule (validator B1). A merge is
  never final: a review row `separate` keeps two entries apart, and a
  school an earlier import merged comes back into the list when a later
  run keeps it apart (validator B2). The survivor: owner list > OSM > Wikidata >
  Overture (higher confidence first), best Arabic and English names, OSM or
  Wikidata position; merged ids in `mergedFrom`, one row each in
  build/schools/merged.csv. Already loaded duplicates get status "merged"
  + mergedInto (never deleted); an admin-edited school is always the
  survivor; parents' schools are never merged, only listed.
- **Names only in Arabic or Latin letters:** mojibake is repaired, Arabic
  presentation forms, fancy and fullwidth letters normalised, controls and
  emoji removed; a school with no Arabic or Latin name is dropped ("Name
  not in Arabic or English"); a few odd letters in a mostly Arabic/Latin
  name are removed. Loaded schools that now fail are taken out of the list
  (searchHidden + hiddenReason), never deleted.
- **Tutoring centres and Quran memorisation are not schools** (سنتر, دروس,
  IELTS, دار تحفيظ, كتاب); Overture preschools named for small children
  ("Kids Academy", "Baby Club") are kept.
- **A reviewer's decisions win:** data/schools/review/decisions.csv
  (drop, keep, rename_ar, rename_en, set_kind, merge_into, separate) is
  applied on every import and wins over the automatic rules.
- **Areas are Egypt's ADM2 units** (qism / markaz / new city; OCHA COD-AB
  on HDX, geoBoundaries as a fallback): OpenStreetMap has almost no
  boundaries below the governorate in Egypt. Districts stay OpenStreetMap
  (named neighbourhoods inside the area, boundaries where they exist).
- **Empty child menus say why** ("Choose a city first", "No areas for this
  city yet", "No districts for this area yet"); in the address form a city
  with no areas lets the parent go on (area optional, district typed and
  optional).

## Owner decisions (16 Nov 2026): what counts as a school, more sources

- **Schools, kindergartens and nurseries only.** Universities, colleges and
  higher institutes are not in the list. The import keeps a switch for
  them (`data/schools/categories.json`, `"university": false`); switched
  on, they would be kept with kind `university` (the server and the search
  index accept it; the app and admin type filter is not built). Nurseries
  (حضانة, OSM `amenity=childcare`, Overture day-care places named like a
  nursery) are kept with the kindergartens.
- **Al-Azhar institutes are schools:** معهد أزهري ابتدائي / إعدادي / ثانوي
  (and "Al-Azhar Institute ...") are kept as schools however they are
  tagged; Al-Azhar University and its faculties are not.
- **Overture Maps Places is the third source** (after OpenStreetMap and
  Wikidata): CDLA Permissive 2.0 / Apache 2.0 / CC0 by provider, attribution
  in open item D24; same keep/drop rules, merged into an OSM or Wikidata
  school with the same name within 300 m, never the main entry when another
  source has the school (coordinator, 16 Nov 2026).
- **The OpenStreetMap download runs per governorate** (27 queries of at most
  180 s) because the one-country query timed out on every public server;
  a governorate that fails keeps its older file (its date is reported).

## Owner decisions (16 Nov 2026): places and addresses

- **City -> Area -> District, option 1 (keep both):** the per-school `areas`
  of Prompt 6 (an area belongs to one school; carpools, search and chat use
  them) stay unchanged. The new hierarchy is separate: City = governorate,
  `placeAreas` (qism / markaz / new city) and `placeDistricts`
  (neighbourhoods), from OpenStreetMap, managed by admins. Which OSM
  admin_level is an Area or a District is measured at import time, not
  assumed (SETUP.md 14).
- **F46 home address:** City, Area and District as dropdown menus
  (filterable; Area waits for City, District for Area; a change clears the
  ones below; "My district isn't listed" -> typed and reviewed), street and
  building, optional floor/apartment/landmark, then the pin confirmed on a
  map; "Search instead" stays as a shortcut. Schools are grouped City ->
  Area for browsing, with Algolia filters.

## Owner decision (15 Nov 2026, 16:44)

- **Schools list on staging:** load every Egyptian school and kindergarten
  we can get from open data into staging; staging uses Algolia for school
  search (paid plan accepted if needed). Source: OpenStreetMap through the
  Overpass API (ODbL), fetched by `tool/cloud_setup.sh` step 12; owner CSV
  lists are added when present (SETUP.md 14, docs/algolia-setup.md).

## Owner decision (16 Nov 2026): no money in the app; rides are free volunteer turns

Confirmed by the owner through the coordinator. **Supersedes** "Improvements,
revised" item 8 ("Settle up by InstaPay replaces the wallet for the pilot")
and the F25 "optional contribution per child".

- **Core fact:** the service is completely free and non-commercial. Each
  parent volunteers to drive the children on some days, by turns. No parent
  pays another parent for rides, there are no fares and the app takes no fee.
- **Every money feature is OFF in every environment (dev, staging, prod):**
  the wallet (F43), Settle up (F45) and the contribution per child (F25,
  new switch `contributions`). The defaults in `functions/src/features/model.ts`
  (`PILOT_DEFAULTS`) and `lib/features/feature_switches/feature_switches.dart`
  (`FeatureSwitches.pilot`) are all off, so a project with no
  `config/features` document has no money feature. **If a staging or prod
  project already has `config/features` with `settleUp: true`, a super admin
  switches it off in Admin panel > Settings** (docs/legal/owner-actions.md).
- **Code is kept, not deleted.** While off: the app shows no money UI (no
  wallet or Settle up rows, buttons, cards, InstaPay fields, contribution
  amounts or steps; deep links show "Not available yet"); the admin panel
  hides the Wallet section and a parent's wallet and settle-up records; the
  server refuses every wallet and Settle up callable with `feature-off`,
  refuses a new contribution and never asks a joining parent to accept one.
- **Volunteer acknowledgement:** creating or joining a carpool needs the box
  "Free turns, no payment" (version `VOLUNTEER_TERMS_VERSION`, stored on the
  membership).
- **Switching any money feature on again** is a new owner decision that
  needs the lawyer first (docs/legal/egypt-legal-review.md: Law 87/2018,
  insurance recourse, CBE). Ride-linked costs (fuel, per child, per run or
  per km) should stay out of the app even then.
- Store texts, review notes, the privacy manifest and App Privacy answers
  no longer declare financial data.

## Legal review, Egypt (16 Nov 2026): flags for the owner and the lawyer

The build agent's safe-side review (docs/legal/egypt-legal-review.md, not
legal advice) found points that **may conflict with earlier "lawyer
confirmed" items. Nothing below changes those decisions;** the owner takes
them to the lawyer (questions in section 12 of the memo):

1. "Legal" items 2 and 3 (operating entity and licence; hosting abroad)
   were confirmed before the PDPC licence regime became enforceable
   (1 Nov 2026): controller, sensitive-data and transfer-abroad licences
   and a registered DPO appear to be needed (open item B5).
2. Item 4 (IDs and children's data with consent screens): the law asks for
   explicit **written** consent for sensitive data; the app now asks for
   separate consents (ID + face, guardian declaration, storage abroad),
   but whether a tick box is "written" is for the lawyer.
3. Emergency-contact WhatsApp without the contact's opt-in (15 Nov): kept;
   the lawyer to confirm the legal basis in writing.
4. Sign-in history deleted with the account (16 Nov) vs. the
   Anti-Cybercrime Law's 180-day log retention: kept; sign-in history is
   now 180 days while the account is open.

Changes made on branch `legal-egypt` (reversible, recorded in the memo):
separate `transferAbroad` consent (required at sign-up); guardian
declaration separate from the ID/face consent; document versions
2026-11-16; privacy requests due in 6 working days with an admin queue;
sign-in history 180 days; public pages with a DPO contact, transfer
section, 72 h breach promise and "Arabic text prevails"; volunteer
acknowledgement at create/join; every money feature off (see the owner
decision above).

- Research answers available (docs/legal/answers.md), pending owner/lawyer confirmation.

## Legal changes R1-R15 (owner, 16 Nov 2026): "implement everything"

The owner approved every recommended change of docs/legal/answers.md
(R1-R15) through the coordinator (Arabic: "yes of course, implement
everything"). Built on branch `legal-changes` (docs/progress/legal-changes.md).
Where an item replaces an earlier decision, it says so.

- **R1 - proof of consent 3 years after closure** (was 1 year):
  `CONSENT_AFTER_CLOSURE_DAYS` in `functions/src/privacy/retention.ts`; the
  run summaries and Settle up records keep their 1 year. Reason: the
  limitation periods (misdemeanours 3 years, tort claims 3 years from
  knowledge; answers.md 1.6).
- **R2 - sign-in log kept 180 days from each sign-in, also after account
  deletion.** **Supersedes, for this log only, "devices, sign-in history
  ... deleted with the account" (16 Nov 2026)**: the list the parent sees
  (`users/{uid}/logins`) still goes with the account. The legal log
  (`signInLog`, `functions/src/privacy/signin_log.ts`) holds per sign-in:
  uid, a keyed hash of the number, the number and IP encrypted (secret
  `SIGNIN_LOG_KEY`), time, device hash, platform, app version; no message
  text, names, photos or location. Server-only (rules deny every client,
  admins too); TTL 180 days from each line; read only through the
  super-admin callable `adminDiscloseSignInLog` (judicial-order reference,
  authority and date required, sign-in < 30 minutes, audit entry first).
  Reason: Law 175/2018 Art. 2 and Decree 1699/2020 (answers.md 4.2).
- **R3 - written consent for sensitive data.** Storage abroad (sign-up),
  the ID, face matching and the guardian's declaration (verification and
  every child added later) are each a separate unticked box, signed with
  the typed full name (must match the ID name after Arabic normalisation;
  at sign-up there is no ID name yet, so only its form is checked) and a
  fresh Face ID / passcode check (a phone without a lock: a sign-in less
  than 10 minutes old). Each record keeps the method, a keyed hash of the
  name, a SHA-256 of the exact text, device key, platform and app version
  (`functions/src/auth/signature.ts`; texts in `consent_texts.ts`, tested
  equal to the ARB files). The typed name sits on `users/{uid}.signedNames`
  and goes with the account. The parent opens and downloads a copy under
  Privacy (`getConsentCopy`). The ID and face consents are now two boxes.
  Versions: transferAbroad, id, face, childData `2026-11-17`.
- **R4 - children 15 to 18.** When a child is 15 or older (by an optional
  date of birth, the age or grade 10-12; the higher wins) the guardian
  also ticks and signs "my child was told what is shared and agrees"
  (consent `teenAgreement`, version `2026-11-17`; child record
  `teenAgreed`). The date of birth is used for the check only, never
  stored. The app derives it from the age and grade it already asks.
- **R5 - prod closed to new real parents until the three PDPC licences
  are granted** (controller, sensitive data, transfer abroad). Server
  setting `config/launch.pdpcLicensed` (missing = false), read only by
  the server: in prod a NEW number gets "Opening soon" after its code is
  checked and no account is created; existing accounts (staff, testers)
  and the App Review demo phones still sign in; dev and staging are
  always open. A super admin switches it in Admin panel > Settings >
  Launch (sign-in < 30 minutes, the licence numbers are required to open,
  audit entry). Pilot with real families only after it is on.
- **R6 - emergency contact opt-in** (adds to the 15 Nov "no opt-in needed"
  answer): saving a contact needs the box "this person agreed"; the
  contact gets a confirm / stop link (`/ec/<token>` on the links site,
  function `emergencyContactReply`) that the parent sends from their own
  phone. Until the contact confirms, alerts STILL go (child safety, as
  answers.md 1.8 says), but the first one uses the template
  `cp_emergency_contact_intro` (names the parent, why, how to stop); a
  contact who tapped "stop" gets nothing. Name, number, status and the
  link token only; deleted with the account.
- **R7 - breach register kept 5 years after an incident closes**
  (`BREACH_REGISTER_YEARS`, `retainUntilMs` set on close; runbook and
  record of processing). No deletion job yet.
- **R8 - terms and privacy wording** (drafts until the lawyer approves,
  answers.md 5.2): same school OR the same activity at one venue, closed
  carpools (approval, no public offers); "Emergencies, accidents and
  insurance" (122/123, report in the app, the driving parent notifies the
  compulsory insurance pool and the insurer within 15 days, Law 155/2024
  Art. 51; run records disclosed only on a lawful request); the operator's
  registered address after its name (`tool/links_site.py
  --operator-address`, `--require-address` for prod); consent (3 years)
  and sign-in log (180 days) lines. Versions terms and privacy
  `2026-11-17`: every account accepts them again (and signs storage
  abroad, R3) on the next app start.
- **R9 - activity carpools (F39) off in the pilot.** New switch
  `activityCarpools` (default off everywhere): creating, searching and
  joining an activity carpool are refused with `feature-off` and the app
  hides the option. When switched on (only after the lawyer's written Law
  87/2018 opinion covers F39): one activity at one venue (a search names
  the activity), joining by approval plus every parent's driver consent
  (F26), no public offers (never on the nearby map's parent list).
- **R10 - processor contracts:** `docs/legal/processor-checklist.md`
  (clauses C1-C13: instructions only, no reuse or model training, 24-hour
  breach notice with the Regs Art. 5 contents, region, sub-processors,
  deletion, audit); big vendors' standard DPAs accepted as they are;
  Sentry and Algolia move to EU regions where the plan allows (owner).
