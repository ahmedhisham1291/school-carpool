# School Carpool App – Product & Technical Spec

Oct 30, 2026 · @Ahmed Hisham

## 1. Overview

A free, non-profit iPhone, Android and web app that lets parents in Egypt who share a school and an area take turns driving each other's children to and from school.

**Problem:** Private school buses in Egypt are very expensive, and many parents do not trust stranger drivers.

**Solution:** Parents of the same school and neighborhood organize carpools among themselves. Each parent drives on some days; others cover the remaining days.

**Principles**

- Non-profit at launch: the app takes no fees or commissions; money moves only between parents' wallets, which a licensed payment partner runs; parents may agree an optional cost contribution per child among themselves; revenue is considered only after the app has many active families (section 13).
- Parent-to-parent only: the app connects and coordinates parents; it does not cooperate with or depend on schools.
- Trust first: every user is identity-verified before using the app.
- Adults only: children never have accounts.

**Goals**

- Parents can find nearby parents from the same school and form a carpool group.
- Parents can set arrival and departure times and a fair rotation of driving days.
- Parents can chat privately and in school and area groups.
- Only verified parents can join.

**Non-goals (v1)**

- Holding parents' money ourselves (a licensed payment partner runs the wallet), driver salaries or commissions
- Integration or approval from schools
- Professional drivers or commercial transport
- Child accounts or child-facing features
- Driving a run from the website (drivers use the phone app)

## 2. Core concept and user flows

A **carpool group** is tied to one school, one area and fixed morning and afternoon times. Members share driving days. Everything else (chat, notifications, trip tracking) supports that group.

**Flow A: Create a carpool group**

1. Parent completes registration and verification.
2. Parent sets their location on a Google Maps map and picks their children's school on the map or from the list and every other school they can drive to.
3. Parent sets arrival time (morning) and departure time (afternoon).
4. Parent selects the days they can drive, number of seats available and which of their children ride.
5. The group appears in search for other verified parents of the same school and area.

**Flow B: Join a carpool group**

1. Parent searches by school, area and times.
2. Parent sends a join request with their children's details.
3. The group admin (creator) approves or declines.
4. The parent chooses which days they will drive; the app proposes the remaining days automatically.

**Flow C: Daily trip**

1. Reminder to the day's driver the evening before and one hour before pickup.
2. Driver turns on live location and starts the run; the run cannot start without it. Parents of the children on that run follow the car on the map.
3. At each home the driver taps Arrived, and the child's parents get an alert to send the child down to the car.
4. Driver confirms each child picked up and each child dropped at school (and the same for the afternoon).
5. Parents get a notification at each confirmation.

**Flow D: Swap or substitute**

1. A driver who cannot drive requests a swap for a specific day.
2. Group members are notified; any member can accept.
3. If nobody accepts by a set cut-off, the app notifies the whole group and the parent of each child.

**Flow E: Chat**

1. Private chat between two verified parents.
2. School group chat for all verified parents of that school.
3. Area sub-group inside each school.
4. Carpool group chat for the members of one carpool.

## 3. Registration and verification

No one can see groups, chat or other parents until their account is verified.

**Registration steps (in order)**

1. Phone number with a one-time code sent by WhatsApp.
2. Email with a confirmation link.
3. Parent national ID: photo of the front and the back.
4. Live selfie taken in-app with a liveness check (blink or turn head); no gallery upload. The selfie is matched automatically to the ID photo.
5. Child details for each child: name, age, grade, school (picked from the schools list, or typed under "Other" when it is missing) and a photo of the child's school ID card.
6. Required before a parent can be given any driving day (parents who never drive skip it): driver's license photo and car details (plate, model, color, seats).

**Verification states**

| State | Meaning | Access |
| --- | --- | --- |
| Unverified | Registered, documents not yet submitted | Profile only |
| Pending | Documents submitted, under review | Profile only |
| Verified | Identity and school confirmed | Full app |
| Rejected | Check failed, reason shown | Can resubmit |
| Suspended | Removed by admin or after reports | None |

**Rules**

