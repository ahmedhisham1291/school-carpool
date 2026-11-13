# School Carpool App – Build Prompts

Nov 13, 2026 · @Ahmed Hisham

## How to use these prompts

Run these prompts in order in an AI coding agent that can read and write files and run commands in your project folder. Each prompt builds one slice of the [spec](https://claude.ai/artifact/FK7wgDMQj2qHuPcevR23qt) and ends with a check you do yourself.

1. Export the spec as Markdown and save it in the project as `docs/spec.md`.
2. Save Prompt 0 as the agent's rules file at the top of the project (`AGENTS.md`, or `CLAUDE.md` in Claude Code).
3. Paste one prompt per session. The agent answers with a plan first; read it, answer its questions, then say "go".
4. Do the "Done when" checks before moving on. If one fails, use the helper prompt at the end.
5. Stage 1 builds everything on iPhone, Stage 2 opens the website, Stage 3 finishes Android.

**Decisions these prompts assume**

- Flutter for iPhone, website and Android, with Firebase behind it.
- Chat runs on Stream Chat, a paid chat service.
- The ID check (Valify) and the wallet (a licensed payment partner) each sit behind one interface with a fake provider, so work is not blocked while the contracts are signed.
- The website is the same parent app in a browser. Starting a run stays on the phone, because a browser cannot share location in the background.
- Paid services are used wherever they are the strongest option: Stream for chat, Algolia for school search, Sentry for errors, Codemagic for builds and a licensed plugin for live location.
- The wallet is run by a payment partner licensed by the Central Bank of Egypt. The app never holds money.
- The DESIGN rules in Prompt 0 apply to every screen in every prompt.

Change Prompt 0 first if you decide differently on any of these.

## Before you start

Get these accounts in place first; several take days to approve.

| What you need | Why | Needed from |
| --- | --- | --- |
| Cloud builds on a paid plan at [Codemagic](https://blog.codemagic.io/how-to-build-and-distribute-ios-apps-without-mac-with-flutter-codemagic/) | iPhone apps are built on macOS; without a Mac you can install test builds but cannot debug on the phone | Prompt 1 |
| Apple Developer account (paid yearly) | Signs the app and puts it on your iPhone through TestFlight | Prompt 1 |
| Three Firebase projects on the pay-as-you-go plan: dev, staging, production | Keeps fake data away from real data; Cloud Functions need the paid plan | Prompt 1 |
| Google Maps Platform key with Maps, Places and Routes switched on | Maps and pickers | Prompt 5 |
| Verified WhatsApp Business account with approved templates | Codes and notifications; until then the dev build prints them in the log | Before staging tests |
| Valify account (ID check provider) | Automatic ID scan and face match; a fake provider covers development | Before the pilot |
| Google Play developer account | Android testing | Stage 3 |
| Lawyer's answers on license, hosting abroad and operator entity | Needed before any real ID is collected | Before the pilot |
| Sentry account (paid plan) | Error reports from the app, the website and Cloud Functions | Prompt 1 |
| Schools data: the Egypt education facilities export from the Humanitarian Data Exchange, plus any ministry or governorate list you can get | Fills the schools list parents choose from | Prompt 4B |
| Algolia account | School search; a fake search covers development | Before staging tests |
| Stream account with one app for development and one for production | Chat | Prompt 9 |
| License for flutter\_background\_geolocation | Live location in release builds; debug builds work without it | Prompt 13 |
| Wallet partner licensed by the Central Bank of Egypt, with a signed contract and test access | Holds the money and runs transfers; a fake provider covers development | Before the pilot |

## Prompt 0: project rules file

Save this text as the rules file so the agent reads it at the start of every session.

```text
# School Carpool App: rules for the coding agent

Source of truth: docs/spec.md. Feature IDs (F1 to F44) are in section 4.
If the spec and a prompt disagree, stop and ask me.

STACK (decided: the strongest option for each job, paid where that buys
quality)
- Flutter, stable channel: one codebase for iPhone, website and Android.
  Riverpod for state and go_router for navigation, unless you give me a
  reason to change.
- Firebase on Google Cloud: Authentication on the Identity Platform tier,
  Firestore with point-in-time recovery and daily backups, Storage, Cloud
  Functions second generation (TypeScript) with instances kept warm for
  sign-in, alerts and the wallet, Cloud Messaging, App Check, Hosting.
- Three Firebase projects and three app flavors: dev, staging, prod.
  Dev runs on the Firebase emulators.
- Sign-in: a one-time code sent by WhatsApp from Cloud Functions, then a
  Firebase custom token. No SMS anywhere.
- The WhatsApp Business Platform is called only from Cloud Functions.
- Google Maps Platform for every map, with Places for address search and
  Routes for arrival times.
- Live location on the phone: flutter_background_geolocation (paid
  license), running only while a run is on.
- Chat: Stream Chat with its Flutter SDK. Cloud Functions issue the Stream
  tokens and decide who is a member of which channel.
- School search: Algolia, fed from Firestore by a Cloud Function.
- ID check: Valify behind one interface (KycProvider).
- Wallet: a payment partner licensed by the Central Bank of Egypt behind
  one interface (WalletProvider). The partner holds the money. Our database
  keeps a copy of balances and a record of transfers, never the money.
- Errors: Sentry in the app, the website and Cloud Functions.
- Builds and releases: Codemagic.
- Fakes for dev: the ID check, wallet, WhatsApp and school search each have
  a fake provider, so the app runs on the emulators with no paid account
  and work is never blocked by a contract. Stream uses a separate dev app
  with fake users.

PLATFORM ORDER
iPhone first. A feature is done only when it runs on iPhone. The website and
Android must keep compiling in CI, but their platform work waits for the
Stage 2 and Stage 3 prompts.

HOW TO WORK
1. Plan first. Before writing code, list the tasks, the files you will touch,
   data model changes and open questions. For every new screen, describe
   the layout and its loading, empty, error and offline states. Wait for my
   "go".
2. Keep changes small. One feature ID per commit, for example
   "F7: rotation per direction".
3. Do not add a dependency, a paid service or a new tool beyond the STACK
   list without telling me why first.
4. End every session with: what you built, screenshots of each new screen in
   Arabic and English, how I test it on my iPhone step by step, and what is
   not done.

DESIGN (applies to every screen in every prompt)
- Look: modern, calm and trustworthy. Generous white space, one accent
  color, rounded cards and a clear hierarchy. Parents use this app in a
  hurry.
- Material 3 with our own theme. Colors, type sizes, spacing, corner radii
  and shadows come from design tokens. No hard-coded values in screens.
- One typeface family that is strong in both Arabic and Latin. Body text at
  least 16.
- 8-point spacing grid. One primary action per screen. Touch targets at
  least 48 by 48.
- Every screen has a loading state (skeleton placeholders), an empty state,
  an error state and an offline state.
- Forms are split into short steps with a progress indicator, check each
  field as the parent types, and say how to fix an error.
- Every action gives feedback. Ask for confirmation before anything that
  cannot be undone.
- Accessibility: contrast at WCAG AA, text that scales to 200 percent
  without breaking the layout, and labels for screen readers.
- Right-to-left first: design each screen in Arabic, then check English.
- Light and dark themes.
- Motion is short and subtle, and follows the phone's reduce-motion setting.
- Driver screens are readable at a glance: large buttons, few words, and no
  typing while a run is on.
- Reuse components from the design system. A new component goes into the
  gallery screen first.

PARENT ID
Every parent gets a public parent ID when the account is created: 8
characters from letters and digits that cannot be confused (no 0, O, 1 or
I), unique, never reused, and not derived from the phone or national ID
number. Only a Cloud Function creates it.

MONEY (never skip)
- Every wallet action goes through Cloud Functions and the WalletProvider.
  The app never writes a balance or a transfer.
- Each transfer carries a unique request ID so a retry can never send twice.
- A fresh Face ID, fingerprint or app passcode check before every transfer.
- Limits per transfer and per day, kept in server settings.
- The transfer record is append-only: no edits and no deletes.
- The app takes no fee and no commission.

SECURITY (never skip)
- Firestore and Storage rules deny everything by default.
- The app never writes status, role, verification or schedule ownership.
  Cloud Functions do. "verified" and "admin" are custom claims.
- Every rules change comes with emulator tests. No failing rules test is
  merged.
- App Check is enforced on Functions, Firestore and Storage in staging and
  prod.
- Secrets live in Secret Manager or build-time defines, never in the
  repository. Stream, Algolia, Valify, WhatsApp and wallet secrets stay in
  Cloud Functions; the app holds only short-lived tokens and search-only
  keys.

PRIVACY (never skip)
- Never log phone numbers, national ID numbers, images, coordinates or
  message text, and never send them to Sentry or Algolia.
- Only fake data in dev and staging. Never copy production data.
- ID, selfie, school ID and license images go to a private bucket and are
  deleted by the scheduled job after review.
- Other parents get rounded home coordinates only. Exact pickup points are
  readable only by approved members of that carpool.

LANGUAGES
Every string lives in ARB files in Arabic and English. Arabic is the default.
Every screen must work right-to-left.

TESTS
Unit tests for logic (rotation, swaps, seat limits, retention, transfers),
rules tests for every collection, widget tests for the main screens, and
golden tests of the main screens in Arabic and English, light and dark. Run
flutter analyze, flutter test and the Functions tests before you say a task
is done.
```

## Stage 1: iPhone

Fifteen prompts build the whole app on iPhone, each ending with a check on your own phone.

### Prompt 1: Foundation

```text
Read docs/spec.md (section 8 and Phase 0 in section 12) and the rules file.

Set up the project foundation:
- Flutter project with iPhone, web and Android targets and three flavors
  (dev, staging, prod).
- Firebase wired to each flavor; local emulators for Auth, Firestore,
  Functions and Storage.
- Arabic and English localization with right-to-left support and a language
  switch.
- Design system from the DESIGN rules: design tokens, light and dark themes,
  the Arabic and Latin typeface, buttons, inputs, cards, sheets, list rows,
  and skeleton, empty, error and offline states.
- A component gallery screen in the dev build that shows every component in
  Arabic and English, light and dark. First show me two color and type
  directions as screenshots and wait for my choice.
- Navigation shell with the five bottom tabs from section 10, showing
  placeholder screens.
- Firestore and Storage rules that deny everything, with a rules test project
  that runs in CI.
- App Check set up for iPhone (off in the emulator).
- Sentry in the app and in Cloud Functions, with personal data scrubbed and
  one test error from each.
- CI on Codemagic that runs analyze, tests and builds for iPhone, web and
  Android on every push.
- A seed script that fills the emulator with fake schools, areas, parents and
  children.
- A SETUP.md I can follow for the console steps: projects, budget alerts,
  quotas, keys, Firestore point-in-time recovery and daily backups.

Out of scope: any real feature.

Done when: the dev app opens on my iPhone, I can switch Arabic and English
and see the layout flip, switch light and dark, open the gallery and the
five tabs, see a test error arrive in Sentry, and CI is green.

Reply with your plan and questions first. Wait for my "go".
```

### Prompt 2: Sign-up with a WhatsApp code (F1, F44)

```text
Read section 3 (steps 1 and 2), F1, F44, and the technical controls in
section 7.

Build registration and sign-in:
- Screens: welcome and language, phone number, code entry, email, then terms
  with the privacy policy and code of conduct.
- Cloud Functions: requestCode creates a 6-digit code, stores only its hash
  with a 5-minute expiry, and sends it with a WhatsApp authentication
  template. verifyCode checks it and returns a Firebase custom token.
- Limits: codes capped per number, device and IP, and a lockout after
  repeated failures.
- In dev, do not call WhatsApp: print the code in the emulator log.
- Email confirmation by link.
- Save a consent record for each document the parent accepts, including
  agreement to WhatsApp messages.
- Create the User record with status "unverified" and a public parent ID
  (PARENT ID in the rules file). The app cannot change either.
- The profile shows the parent ID with a copy button.

Done when: on my iPhone I register with a phone number, enter the code,
confirm my email, accept the terms, and land on a "verify your account"
screen. My parent ID shows on my profile. A wrong or expired code is
refused. Rules tests prove a user cannot change their own status or parent
ID, and a test creates 10,000 parent IDs with no repeat.

Plan and questions first. Wait for my "go".
```

### Prompt 3: Identity verification (F2, F3, F18)

```text
Read section 3 in full, F2, F3, F18, and the Verification, Child, Vehicle and
Guardian link rows in section 9.

Build identity verification:
- Capture: national ID front and back, live selfie with a liveness prompt
  (camera only, no gallery), child details with a school ID photo, and the
  driver's license and car details for parents who will drive.
- Uploads go to a private bucket. Compress images on the phone and resume a
  broken upload. Never save captures to the gallery, and block screenshots on
  these screens.
- KycProvider interface with a fake provider that returns "match" or
  "no match" from a test setting. The real provider plugs in later.
- A Cloud Function runs the check, then puts the case in the admin queue.
  Only an admin decision sets "verified" and the custom claim.
- Store the national ID number only as a keyed hash (HMAC, key in Secret
  Manager). Refuse a second account with the same ID and any ID on the ban
  list.
- Record only the expiry date from the back of the ID. Store the driver's
  license and car license expiry dates.
- A scheduled job deletes all verification images within 7 days of the
  decision.
- Status screens: pending, approved, and rejected with the reason and a way
  to resubmit.

Done when: on my iPhone I submit documents and see "pending". After the case
is approved in the emulator, the app opens fully. A rejected case shows the
reason. A second account with the same ID is refused. A test shows the
deletion job removing the images.

Plan and questions first. Wait for my "go".
```

### Prompt 4: Admin web panel (F14)

```text
Read F14, the admin panel screens in section 10, and the admin panel control
in section 7.

Build the admin panel as a Flutter web app in the same repository:
- Sign-in for admin accounts only, with two-step login and short sessions.
- Verification queue: document viewer with the reviewer's name watermarked on
  every image, no download, the parent and child name check from section 3,
  and approve or reject with a reason.
- Users: search by name, phone or parent ID, suspend, ban, and see
  verification history.
- Schools and areas: add and edit, with a map pin for each school, and a
  queue of schools that parents typed under "Other" to approve as new or
  merge into an existing school.
- Reports queue (the list only; report handling comes with chat).
- Audit log: every admin action is written to a collection that admins cannot
  edit or delete.
- Roles: admin and super admin. Only a super admin creates admin accounts.

Done when: I open the panel in a browser, sign in with two steps, approve one
fake parent and reject another, add a school with a pin, and see all of it in
the audit log. A parent account cannot open the panel.

Plan and questions first. Wait for my "go".
```

### Prompt 4B: Schools list for Egypt (F4)

```text
Read F4, step 5 in section 3, and the School row in section 9.

Build the schools list:
- An import tool in tools/import_schools that reads the files I put in
  data/schools: the Egypt education facilities export from the Humanitarian
  Data Exchange (OpenStreetMap data) and any ministry, governorate or school
  group lists I add as CSV.
- Keep kindergartens and schools only. For each one keep the Arabic name,
  the English name, governorate, city or district, map location, source and
  source ID.
- Clean the data: drop entries with no name, normalize Arabic spelling for
  matching (alef and yaa forms, taa marbuta, diacritics), and merge
  duplicates that share a name within about 300 meters.
- Print a report: schools per governorate, entries dropped and why, and
  likely duplicates for me to check. Running the import twice must not
  create duplicates.
- Load the result into Firestore and sync it to an Algolia index with a
  Cloud Function. The app gets a search-only key limited to that index. The
  index holds school names and places only, never anything about a parent.
- School picker in registration and in "add a child": search as the parent
  types in Arabic or English, tolerant of spelling differences, with a
  governorate filter.
- "Other" is the last row of every result list. The parent types the school
  name and governorate and can drop a pin. It is saved as a school awaiting
  review, visible only to that parent until an admin approves it or merges
  it into an existing school (admin panel queue from Prompt 4). The parent
  continues registration meanwhile.
- Show the OpenStreetMap credit its license requires on the About screen.
- In dev, a fake search service reads the seed schools, so no Algolia
  account is needed.

Done when: I run the import and read the report. On my iPhone I find a
school by typing part of its name in Arabic and in English. I add a school
under "Other", approve it in the admin panel, and a second parent can then
find it.

Plan and questions first. Wait for my "go".
```

### Prompt 5: Home, schools and maps (F4, F21 to F24, F40)

```text
Read F4, F21, F22, F23, F24, F40, the Home address and Map visibility rules
in section 6, and the location control in section 7.

Build maps and location:
- Home picker on Google Maps with pin, address search (Places) and "use my
  current location".
- School picker: the search from Prompt 4B or the map, nearest schools first
  once the home is set, one school per child, plus the list of other schools
  the parent can drive to.
- A Cloud Function rounds home coordinates to about 500 meters before saving.
  Exact pickup points go in a separate record that only approved members of
  the same carpool can read.
- Nearby parents map: verified parents of the same school inside a chosen
  radius, blurred markers, and a card with first name, Verified badge,
  school, and Message and Join buttons.
- Settings: hide me from the map, new-parent alerts on or off.
- Create the "new parent nearby" event when someone is verified (sending it
  comes in Prompt 8).
- Limits on how often a parent can move their home pin and search the map.
- Maps follow the app's light and dark themes.

Done when: on my iPhone I set my home and my child's school on the map, see
fake nearby parents as blurred markers, and hide myself. A test proves the
app never receives another parent's exact coordinates.

Plan and questions first. Wait for my "go".
```

### Prompt 6: Carpools (F5, F6, F25, F26, F31, F32, F36, F39)

```text
Read Flows A and B in section 2 and features F5, F6, F25, F26, F31, F32, F36
and F39.

Build carpool groups:
- Create a carpool: school or activity place, area, morning and afternoon
  times, days, seats, which children ride, an optional contribution per
  child, and rules picked from a fixed list.
- Search by school, area and time. Send a join request with the children's
  details. The creator approves or declines.
- Driver consent: a new member cannot be given a driving day for other
  children until each parent has accepted that driver. A parent can withdraw
  consent at any time.
- Seats: refuse any arrangement with more children than the car's passenger
  seats.
- Invite link that opens the app or the store. The invited parent must still
  be verified.
- "Looking for a carpool" posts, with a suggestion to start a group when
  three families match.
- Carpool detail screen: members, children's first names and grades, rules
  and contribution.

Done when: with two fake parents, one creates a carpool on my iPhone, the
other finds it, asks to join, is approved, and both accept each other as
drivers. An invite link opens the right carpool.

Plan and questions first. Wait for my "go".
```

### Prompt 7: Schedule, swaps and absences (F7, F11, F27, F28, F30, F37)

```text
Read Flows C and D in section 2, features F7, F11, F27, F28, F30 and F37, and
the Backups rule in section 6.

Build the schedule:
- Rotation: propose a fair plan with one confirmed driver for every morning
  run and every afternoon run. Members can adjust their days. Use the drive
  balance so the family that has driven least is offered more.
- Schedule exceptions set by the group admin: no-school days and one-off time
  changes, including Ramadan times.
- Swap request for one run. Any member can accept. An accepted swap updates
  the schedule.
- Driver confirmation before each run by a set time. With no confirmation,
  every parent in the group is alerted to take their own child. The app never
  assigns a driver who has not confirmed.
- "Child absent today" removes a child from that day's pickup list and tells
  the driver.
- Drive balance screen: runs driven and received per family this term.
- All schedule writes go through Cloud Functions.

Done when: on my iPhone I see this week's plan with a driver for each run,
swap one run with the second fake parent, mark a child absent, and add a
holiday. Unit tests cover the rotation and swap logic, including uneven
numbers of children.

Plan and questions first. Wait for my "go".
```

### Prompt 8: Notifications by push and WhatsApp (F12, F23)

```text
Read F12, F23, the critical alerts requirement in section 11, and the "on
the phone" control in section 7.

Build notifications:
- One Cloud Function sends every notification. It writes the in-app record,
  sends the push, and sends the WhatsApp template when the parent has that
  type switched on.
- Types: reminders to the driver the evening before and one hour before, swap
  requests and results, join requests, missing driver confirmation, child
  absent, new parent nearby, and verification result.
- Chat messages notify by push only.
- Push and WhatsApp text never contains child names, addresses or message
  text. The app loads the details after it opens.
- Notifications tab with read and unread.
- Settings: WhatsApp on or off for each type.
- Critical alerts ("no driver for tomorrow", "child not confirmed") also
  sound an in-app alarm when neither message is opened in time.
- In dev, log the WhatsApp message instead of sending it.

Done when: on my iPhone I receive a reminder push, a swap request appears in
the Notifications tab, and the emulator log shows the matching WhatsApp
message. Switching a type off stops its WhatsApp message.

Plan and questions first. Wait for my "go".
```

### Prompt 9: Chat (F8, F9, F10, F13)

```text
Read section 5, Flow E, and features F8, F9, F10 and F13.

Build chat on Stream Chat with its Flutter SDK:
- A Cloud Function creates the Stream user and a short-lived token for
  verified, non-suspended parents only. The Stream secret never leaves Cloud
  Functions. Suspending, banning or deleting an account removes that
  parent's chat access at once.
- Cloud Functions create every channel and manage its members: private
  chat, school group, area sub-groups and the carpool chat. The app cannot
  create channels or add members.
- Private chat starts with a request the other parent accepts, with a daily
  limit on new requests.
- Text, photos and a location pin. Photos only in private and carpool chats.
  Remove location data from every photo before upload.
- Read receipts in small chats, typing indicator, mute per chat, and
  messages that send once the phone is back online.
- Style the Stream screens with our design tokens so chat looks like the
  rest of the app, in Arabic and English.
- Stream moderation switched on for text and images, with blocked terms in
  Arabic and English. Report any message, user or group with a reason. Block
  any user.
- Admin panel: the reports queue shows the reported message with a little
  context only. Admins can remove a message or a member. An urgent report
  about a child's safety or dangerous driving pauses the driver's driving
  days at once.
- Message retention from section 7 applied in Stream. Stream gets first
  names and parent IDs only: no phone numbers, no addresses.
- Chat push goes through our own notification function (Prompt 8) from a
  Stream webhook, so push text follows the same privacy rule.
- Use a separate Stream app with fake users for dev and tests.

Done when: two fake parents chat between my iPhone and a second device, one
reports a message, and I see it in the admin panel and remove it. A blocked
parent cannot message the blocker. An unverified account gets no chat token.

Plan and questions first. Wait for my "go".
```

### Prompt 10: Trips and live location (F15, F16, F20, F29, F33, F34, F35, F38, F41)

```text
Read Flow C, the Live location, Arrival time and Handover rules in section
6, and features F15, F16, F20, F29, F33, F34, F35, F38 and F41.

Build the daily run:
- Start run: only the confirmed driver can start, and only after live
  location is on. Use flutter_background_geolocation so location keeps
  sending when the phone is locked or another app is open, one point every 5
  to 10 seconds. Tracking starts with the run and stops when the last child
  is dropped. It never runs outside a run.
- Live map for parents of the children on that run only, with the expected
  arrival time at their stop from the Routes API. Alert them if location
  stops.
- Today's driver card: profile photo, car model, color and plate.
- Arrived button for each child: a push with sound and a WhatsApp message
  asking the parents to send the child down. A second tap repeats it.
- Pickup and drop-off confirmation for each child, with a notification each
  time.
- Handover list: the adults allowed to receive each child. The receiving
  parent confirms the child arrived; with no confirmation in 10 minutes, both
  sides are alerted.
- Quick driver buttons: running late, at the gate, all children in.
- Emergency button: alerts the group and the saved emergency contact with the
  location.
- Random live selfie check before some runs; a mismatch pauses driving days
  and alerts an admin.
- Ask for the location permission after a clear explanation screen. Live
  points are deleted within 24 hours.
- Driver screens follow the driver rule in DESIGN: large buttons, few words,
  no typing.

Done when: I start a run on my iPhone, lock the phone, and a second device
shows the car moving with an arrival time. Arrived, pickup and drop-off each
reach the other parent. Stopping location triggers the alert. A parent whose
child is not on the run sees nothing. After the run ends, the phone sends no
more location.

Plan and questions first. Wait for my "go".
```

### Prompt 11: Trust and yearly checks (F17)

```text
Read section 6 in full, F17, and the rules in section 3.

Build the remaining trust features:
- Ratings and vouching between parents, only after shared trips, one rating
  per pair each month.
- Who may drive: only the verified parent whose license and car were checked.
  A spouse verifies separately and is linked to the same children.
- An expired driver's license or car license blocks new driving days, with a
  reminder to the parent before expiry.
- Suspended or banned driver: their runs become open swap requests and the
  group is told only that the driver is unavailable.
- Re-verification every school year: each parent confirms children, grades
  and schools; a child who left a school leaves its groups and chats.
- Re-verify when the phone number or the car changes.

Done when: on my iPhone I rate a parent after a finished trip, an expired
license in the test data blocks a driving day, and suspending a driver in the
admin panel opens swap requests for their runs.

Plan and questions first. Wait for my "go".
```

### Prompt 11B: Wallet and transfers (F43)

```text
Read F43, F44, F25, the Wallet, Parent ID and Contributions rules in section
6, the Wallet and Transfer rows in section 9, and the MONEY rules in the
rules file.

Build the wallet:
- WalletProvider interface: open a wallet, read the balance, add money, send
  to another wallet, withdraw, list transactions, freeze. Build a fake
  provider with test money. The real partner plugs in when the contract is
  signed, and nothing else in the app may call the partner directly.
- A wallet opens for a parent only after verification, with agreement to
  the partner's terms saved as a consent record.
- Wallet screen: balance, Add money, Send, Withdraw, and a history list with
  date, other parent, amount, note and status.
- Send: choose a parent from one of my carpools, or type a parent ID. Before
  the amount screen, show the receiver's first name, photo and Verified
  badge to confirm. Then amount, optional note, a review screen, and a Face
  ID, fingerprint or app passcode check.
- "Pay contribution" on the carpool screen fills in the receiver and the
  agreed amount. It stays optional; nothing is ever taken automatically.
- A Cloud Function runs every transfer: it checks that both parents are
  verified and not suspended, checks the limits, uses the request ID so a
  retry cannot send twice, calls the provider, and writes the append-only
  transfer record. The balance shown always comes from the provider.
- Clear states for pending, done and failed. A failed transfer never leaves
  money missing: test the timeout and retry paths.
- Notifications to sender and receiver by push and WhatsApp, with no amount
  on the lock screen.
- Parent ID lookup returns first name and badge only, and is rate limited so
  IDs cannot be guessed in bulk.
- Admin panel: read-only transfer log, freeze and unfreeze a wallet with a
  reason, and alerts for unusual patterns such as many transfers to new
  receivers in a short time. Admins cannot move money.
- Report a transfer problem from the history list.

Done when: with two fake parents, I add test money on my iPhone, send one
amount by parent ID and one from a carpool, and both histories match. A
double tap or a retry sends once. A transfer above the limit is refused. A
frozen wallet cannot send. Rules tests prove the app cannot write a balance
or a transfer.

Plan and questions first. Wait for my "go".
```

### Prompt 12: Privacy and security hardening

```text
Read section 7 in full and the non-functional requirements in section 11.

Finish privacy and security:
- Privacy screen: see, correct, export and delete my data, and withdraw each
  consent. Every request is logged. Export and deletion also cover chat held
  by Stream and the wallet history.
- Account deletion that keeps only the keyed ID hash on the ban list, open
  reports, and transfer records for as long as the law requires (ask me for
  the lawyer's answer). The wallet must be empty before an account is
  deleted.
- Active devices and recent logins with sign-out for each. App lock with
  Face ID or fingerprint.
- New phone login: sign out the old phone, email the parent, and ask for a
  fresh selfie before chats, the wallet and child data open.
- Alerts to admins when an account opens many profiles, sends many chat
  requests, searches many areas or looks up many parent IDs quickly.
- Retention job for every data type in section 7, with a report when a
  deletion fails.
- Point-in-time recovery and daily backups switched on, with a written
  restore test.
- Sentry: a test proves that no phone number, ID number, coordinate or
  message text reaches it. Alert me on new errors in sign-in, trips and the
  wallet.
- Offline: today's schedule and pickup list readable without a connection;
  confirmations queue and send once.
- A SECURITY.md checklist against the OWASP mobile standard (MASVS), each
  item marked done or open, a list of every outside service with the data it
  receives, and an incident plan with the 72-hour breach report.

Done when: on my iPhone I export my data, delete a test account and see only
the ban-list hash and its transfer records remain, lock the app with Face
ID, and see a second device listed. All rules tests pass.

Plan and questions first. Wait for my "go".
```

### Prompt 13: iPhone test release

```text
Read Phase 5 in section 12.

Prepare the iPhone app for testers:
- Staging build signed and uploaded to TestFlight from Codemagic, with the
  live location license key in the release build.
- App Store privacy answers drafted from the data the app really collects,
  including what Stream, Algolia, Sentry, Valify and the wallet partner
  receive.
- The explanation text for the location, camera and notification
  permissions, in Arabic and English.
- A design pass on every screen with the Design check helper prompt.
- A test script in docs/test-iphone.md that walks through every feature ID
  with the expected result.
- A list of every open item, known bug and missing account (WhatsApp
  templates, Valify, the wallet partner, lawyer's answers).

Done when: I install the staging app from TestFlight on my iPhone and finish
the test script with two test accounts.

Plan and questions first. Wait for my "go".
```

## Stage 2: Website

Two prompts open the same app in a browser once the iPhone test script passes.

### Prompt W1: Parent app in the browser (F42)

```text
Read F42 and the rules file. The iPhone app is complete; now make the same
app work as a website.

- Responsive layouts for phone, tablet and desktop widths, in Arabic and
  English, light and dark, following the DESIGN rules.
- Registration, verification, the school search, maps, carpools, schedule,
  chat, the Notifications tab and the live trip map all work in Chrome,
  Safari and Edge.
- ID and selfie capture with the browser camera. Where a browser cannot do
  the liveness check, show "continue on your phone".
- Starting a run, live location sharing and the Arrived button are hidden on
  the website, with a message to use the phone app.
- Wallet on the website: balance and history only. Sending money stays in
  the phone app.
- App Check for web, a Maps key restricted to the site's domain, strict
  security headers, and Sentry switched on for the website.
- Notifications on the website: the in-app list and WhatsApp. Browser push is
  optional.
- Deploy to Firebase Hosting on staging. The admin panel stays on its own
  address.

Done when: I register and verify a test parent in a desktop browser, join a
carpool, chat, and watch a run that I start from my iPhone. The site works in
Arabic right-to-left.

Plan and questions first. Wait for my "go".
```

### Prompt W2: Website checks and release

```text
Test and release the website:
- Cross-browser test run on Chrome, Safari and Edge, at desktop and phone
  sizes, written up in docs/test-web.md.
- Fix the layout and right-to-left issues found.
- Confirm that a signed-out or unverified visitor sees nothing but the
  sign-in and verification pages.
- Page speed check on a slow connection; shrink the first load where it is
  slow.
- Production hosting with the custom domain, set up but not switched on
  until I say so.

Done when: the write-up shows every feature passing in the three browsers,
and I can open the staging site on my laptop and my phone.

Plan and questions first. Wait for my "go".
```

## Stage 3: Android

Two prompts finish Android after the website passes.

### Prompt A1: Android platform work

```text
The iPhone app and the website are complete. Now finish Android.

- Run the full app on Android 8 and later and fix what differs from iPhone.
- Live location during a run through flutter_background_geolocation as a
  foreground service with a visible notification, so it survives a locked
  screen, with the Android license key in release builds. Ask for
  permissions after the explanation screen.
- Notification channels for reminders, trip alerts, chat and the wallet,
  with sound on the Arrived alert.
- App Check with Play Integrity. Maps key restricted to the app's package and
  signing key.
- Invite links open the app on Android.
- A short in-app guide for phones that stop background apps, shown when a
  driver first starts a run.
- Camera capture, screenshot blocking, and app lock with fingerprint,
  including the check before a wallet transfer.

Done when: on an Android phone I register, start a run with the screen
locked while my iPhone shows the car moving, receive the Arrived alert with
sound, and send a test transfer after a fingerprint check.

Plan and questions first. Wait for my "go".
```

### Prompt A2: Android test release

```text
Prepare the Android app for testers:
- Staging build uploaded to Google Play internal testing from CI.
- Data safety answers drafted from the data the app really collects.
- Drafts of the location and foreground service declarations Google Play
  asks for.
- docs/test-android.md: the iPhone test script adapted for Android.

Done when: I install the app from the Play internal testing link and finish
the test script.

Plan and questions first. Wait for my "go".
```

## Helper prompts

Four short prompts keep the build on track between the main ones.

### When a check fails

```text
This check failed: [what I did, what I expected, what happened, on which
device].

Find the cause before changing anything. Tell me the cause, the smallest fix,
and which test you will add so it cannot come back. Wait for my "go".
```

### Before moving to the next prompt

```text
Review what you built in this prompt against docs/spec.md and the rules file.
List anything missing, anything that breaks a security, privacy, money or
design rule, any string not translated, and any feature ID without a test.
Do not fix anything yet; give me the list.
```

### Design check

```text
Check every screen you built in this prompt against the DESIGN rules in the
rules file. For each screen give me screenshots in Arabic and English, light
and dark, on the smallest and the largest phone size, and with large text.
List anything that breaks a rule: hard-coded colors or sizes, a missing
loading, empty, error or offline state, more than one primary action, small
touch targets, weak contrast, or text that is cut off. Do not fix anything
yet; give me the list.
```

### At the start of a new session

```text
Read the rules file and docs/spec.md. Then summarize the state of the project
from the code and the last commits: what is done, what is in progress, and
what the next prompt needs. Do not change anything.
```