- Use the child's **school ID card**, not the child's national ID or birth certificate, to limit sensitive data.
- Other parents only see a "Verified" badge, first name, school and area. They never see ID images.
- At launch an eKYC provider that supports Egyptian IDs scans the ID and matches the selfie, and an admin confirms each decision.
- ID images are encrypted, access-limited, and deleted after review. Only the result and minimal fields are kept.
- Re-verify when the phone number or the car changes.
- Parent–child link: the reviewer checks that the child's full name on the school ID contains the father's name from the national ID (for a mother, the husband's name on the back of her ID). If it does not match, the parent shows a birth certificate, which is viewed and not stored.
- The back of the national ID shows religion, marital status and job. The app needs none of them: record only the expiry date and never copy the other fields into the database.
- Drivers need a valid driver's license and car license. Store both expiry dates, remind the parent before expiry, and block driving days after it.
- The child's school ID photo and the driver's license photo are deleted after review like the parent's ID. Only the result and the expiry dates are kept.
- Re-verify every school year: before the first term each parent confirms children, grades and schools. A child who left a school leaves its groups and chats.

## 4. Features by priority

MVP means the first release for one pilot neighborhood and school. Every feature in this table is built for that first release.

| ID | Feature | Priority | Acceptance criteria |
| --- | --- | --- | --- |
| F1 | Registration with WhatsApp OTP and email confirmation | MVP | A user can register; wrong or expired codes are rejected |
| F2 | ID and selfie verification with admin review | MVP | Submitted documents appear in an admin queue; admin can approve or reject with a reason; user sees the result |
| F3 | Child profiles with school ID photo | MVP | A parent can add, edit and remove children |
| F4 | School and area selection | MVP | A list of Egyptian schools is loaded before launch and kept by admin, with the area list; the parent searches it in Arabic or English and picks exactly one school per child; when the school is missing, the parent chooses "Other" and types its name, and an admin approves or merges it |
| F5 | Create carpool group (school, area, times, days, seats) | MVP | Group appears in search for verified parents of the same school |
| F6 | Search and join request with admin approval | MVP | Creator receives request and can approve or decline; member is notified |
| F7 | Turn schedule: weekly rotation of driving days | MVP | App proposes a fair rotation; members can adjust their days; every morning and afternoon run has one confirmed driver |
| F8 | Private chat (parent to parent) | MVP | Messages delivered in real time with push notifications; block and report available |
| F9 | School group chat and area sub-groups | MVP | Only verified parents of that school can join; area sub-group is created automatically |
| F10 | Carpool group chat | MVP | Created with the group; members only |
| F11 | Swap or substitute request | MVP | Request notifies members; an accepted swap updates the schedule |
| F12 | Daily reminders and notifications by app push and WhatsApp | MVP | Driver reminded the evening before and one hour before; parents notified on swaps; every trip and schedule notification goes to the app and to WhatsApp, and chat messages notify in the app only |
| F13 | Report and block users | MVP | Reports reach an admin queue; blocked users cannot message the blocker |
| F14 | Admin panel (web) for verification, reports, schools, areas | MVP | Admin can review documents, suspend users and manage lists |
| F15 | Trip start/end with required live location sharing | MVP | Driver location visible to parents of children on that trip only during the trip; a run cannot start until the driver turns live location on, and those parents are alerted if sharing stops before the last child is dropped |
| F16 | Pickup and drop-off confirmation per child | MVP | Parents are notified at each confirmation |
| F17 | Ratings and vouching between parents | MVP | Only after shared trips; one rating per pair per month |
| F18 | Automated eKYC provider | MVP | Replaces or supports manual review |
| F19 | Arabic and English with RTL support | MVP | All screens work in both languages and directions |
| F20 | Emergency button to alert the group and a saved emergency contact | MVP | One tap sends an alert with location |
| F21 | Google Maps location picker: parent sets home or pickup location by pin or address search | MVP | Location is saved as an approximate point; the exact address is never shown to other parents |
| F22 | Nearby parents map: shows verified parents of the same school within a chosen radius | MVP | Map shows blurred markers; filter by school and radius; tapping a marker shows first name, Verified badge and Message or Join buttons |
| F23 | New-parent notification: nearby parents are notified when a new parent is verified | MVP | Sent only after verification, only to verified parents of the same school within their radius; can be turned off in settings |
| F24 | Driving schools: a parent chooses every school he can drive to | MVP | Parent selects one or more schools; search, map and notifications respect this list |
| F25 | Optional contribution per child: amount in EGP and period (per trip, week or month) | MVP | Shown on the carpool and accepted by the joining parent; paid between parents in cash, by Settle up (F45) or, once it is switched on, from the wallet (F43); nothing is taken automatically |
| F26 | Driver consent: each parent approves each driver who will carry their child | MVP | A new member cannot drive other children until each parent has accepted; a parent can withdraw consent at any time; parents are prompted to meet before the first ride |
| F27 | Child absent today: a parent marks a child as not riding | MVP | Driver and group are notified; the child leaves that day's pickup list |
| F28 | Driver confirmation before each run | MVP | The driver confirms by a set time; with no confirmation every parent in the group is alerted to arrange their own trip |
| F29 | Handover list: adults allowed to receive each child at drop-off | MVP | The driver sees the names for each child; a parent can add or remove an adult at any time |
| F30 | Schedule exceptions: holidays, exam days, early dismissal and Ramadan times | MVP | The group admin sets a no-school day or a one-off time change; reminders and driving turns follow it |
| F31 | Invite link: a parent shares a link to a carpool or school group by WhatsApp | MVP | The link opens the app or the store; the invited parent must still be verified before seeing anything |
| F32 | Looking for a carpool: a parent with no group posts school, area and times | MVP | Verified parents of the same school and area see the request; the app suggests starting a group when three families match |
| F33 | Today's driver card: profile photo, car model, color and plate | MVP | Shown on the day to parents of that carpool only; the photo is approved during verification |
| F34 | Two-sided handover: the receiving parent confirms the child arrived | MVP | If the driver marks a child dropped and the parent does not confirm within 10 minutes, both are alerted |
| F35 | Quick driver buttons: running late, at the gate, all children in | MVP | One tap posts the message to the carpool chat; no typing while driving |
| F36 | Carpool rules shown before joining, for example no smoking or mothers-only drivers | MVP | The creator picks from a fixed list; rules appear in search results and on the join request |
| F37 | Drive balance: runs driven and received per family | MVP | Each member sees the term's balance; rotation and swaps favour the family that has driven least |
| F38 | Random driver selfie check before a run | MVP | The app sometimes asks the driver for a live selfie before starting; a mismatch pauses driving days and alerts an admin |
| F39 | Activity carpools: sports clubs, lessons and summer camps | MVP | A carpool can target an activity place and days instead of a school |
| F40 | School on the map: the parent picks each child's school on Google Maps or from the list | MVP | Each school has a map pin set by the admin; the parent's map shows their home pin and their children's school pins |
| F41 | Arrived button: the driver tells a child's parents the car is outside | MVP | One tap sends a push with sound and a WhatsApp message to the child's parents asking them to send the child down to the car; the tap is saved as a trip event; a second tap repeats the alert |
| F42 | Website: the parent app also runs in a browser | MVP | Registration, verification, carpools, schedule, chat and the live trip map work in Chrome, Safari and Edge; starting a run needs the phone app |
| F43 | Wallet: each parent has a wallet and can send money to another parent's wallet | MVP | Run by a payment partner licensed by the Central Bank of Egypt, which holds the money; add money, send to a parent chosen from a carpool or by parent ID, withdraw, and see history; every transfer needs the app lock, respects limits and cannot run twice; the app takes no cut |
| F44 | Parent ID: every parent has a unique ID | MVP | 8 characters, created at registration, unique and never reused, shown on the profile with a copy button; looking up an ID shows only the first name and the Verified badge |
| F45 | Settle up by InstaPay: payment requests between parents of one carpool | MVP (the pilot's payment feature) | A verified parent saves an InstaPay address (name@instapay) and asks another verified parent of a shared carpool to pay an amount (EGP, a reason, an optional note), or records a payment already made; the payer sees the address with a Copy button, pays in the InstaPay app and taps "I paid"; the payee taps "Received" (closed) or "Not received" (open again, counted; after 2 either side can report it); the payee can cancel and the payer decline an open request; the app never moves, holds or sees money and never asks for bank or card details; no fee and no commission; one record per request ID; the history is never edited or deleted by the app |
| F46 | Home address by City, Area and District (owner, 16 Nov 2026) | MVP | The parent enters the home address in short steps: City (governorate), Area (qism, markaz or new city) and District (neighbourhood) from filterable dropdown menus (Area waits for City, District for Area; changing one clears the ones below; the District list ends with "My district isn't listed", which takes a typed name for the admins to review), then street and building number (checked as typed), optional floor, apartment and landmark, then confirms the pin on a map (the server searches the address once; the parent moves the map under the pin). "Search instead" keeps the address search and fills City, Area and District from the chosen place. The exact pin, street and building are visible only to the parent (and, as today, the exact pickup point only to approved members of a carpool); other parents see the rounded point and the area. Schools are grouped the same way (City -> Area) for browsing and search filters (F4); admins manage the places (F14) |

## 5. Chat

Build chat on Stream Chat, a paid managed chat service with ready screens and moderation tools, instead of writing a messaging backend.

| Chat type | Members | Created | Notes |
| --- | --- | --- | --- |
| Private | Two verified parents | On first message | Phone numbers hidden; block and report |
| School group | All verified parents of one school | Automatically per school | Large, so mute by default after a set size; moderation tools |
| Area sub-group | Verified parents of one school in one area | Automatically per school and area | Main place to find neighbors |
| Carpool group | Members of one carpool | With the carpool | Daily coordination; swap requests appear as messages |

**Requirements**

- Text messages, photos and shared location pin. No voice or video calls in v1.
- Real-time delivery, read receipts, and push notifications with per-chat mute.
- Message history stored for moderation (retention period to be decided).
- Report any message; block any user; admins can remove messages and members.
- Only verified, non-suspended parents can read or write.
- Arabic and English text, RTL layout.
- Private chat starts with a request the other parent accepts. Limit new requests per day, and let a parent turn requests off.
- Photos only in private and carpool chats, not in school and area groups. The app removes location data (EXIF) from every photo before upload.
- Admins see only reported messages with a little context and never browse private chats. The privacy policy says chats are not end-to-end encrypted.

## 6. Trust, safety and moderation

- **Verified only:** unverified users see nothing beyond their own profile.
- **Group approval:** each carpool creator approves new members.
- **Minimal exposure:** other parents see first name, "Verified" badge, school, area and, once in a group, children's first names and grades. Never ID images, national ID numbers or home address.
- **Home address:** the map shows only an approximate location (rounded to roughly 500 meters) for other parents; the exact address is shared only inside the carpool group after joining, and only if the parent chooses.
- **Live location:** the driver must share live location on every run, from the start until the last child is dropped. Only parents of children on that run can see it, and it is off outside runs.
- **Arrival time:** parents watching a run see the expected arrival at their stop, updated with traffic.
- **Reporting:** report user, message or group with a reason; reports go to an admin queue with a target response time of 24 hours.
- **Enforcement:** warning, temporary suspension, or permanent ban; banned users cannot re-register with the same ID or phone number.
- **Backups:** if a driver is unavailable, the app alerts all members; no child should be left without a confirmed driver. If no driver is confirmed by the cut-off, each parent is told to take their own child that day; the app never assigns a driver who has not confirmed.
- **Code of conduct:** shown at registration and accepted by checkbox. Covers respectful chat, no advertising, no sharing of other parents' data, and punctuality.
- **Liability notice:** terms state that carpool arrangements are agreements between parents, and the app only connects them. Confirm wording with a lawyer.

* **Map visibility:** a parent can hide themselves from the nearby map in settings; hidden parents can still search and join groups.
* **New-parent alerts:** sent only after the new parent is verified, only to verified parents of the same school within their radius, with first name and school only, and can be switched off.
* **Contributions:** the amount per child is optional and shown openly; parents pay it in cash, by Settle up (F45) or, once it is switched on, from their wallet (F43); the app itself never holds money and takes no cut, and disputes are between parents.
* **Settle up (F45, the pilot's payment feature):** the app records payment requests between two verified parents of one carpool (requested, paid, received) and shows the payee's InstaPay address to the payer of an open request only. The money moves in the InstaPay app, never through ours: the app does not move, hold or see money and never asks for bank or card details. Suspended, banned, unverified or blocked parents cannot create requests; a parent who left the carpool can still finish the records that exist. A record that keeps bouncing can be reported to the admins, who review conduct; the app cannot recover money.
* **Feature switches:** the wallet, ratings and vouching, and the yearly check are switched off for the pilot, and Settle up is on. A super admin changes a switch in the admin panel (written to the audit log); the server refuses every call of a switched-off feature and the app hides it, with no new release. Sign-in, verification, carpools, the schedule, trips and alerts, and chat have no switch, and who may drive (verified, licence and car dates, suspension) never depends on a switch.
* **Wallet (switched off for the pilot; Settle up, F45, is used instead):** every verified parent has a wallet run by a licensed payment partner. A parent can add money, send to another parent chosen from a carpool or by parent ID, and withdraw. The receiver's first name and Verified badge are shown before sending, every transfer needs the app lock, and limits apply per transfer and per day. The app cannot reverse a transfer: problems go to a report and the partner's dispute process.
* **Parent ID:** every parent has a unique 8-character ID on the profile. It is what another parent types to find them for a transfer, and looking it up shows the first name and Verified badge only.
* **Who may drive:** only the verified parent whose license and car were checked. A spouse verifies separately and is linked to the same children. Hired drivers and unverified relatives never drive a carpool.
* **Seats:** the app blocks a run with more children than the car's passenger seats.
* **Handover:** in the afternoon the driver hands a child only to a parent or an adult the parent named in the app, and never leaves a child at an empty home. Parents tell the school themselves which carpool parents may collect their child.
* **Urgent reports:** a report about a child's safety, dangerous driving or an accident pauses the reported driver's driving days at once and is reviewed the same day. Those days become open swap requests, and the group is told only that the driver is unavailable.

## 7. Data privacy, security and legal

The app stores national IDs, face images and children's details, so privacy is a core requirement, not an extra.

**Technical controls**

- Encrypt all traffic (HTTPS) and all stored documents.
- Store ID and selfie images in a private bucket; only admin reviewers can open them, with an access log.
- Delete ID and selfie images after review; keep only status, date and reviewer.
- Store the national ID number as a keyed hash (HMAC, with the key in a secret manager) for duplicate and ban checks. A plain hash of a 14-digit number can be reversed by trying every number.
- Role-based access: parent, admin, super admin.
- Allow users to delete their account and all personal data.
- Rate-limit logins and OTP requests; lock accounts after repeated failures.
- Keep production secrets out of the app and the code repository.
- Add a privacy screen where a parent can see, correct, export and delete their data and withdraw each consent; log every request.
- Show active devices and recent logins in the profile with sign-out for each, and lock the app with fingerprint or face.
- Alert admins when an account opens many profiles, sends many chat requests or searches many areas in a short time.
- Deny all database and storage access by default (Firebase rules). Only Cloud Functions write status, role and verification fields; "verified" and "admin" are server-set claims on the login token. Test the rules automatically on every build.
- Wallet: every transfer runs on the server through the payment partner, carries a one-time request ID so it cannot run twice, needs a fresh app-lock check, and is limited per transfer and per day. The transfer record cannot be edited or deleted. Admins can freeze a wallet but cannot move money. Parent ID lookups are rate limited.
- Outside services get the least data they need: Stream holds chat text, first names and parent IDs; Algolia holds school names and places only; Sentry gets error reports with phone numbers, ID numbers, coordinates and message text removed. Their secret keys stay in Cloud Functions.
- Turn on App Check so only the real app reaches the backend. Cap WhatsApp codes per number, device and IP, store only a hash of each code, and expire it after 5 minutes. Restrict the Maps key to the app, and set quotas and budget alerts on every cloud project.
- Protect the admin panel: separate admin accounts with two-step login, short sessions, no document download, the reviewer's name watermarked on every ID image, and a log of every admin action that admins cannot edit.
- Treat a login from a new phone as risky: sign out the old phone, alert the user by email, and ask for a fresh selfie before chats and child data open. Phone numbers get recycled and SIM cards swapped.
- Round coordinates on the server before saving, and send other parents only the rounded point. Keep exact pickup addresses in a separate record that only approved members of that carpool can read. Limit home-location changes and map searches so nobody can sweep the map.
- Set a retention schedule and enforce it with a scheduled job: verification images deleted within 7 days of the decision (rejected ones, thumbnails and backups too), live trip locations within 24 hours, chat and logs after the chosen period. A deleted account keeps only the keyed ID hash on the ban list and open reports, and the privacy policy says so.
- On the phone: never save ID captures to the gallery, keep login tokens in Keychain and Keystore, block screenshots on document screens, and send push notifications without child names, addresses or message text.
- Use only fake data in development and staging. Before the pilot, run a penetration test and a check against the OWASP mobile standard (MASVS) on the app, the rules and the admin panel.
- Back up the database daily and test a restore. Write an incident plan that names who decides, who tells users, and how the 72-hour breach report to the Personal Data Protection Center is made.

**Legal checklist (confirm with an Egyptian lawyer)**

- Egypt's Personal Data Protection Law (Law 151 of 2020): consent, purpose limits, security duties, and any registration or licensing the law requires for a data controller.
- Privacy policy and terms of use in Arabic and English, accepted at registration.
- Explicit consent for ID, face and children's data.
- Insurance: whether the driver's car insurance covers children of other families.
- Apple App Store and Google Play rules for apps with user-generated content: report, block, and account deletion must exist; apps with kids' data need a clear privacy label.
- Live location: the driver consents in writing, only parents of children on that run can see it, and the points are deleted within 24 hours. Ask the lawyer to confirm this fits the Regulations' limits on tracking children ([summary](https://www.tamimi.com/law-update/general/articles/from-policy-to-practice-egypt-issues-executive-regulations-of-the-personal-data-protection-law/)).
- The law's Executive Regulations ([Ministerial Decree 816 of 2025](https://cms.law/en/are/legal-updates/egypt-s-pdpl-executive-regulations-issued-one-year-compliance-countdown-begins), issued 1 November 2025) are out, and their one-year grace period ends by the end of 2026 at the latest (1 November 2026 on a strict reading). Plan for a license from the Personal Data Protection Center, a registered data protection officer, written guardian consent in Arabic for children's data, a consent register and a 72-hour breach report.
- Hosting abroad: Firebase, Stream (chat), Algolia (school names only) and Sentry (error reports) keep data outside Egypt, and the Regulations require a license or permit to store or transfer personal data abroad ([summary](https://www.tamimi.com/law-update/general/articles/from-policy-to-practice-egypt-issues-executive-regulations-of-the-personal-data-protection-law/)). Settle this with the lawyer before choosing the hosting region and each vendor.
- Wallet: holding parents' money and moving it between them is a payment service that needs a Central Bank of Egypt license ([rules of June 2025](https://insightplus.bakermckenzie.com/bm/banking-finance_1/egypt-new-regulation-on-payment-solutions); [minimum capital of EGP 10 to 30 million](https://www.dailynewsegypt.com/?p=833461)). The app therefore uses a licensed bank or payment company as its partner and never holds money itself. Ask the lawyer whether the partner's license covers this use, which identity checks the partner needs from parents, and whether paid contributions change how the ride-hailing law sees the app.
- Schools list: data taken from OpenStreetMap carries the Open Database License. Credit OpenStreetMap in the app, and ask the lawyer what the license's share-alike term means for our list.
- Operator: decide which registered entity (association, foundation or company) owns the app, holds the license, signs the terms and carries liability. [Law 151](https://eg.andersen.com/wp-content/uploads/2026/02/Law-No.-151-of-2020.pdf) defines the license as issued to a legal entity.
- Transport law: confirm that an optional cost contribution does not bring a parent or the app under the 2018 law that licenses ride-hailing companies and their drivers ([brief](https://timep.org/2019/02/12/timep-brief-uber-and-careem-law/)).

## 8. Technical architecture and stack

One cross-platform mobile codebase plus a small managed backend keeps cost and effort low for a non-profit project.

| Layer | Recommendation | Why |
| --- | --- | --- |
| Mobile app | Flutter | One codebase for iPhone, Android and the website; good RTL support |
| Auth | Firebase Authentication (Identity Platform tier) with WhatsApp one-time codes (created by Cloud Functions) and email | Ready-made sessions; WhatsApp codes cost far less than SMS; the paid tier adds two-step login for admins |
| Database | Firestore, with point-in-time recovery and daily backups | Real-time updates, offline reading and no servers to run; data can be restored to any minute of the last 7 days |
| File storage | Cloud Storage for Firebase, private bucket | Encrypted ID and selfie images, signed URLs |
| Chat | Stream Chat (paid) | Ready chat screens, reliable delivery and built-in moderation; no custom messaging backend |
| Push notifications | Firebase Cloud Messaging and Apple Push (APNs) | Both platforms |
| WhatsApp messages | WhatsApp Business Platform with approved message templates | Verification codes and notifications; SMS is not used |
| Maps and location | Google Maps Platform: maps, Places address search and Routes arrival times | Location picker, address search, nearby search within a radius, distance to school, arrival times that follow traffic, live trip location |
| Live location on the phone | flutter\_background\_geolocation (paid license) | Keeps the driver's location flowing with the screen locked on iPhone and Android, with low battery use |
| Backend logic | Cloud Functions, second generation, with instances kept warm for sign-in, alerts and the wallet (verification workflow, rotation, reminders, transfers) | No server to manage, and no slow first response |
| Admin panel | Flutter web app in the same project | Review documents, reports, manage lists |
| Website hosting | Firebase Hosting | Serves the parent website and the admin panel |
| Face match and ID scan | Valify, an Egyptian eKYC provider, at launch (to confirm with a demo and a contract), with admin review | Reads the Egyptian national ID in Arabic, with face match and a liveness check; paid per check |
| Analytics and crash reports | Sentry (paid plan) | One place for errors from the apps, the website and Cloud Functions, with personal data removed first |
| Languages | Arabic (default) and English, RTL | Target users in Egypt |
| Nearby search | Geohash or geo queries on stored approximate points, plus Cloud Functions for new-parent alerts | Finds parents within a radius without exposing exact coordinates |
| School search | Algolia | Instant search in Arabic and English that tolerates spelling differences, across tens of thousands of schools |
| Wallet | A payment partner licensed by the Central Bank of Egypt, behind one interface | The partner holds the money and runs the transfers; the app only sends instructions and shows balances |
| Builds and releases | Codemagic (paid plan) | Builds, signs and uploads the iPhone, Android and web apps in the cloud on every change |

**Environments:** development, staging and production, each with a separate project and database.

**Release:** Apple Developer account (paid yearly) and Google Play developer account (one-time fee) are required before store submission.

## 9. Data model

| Entity | Key fields | Relations |
| --- | --- | --- |
| User (parent) | id, parent ID (public, 8 characters, unique), first name, last name, phone, email, status (unverified, pending, verified, rejected, suspended), language, created at | Has many children, memberships, messages |
| Verification | id, user id, ID front image, ID back image, selfie image, result, reviewer, reason, reviewed at | Belongs to user; images deleted after review |
| Child | id, parent id, first name, age, grade, school id, school ID checked (yes or no) | Belongs to user and school |
| School | id, Arabic name, English name, governorate, city, source, status (active, awaiting review, merged), added by, map location (latitude and longitude), place area id and name, place district id (F4 grouping, F46), hidden from search (sample), admin search grams (server only: word starts of the normalized names for the admin panel search) | Has many areas, groups; in one place area |
| Place area (City -> Area) | id, governorate (the City), Arabic and English names, centre, school count, active, merged into; server only (placeInternal, never read by the app): source (OpenStreetMap or admin), outline (simplified), address count (admins see it through the admin panel) | Many per governorate; has many place districts. Not the per-school Area below (owner decision 16 Nov 2026: both kept) |
| Place district | id, place area id, governorate, Arabic and English names, centre, school count, active, merged into; server only (placeInternal): source (OpenStreetMap boundary, named place, admin), outline, address count | Belongs to a place area |
| District request | user id, place area id, typed name, status (open, done) | "My district isn't listed" (F46); admins add, map or dismiss it; deleted with the account |
| Home address | user id, place area id, place district id or typed district, street, building, floor, apartment, landmark, exact location | Private: only the parent reads it; written only by Cloud Functions (F46); the pin must be inside the chosen area's outline or within 300 m of it (an area without an outline accepts any pin) |
| Area | id, school id, name, center point | Belongs to school |
| Vehicle | id, driver id, plate, model, color, seats, driver's license expiry, car license expiry | Belongs to user |
| Carpool | id, school id, area id, creator id, morning arrival time, afternoon departure time, active days, seats, status | Has many members, schedule entries |
| Membership | id, carpool id, user id, role (admin, member), status (requested, approved, declined, left), driving days | Links users and carpools |
| Carpool child | membership id, child id | Which children ride in which carpool |
| Schedule entry | id, carpool id, date, direction (to school, home), driver id, status (planned, swapped, completed, missed) | One driver per carpool, day and direction |
| Swap request | id, schedule entry id, requester id, accepted by, status | Updates schedule entry |
| Trip | id, schedule entry id, direction (to school, home), started at, ended at | Belongs to schedule entry |
| Trip event | id, trip id, child id, type (driver arrived, picked up, dropped), time | Belongs to trip and child |
| Trip location | trip id, latitude, longitude, time | Live points during a run; seen only by parents of children on that run |
| Chat | id, type (private, school, area, carpool), members | Managed by Stream Chat |
| Report | id, reporter id, target type, target id, reason, status, handled by | Admin queue |
| Block | id, blocker id, blocked id | Prevents messaging |
| Notification | id, user id, type, payload, read, channels (push, WhatsApp) | Push, in-app and WhatsApp |
| Parent location | user id, approximate latitude and longitude (rounded), geohash, area id, governorate, place area id and place district id (F46), search radius in km, show on map (yes or no), notify about new parents (yes or no) | Belongs to user; the exact address is never in it (it stays in the private home address) |
| Driving school | user id, school id | Links a parent to every school he can drive to |
| Contribution | carpool id, amount per child, currency (EGP), period (trip, week, month), note | Agreement only; paying it is optional, in cash, by Settle up or by a wallet transfer |
| Settle-up record | id, request ID, payee, payer, first names, carpool id, amount, currency (EGP), reason (contribution, fuel, other), note, status (open, paid, closed, cancelled, declined), "not received" count, history (requested, paid, received and so on, with the side and time) | Written only by Cloud Functions; read only by its two parties; never the money, never an InstaPay address |
| InstaPay address | user id, address (name@instapay), updated at | Private: Cloud Functions only; shown to its owner and to the payer of an open request from that payee; deleted with the account |
| Feature switches | wallet, ratings and vouching, yearly checks, Settle up (on or off) | One server document; parents read it, only Cloud Functions write it |
| Wallet | user id, partner wallet reference, status (active, frozen), balance copy, updated at | One per verified parent; the payment partner's record is the truth |
| Transfer | id, request ID, from user, to user, amount, currency (EGP), note, carpool id (optional), status (pending, done, failed), partner reference, created at | Written only by Cloud Functions; never edited or deleted |
| Consent record | user id, type (terms, privacy, ID, face, child data, WhatsApp messages), document version, accepted at, withdrawn at | Proof of each consent, kept as the law requires |
| Audit log | id, actor id, action, target, time, IP address | Append-only record of admin and security events |
| Guardian link | child id, user id, relation (father, mother, guardian) | Lets two verified parents share the same children |
| Driver consent | carpool id, parent id, driver id, accepted at, withdrawn at | A driver carries a child only with that parent's consent |
| Authorized adult | child id, name, phone, relation | Who may receive the child at drop-off |

## 10. Screens and navigation

**Onboarding and registration**

1. Welcome and language choice
2. Phone number and OTP
3. Email and confirmation
4. Terms, privacy policy and code of conduct
5. ID front and back capture
6. Live selfie with liveness check
7. Add child (details and school ID photo)
8. Driver details (license and car), required before driving
9. Verification status (pending, approved, rejected with reason)

**Main app (bottom tabs)**

- **Home:** today's trips, upcoming driving days, pending requests
- **Carpools:** my groups, search, create group
- **Chats:** private, school, area and carpool chats
- **Notifications:** swaps, join requests, reminders
- **Profile:** my details and parent ID, children, vehicle, Settle up (F45: my InstaPay address, what I owe and am owed per parent, open and finished requests, a new request in three steps, a request's page with the address, Copy and the steps to pay in InstaPay), wallet (when switched on), settings, language, delete account

**Carpool screens**

- Search by school, area and time; results list
- Create carpool: school, area, times, days, seats, children
- Carpool detail: members, weekly schedule, chat, swap request
- Join request and approval
- Schedule and rotation editor
- Swap request and accept
- Trip screen with live map, Arrived button, and pickup and drop-off confirmation

**Chat screens**

- Chat list, conversation, group info, report and block

**Map and location**

- Location picker on Google Maps with pin, address search and "use my current location"
- School picker on Google Maps with school pins and search by name
- Live trip map for parents: the driver's car, the route and the children on board
- Nearby parents map with school filter, radius slider and blurred markers
- Parent card from a marker: first name, Verified badge, school, Message and Join buttons
- My driving schools: multi-select list of schools
- Contribution settings when creating a carpool: amount per child and period
- Settings: map visibility and new-parent alerts on or off, WhatsApp notifications on or off by type

**Admin web panel**

- Verification queue with document viewer, approve and reject
- Reports queue
- Users list with suspend and ban
- Schools and areas management. The Schools list (English by default)
  covers every school, including hidden sample schools, schools awaiting
  review and merged ones (switch "Show hidden and unapproved"): search by
  name in Arabic or English (spelling variants such as ة/ه, ى/ي, أ/إ/ا
  and small typos are found), filters City -> Area -> District (dependent
  dropdowns; changing one clears the ones below), status, visibility in
  the parents' search and source, sort by Arabic or English name, a count
  of matches, pages of 50, "Clear filters", and every filter in the
  address (bookmarkable). Table columns: Arabic name, English name, City,
  Area, District, source, status. Served by `adminSearchSchools` (admin
  only, rate limited, first page of each search in the audit log without
  the typed text); Firestore, not Algolia, so hidden schools are found too.

## 11. Non-functional requirements, risks and open questions

**Non-functional requirements**

- Works on iOS 15+, Android 8+ and current Chrome, Safari and Edge; runs well on low-end phones and weak connections.
- Arabic first with full RTL; English second.
- Chat messages delivered within 2 seconds on a normal connection.
- Verification decision shown to the user within 48 hours in the pilot.
- Crash-free sessions above 99%.
- Monthly running cost kept as low as possible; target to be set after the pilot.
- Live location keeps working when the phone is locked or another app is open, sends a point every 5 to 10 seconds, and is tested for battery use on low-end phones. It needs the background location permission, asked after a clear explanation screen.
- Critical alerts (no driver for tomorrow, child not confirmed) also sound an in-app alarm when neither the push nor the WhatsApp message is opened in time; many Android phones stop background apps.
- Design: a modern, calm and consistent look on every screen from one design system; Arabic-first right-to-left layouts; light and dark themes; loading, empty, error and offline states on every screen; contrast at WCAG AA and text that scales; driver screens readable at a glance.
- Weak connections: today's schedule and pickup list work offline, confirmations queue and send once without duplicates, and ID photos are compressed on the phone with resumable upload.

**Risks**

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Accident involving other families' children | Very high | Terms, insurance check with lawyer, driver license and car checks, clear code of conduct |
| Fake or stolen identity | High | ID plus liveness selfie, manual review, ban list |
| Leak of ID and face images | Very high | Encryption, deletion after review, access logs, minimal storage |
| Driver cancels at the last minute | High | Swap flow, alerts to all members, backup driver option |
| Too few users in one area | Medium | Start with one school and neighborhood, invite parents directly |
| Abuse in chat | Medium | Report and block, admin removal, verified-only access |
| Monthly costs with no revenue | Medium | Light stack, free tiers, donations or sponsors later if needed |
| Charging money per child | High | Keep it optional and display-only with no in-app payment; ask a lawyer whether charging makes a parent a commercial transporter needing a license or different insurance; terms describe it as cost sharing |
| Map shows where families live | High | Approximate rounded locations only, verified users only, hide-from-map option, no exact address until the parent shares it |
| Wallet misuse: fraud, a stolen phone, or a dispute over a transfer | High | A licensed partner holds the money; app lock before every transfer; limits per transfer and per day; the receiver's name is shown before sending; admins can freeze a wallet; transfer reports and the partner's dispute process |
| No wallet partner is signed by launch | High | Start talks in Phase 0; the wallet sits behind one interface, so the rest of the app can launch with the wallet switched off and contributions paid in cash |
| Schools list is incomplete or has duplicates | Medium | "Other" option with admin review and merge; add official lists as they are obtained |
| Paid services raise the monthly bill before there is any income | Medium | Budget alerts on every service; each vendor sits behind an interface so it can be swapped; review the bill after the pilot |
| Live location stops during a run (battery, no signal, or the driver switches it off) | High | A run cannot start without it; parents are alerted when it stops; pickup and drop-off confirmations still work |
| An adult who is not the child's parent, or a hired driver, does the driving | Very high | Parent–child name check, driver consent per parent, only verified parents drive, handover list |

**Open questions**

- Which school and neighborhood is the pilot?
- Who reviews verifications in the pilot, and how fast?
- How long are chat messages kept?
- Can a parent drive without verifying a car, for example in a family car not registered in their name?
- Are there age or grade limits for children riding in a private car?
- Valify is the first choice for the ID check: confirm in a demo its price per check, where it stores images and how long it keeps them.

* What search radius is the default for the nearby map and new-parent alerts (for example 3 km)?
* Is the contribution fixed per carpool or can each driver set his own amount per child?
* Is the Google Maps cost acceptable at pilot scale (since March 2025 Google gives a free number of calls per Maps product each month instead of the $200 credit; [check each product the app uses](https://developers.google.com/maps/billing-and-pricing/march-2025))?
* After ID images are deleted, what identifies a parent to the police if a child is harmed: the ID number kept encrypted for legal requests, or only name and phone?
* Which licensed payment partner runs the wallet, and what are its fees, limits and identity checks? The wallet cannot open to parents before that contract is signed.
* Stream, Algolia and Sentry keep data outside Egypt: confirm with the lawyer that the cross-border permit covers each one, and pick the nearest data region each offers.
* Are Huawei phones without Google services supported? Firebase push and Google Maps do not work on them.
* A parent whose number has no WhatsApp cannot get a code or notifications; is that acceptable for the pilot?

## 12. Implementation phases for task breakdown

Give this document to an AI and ask it to turn each phase below into small tasks with estimates, dependencies and acceptance criteria, using the feature IDs in section 4. Build and test each phase on iPhone first, then the website, then Android.

1. **Phase 0, Foundation:** create Firebase projects for development, staging and production, set up the Flutter project, Arabic and English localization with RTL, design system, navigation shell, and CI builds for iPhone, web and Android, a verified WhatsApp Business account with approved message templates, accounts for Stream, Algolia, Sentry, Codemagic and Valify, first talks with a wallet partner, App Check, deny-by-default database rules with automated tests, quotas and budget alerts, fake data only outside production, and the lawyer's answers on license, hosting abroad and operator entity before any real ID is collected.
2. **Phase 1, Accounts and verification (F1 to F4, F13 partly, F14, F44):** WhatsApp OTP and email, registration screens, ID and selfie capture, child profiles, parent ID, the Egyptian schools list with search and "Other", areas data, private document storage, admin panel with verification queue, two-step login and action log, keyed ID hash, scheduled deletion of verification images, verification status screens.
3. **Phase 2, Carpools (F5 to F7, F11, F12, F21 to F32, F36, F37, F39, F40):** Google Maps location picker, school pins on the map, nearby parents map, new-parent notifications, driving schools, optional contribution per child, create and search carpools, join requests and approval, rotation algorithm, schedule screens, schedule exceptions, driver consent, child absent flag, driver confirmation before each run, handover list, swap requests, push and WhatsApp notifications and reminders, invite links, looking-for-a-carpool list, carpool rules, drive balance, activity carpools.
4. **Phase 3, Chat (F8 to F10, F13):** integrate Stream Chat, private chat, school and area groups, carpool chat, report and block, admin moderation tools.
5. **Phase 4, Trips and trust (F15 to F18, F20, F33 to F35, F38, F41, F43, F45):** required live location and trip tracking, Arrived button, today's driver card, two-sided handover, quick driver buttons, random driver selfie check, pickup confirmations, ratings and vouching, automated eKYC, emergency button, wallet and transfers, Settle up by InstaPay (the pilot's payment feature; the wallet stays switched off until the partner contract).
6. **Phase 5, Hardening and pilot:** penetration test and MASVS check, restore drill, privacy policy and terms, deletion of ID images after review, store listings, testing on iPhone (TestFlight), then the website, then Android (Play internal testing), pilot with one school and neighborhood, feedback fixes.
7. **Phase 6, Public launch:** App Store and Google Play release, support channel, monitoring and moderation routine.

**Suggested prompt for the AI**

```markdown
You are a senior product manager and tech lead. Read the attached spec for a free school carpool app for parents in Egypt (Flutter, Firebase, Arabic first). Break each phase into small, ordered tasks (each under one day of work), with dependencies, acceptance criteria, and feature IDs from section 4. Flag anything unclear or risky before listing the tasks.
```

The step-by-step build prompts are in [School Carpool App – Build Prompts](https://claude.ai/artifact/PV6NvUK4H2RcJbPw9Ls67A).

## 13. Running costs and revenue options

Verification codes and notifications go by WhatsApp, which costs about 33 times less per message than a Firebase SMS; SMS is not used. The app launches free and non-profit. Revenue starts only after it has many active families (number to be set), and then local sponsors and an optional paid plan fit better than an ad network or a paywall.

**Message costs (checked 13 November 2026)**

| Channel | Price | Notes |
| --- | --- | --- |
| SMS by Firebase (not used) | [USD 0.12 per SMS to Egypt](https://cloud.google.com/identity-platform/pricing); first 10 a day free | Not used; kept for comparison |
| SMS by an Egyptian gateway (not used) | [EGP 5,000 for 5,000 SMS; EGP 45,000 for 100,000](https://sms.com.eg/) (EGP 1.00 to 0.45 each) | Not used; kept for comparison |
| WhatsApp code or notification (used) | [USD 0.0036 per message](https://www.growaxis.net/insights/whatsapp-business-api-providers-egypt-2026) for a business based in Egypt; USD 0.065 if based abroad | Needs a verified WhatsApp Business account, approved message templates and each parent's agreement; the app creates and checks its own codes |
| Email | Free: Firebase sends [1,000 confirmation emails a day](https://firebase.google.com/docs/auth/limits) on its free plan | Other mail fits free tiers such as Resend (3,000 a month) |

At 8 WhatsApp notifications per parent each school day (22 days a month), 1,000 parents cost about USD 630 a month. Verification codes add about USD 36 per 10,000 codes.

**Paid services chosen for quality**

Each service below was picked as the strongest option for its job. Prices are list prices found in November 2026; confirm each one before signing.

| Service | Job | Price |
| --- | --- | --- |
| Stream Chat | Chat screens, delivery and moderation | By monthly active users ([pricing page](https://getstream.io/pricing/)); [one price tracker](https://www.xpay.sh/agent-ready-index/stream-chat/) listed the first paid plan at USD 399 to 499 a month in May 2026 |
| flutter\_background\_geolocation | Driver's live location with the screen locked | One-time license per app, [required for release builds](https://github.com/transistorsoft/flutter_background_geolocation); [one reseller](https://www.techjockey.com/detail/transistor-software) lists it from USD 399 |
| Algolia | School search | Free up to 10,000 searches a month, then [USD 0.50 per 1,000 searches](https://www.activepieces.com/blog/algolia-pricing-2026-plans-costs-and-examples.md) |
| Sentry | Error reports | [About USD 26 a month on the Team plan and USD 80 on Business](https://cubeapm.com/pricing-calculator/sentry/), plus usage |
| Valify | ID scan, face match and liveness check | Per check, by quote |
| Codemagic | Cloud builds for iPhone, Android and web | By plan or build minutes; confirm on its pricing page |
| Google Cloud upgrades | Identity Platform tier, Firestore recovery and backups, warm Cloud Functions, Places and Routes | Pay as you go; grows with the number of families |
| Wallet partner | Holds the money and runs transfers | By contract; ask for no fee on transfers between parents |

Set a budget alert on every service and review the bill after the pilot.

**Revenue options for later, after growth**

| Option | How it earns | Fit and risk |
| --- | --- | --- |
| Local sponsors | Tutoring centres, clubs and school-supply shops pay for a labelled sponsor card shown to parents of one school or area | Best first step: no ad software and no personal data shared; needs someone to sell it |
| Optional paid plan | A monthly fee for extras such as activity carpools, several carpools and drive-balance reports | Works once groups are active; [Apple and Google keep 15%](https://www.revenuecat.com/blog/engineering/small-business-program); safety features stay free |
| One-time verification fee | A small fee at verification covers the ID check and the codes | Covers costs and deters fake accounts, but slows sign-ups while the app needs growth |
| Insurance partner | A licensed insurer offers accident cover for carpool children and pays a referral fee | Closes the insurance gap in section 7; needs a licensed partner |
| Ad network | Banner ads from AdMob or similar | Weak: 1,000 parents opening the app twice a day make about 60,000 banner views a month, worth under USD 60 at [banner rates](https://appfollow.io/blog/mobile-game-ads-formats-monetization), and ad software collects data in an app that holds children's details |
| Share of parent contributions | The app keeps part of the money parents pay each other | Avoid: the app becomes a paid transport broker under the ride-hailing law and must handle payments |

[GoKid](https://apps.apple.com/US/app/id1050331956?mt=8), a parents' carpool app in the US, follows the paid-plan model: free to use, with extras at USD 4.99 a month.

When that time comes, any paid option replaces the Non-profit principle in section 1 and needs a registered company that pays tax. Ask the lawyer how charging changes the ride-hailing law answer before taking any money.
