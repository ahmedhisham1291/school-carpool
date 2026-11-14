# Prompt 6: Carpools (F5, F6, F25, F26, F31, F32, F36, F39) — progress note

Branch: `prompt-06-carpools` (from `main` with Prompts 1 to 5, the design
refresh and docs/DECISIONS.md). Date: 14 Nov 2026. The coordinator gave
"go" on the owner's behalf.

**Status: code complete. Functions unit tests and the Python tool tests
were run here (272 and 4 pass). The Flutter code, the widget tests and the
rules tests were written, not run here** (no Flutter SDK or npm registry in
this workspace). Expect small analyzer fixes on the first CI run.

## Plan that was followed

1. Functions: pure flows over a store (`functions/src/carpools/flow.ts`),
   the seat and consent rules in one pure module (`model.ts`), Firestore
   store, 13 callables, unit tests.
2. Rules for every new collection, with emulator tests; areas opened for
   reading.
3. App: Carpools tab, search, start a carpool in four steps, carpool
   detail (members, children's first names and grades, rules,
   contribution, driver consent, pickup point, join requests, invite,
   leave), join sheet, invite screen (`/c/<code>`), "Looking for a
   carpool". The nearby card's Join opens that parent's carpools.
4. Universal links: a second Hosting site serves
   `apple-app-site-association` and a static fallback page; the Associated
   Domains entitlement is added from `INVITE_LINK_DOMAIN`.
5. Seed (cars, a ready carpool), a script that plays a second fake parent,
   SETUP section 16, COSTS, DESIGN, strings, gallery, tests, screenshots.

## Data model (all writes by Cloud Functions)

| Record | Holds | Who reads it (firestore.rules) |
| --- | --- | --- |
| `carpools/{id}` | Public summary: kind (school or activity), school and area names, activity name and place (rounded), times, days, seats, children and member counts, `seatsLeft`, rules, contribution, creator's first name, status | Any verified parent, by ID only (no list or query) |
| `memberships/{carpoolId}_{uid}` | `carpoolId`, `uid`, `status` (requested, approved, declined, left), `role` (admin, member), first name, children (id, first name, grade), car (seats, valid until), driving days, accepted rules and contribution, times | The parent it belongs to (get, or list with `uid ==`). Same ID and fields Prompt 5's pickup-point rule checks |
| `carpools/{id}/members/{uid}` | Approved members: first name, role, children's first names and grades, car seats and validity, driving days, pickup shared | Verified approved members of that carpool |
| `carpools/{id}/requests/{uid}` | Open join requests with the children's first names and grades | The requester and the carpool admin |
| `carpools/{id}/driverConsents/{parent}_{driver}` | F26: status accepted or withdrawn, accepted and withdrawn times | Verified approved members of that carpool |
| `carpools/{id}/pickupPoints/{uid}` | EXACT home, copied only when the member switches "Share pickup point" on; deleted when off or on leaving | Its owner and approved members (Prompt 5 rule, unchanged in meaning) |
| `carpoolInvites/{code}`, `carpoolLimits/{uid}` | Invite codes (14 days, TTL) and per-parent limits | Cloud Functions only |
| `carpoolWanted/{uid}` | F32 post: first name, school, area, times, days, number of children (60 days, TTL) | Its owner; others through `listCarpoolWanted` only |
| `areas/{id}` | Opened for reading (names and centres, public) | Signed-in parents, at most 200 per query |

Indexes: `carpools` (kind, schoolId, status) and (kind, status,
`activity.geohash`).

## Rules the server enforces

- **Seats (spec section 6):** the creator needs an approved car with valid
  papers; seats offered are never more than the car's passenger seats; the
  creator's own children take seats. A join request must fit the free
  seats, and approval re-checks them inside the transaction (two requests
  that each fit cannot both be approved). `checkArrangement` refuses a run
  with more children than the driver's passenger seats (for Prompt 7).
- **Driver consent (F26):** `driverStatus` says a member can drive only
  when every other parent with children in the carpool accepted them, the
  car is approved and valid, and its seats fit all children. Consent is
  given or withdrawn any time through `setDriverConsent` (approved members
  only, never to oneself). Leaving deletes every consent given to or by
  the member, so joining again needs fresh consent. The app asks to meet
  before the first ride when accepting.
- **Join (F6, F25, F36):** verified parents only; the rules must be
  accepted, and the contribution too when there is one; children must be
  the parent's approved children at the carpool's school (any school for
  activities). Only the admin approves or declines. The admin leaves only
  as the last member (that closes the carpool).
- **Search (F5, F39):** school carpools only for the parent's own schools
  (children's or driving schools), with area and times within 30 minutes;
  activity carpools within the chosen radius of the parent's rounded home.
  Full carpools are hidden. Nothing in a result names a child or a uid.
- **Invite links (F31):** 10-character codes from the parent ID alphabet,
  made by approved members, valid 14 days. Opening one needs the verified
  claim and a verified account, returns only the carpool ID, and is
  limited to 20 an hour per parent (codes cannot be guessed). Joining still
  needs the admin's approval.
- **Looking for a carpool (F32):** posts for one's own approved child's
  school; listed only to parents of that school; a suggestion when the
  parent's post matches at least two other families (same school, same
  area when both chose one, a shared run within 30 minutes, a shared day).
- **Limits** (params): 3 new carpools a day, 30 searches an hour, 10 join
  requests a day, 20 invites a day, 20 invite opens an hour, 5 posts a day,
  30 post lists an hour; at most 10 active memberships and 5 carpools as
  admin.

## Screens and states

| Screen | Layout | Loading | Empty | Error | Offline |
| --- | --- | --- | --- | --- | --- |
| Carpools tab | Waiting invite card; "My carpools" cards (Requested/Admin badges); More: Find, Start, Looking for one | Skeleton cards | "No carpools yet" + Find a carpool | Error view + retry | Offline view + retry |
| Find a carpool | Chips: school or Activities, area, time (radius for activities), "Hoda's carpools" from Join; result cards with times, days, seats, contribution, rules | Skeleton cards | No school (search activities); nothing found (Start a carpool) | Error view; "too many tries" and "set your home" inline | Offline view |
| Start a carpool | Step bar; 1 where (school + area, or activity name + place search), 2 when (morning/afternoon switches with times, days), 3 who (children, seats up to the car, driving days), 4 rules and contribution; Next / Back | Skeleton | No approved child (Add a child) | Inline message per step and from the server | Offline view; inline on create |
| Carpool detail | Title, area, started by; times; seats and contribution; rules; for members: members (children, driver badge), "Who drives my kids" switches, pickup point switch; for the admin: join requests (Approve, Decline); Ask to join / Cancel request / Invite parents; Leave | Skeleton | Not found | Error view; inline in sections | Offline view |
| Ask to join (sheet) | Children check rows, seat check as you pick, rules, accept rules, accept contribution, Send request | n/a | No child at this school | Snackbar | Snackbar |
| Invite (sheet) | Link, Send on WhatsApp, Copy link | Button progress | n/a | Snackbar | Snackbar |
| Invite link `/c/<code>` | Verified: opens the carpool. Not verified: "Verify first", code kept | Progress | n/a | "Invite not valid"; error + retry | Offline view |
| Looking for one | School chips (several schools); match card (Start a carpool); My request (Post / Delete); Families looking | Skeleton | "Nobody yet"; no school | Error; "too many tries" | Offline view |

## Decisions

1. **The creator must have an approved car** to start a carpool (spec Flow
   A: the creator picks the seats and the days they drive). Seats can never
   be more than the car's passenger seats. Parents without a car post
   "Looking for a carpool" or join one.
2. **Contribution is fixed per carpool** (spec open question): set by the
   creator, shown everywhere, accepted when joining. Paid outside the app or
   by wallet later; the app takes nothing.
3. **Activity carpools** have no area: they are searched by distance from
   the parent's rounded home (1 to 10 km) to the activity place, which is
   stored rounded to about 500 m.
4. **Members' driving days** wait for Prompt 7 (rotation); only the
   creator's days are saved now. `checkArrangement` and `driverStatus` are
   ready for Prompt 7 to refuse any driving day without consent or seats.
5. **New dependency `url_launcher` (^6.3.1)**, the official Flutter plugin,
   to open WhatsApp (`https://wa.me/?text=...`) with the invite text
   (F31 says the parent shares by WhatsApp). Free, Java/Swift (no Kotlin
   fix needed, `KOTLIN_FIX_PLUGINS` unchanged), no URL-scheme query needed
   on iOS. If WhatsApp does not open, the link is copied.
6. **Universal links** use a second Hosting site per project (`links`), so
   the admin panel's strict headers stay as they are. The entitlement is
   added only when `INVITE_LINK_DOMAIN` is set, because signing fails until
   the App ID has the Associated Domains capability (SETUP 16.3).
7. **An invite opened before sign-up or verification is kept on the phone**
   (`shared_preferences`, a code only) and offered on the Carpools tab after
   verification.
8. **Nearby Join (F22)** opens the search filtered to that parent's
   carpools at that school.

## How to test it on the iPhone (the "Done when" check)

1. Emulators and seed: `firebase emulators:start --project demo-school-carpool`,
   then `npm --prefix functions run seed:emulator`.
2. Run the dev app on the iPhone (SETUP section 9; `--dart-define=EMULATOR_HOST=<Mac IP>`).
3. Sign up, add a child at "Nile International School (test)" **and the
   driver details (license and car)**, submit, and approve with
   `npm --prefix functions run review:emulator -- queue` and `-- approve <caseId>`.
4. Carpools tab > **Start a carpool**: school, area Degla, times, days,
   your child, seats (at most your car's seats), rules, a contribution.
   **Create carpool**. Get its ID with
   `npm --prefix functions run carpool:emulator -- search --as seed-map-parent-1`
   (this is also Hoda finding it).
5. Second fake parent (Hoda) finds and asks to join:
   `npm --prefix functions run carpool:emulator -- request <id> --as seed-map-parent-1`.
   (Or sign in as Hoda on a simulator with `+201000000101`.)
6. On the iPhone, the carpool shows **Join requests**: Hoda's child with
   first name and grade, and "Has an approved car". **Approve**.
7. Under **Who drives my kids**, switch Hoda on (the dialog says to meet
   first). Hoda accepts you:
   `npm --prefix functions run carpool:emulator -- consent <id> <your uid> --as seed-map-parent-1`
   (your uid is in the emulator UI, Authentication). Both member badges
   say **Can drive**. Switch Hoda off and on to see withdraw.
8. **Invite parents** > Copy link. With the links site and Associated
   Domains set up (SETUP 16.2 and 16.3, dev project), the link opens the
   app on the invite screen and then the carpool. On the emulators, open
   `/c/<code>` by pasting the link into Notes and tapping it once the dev
   domain is configured; otherwise check the flow in the widget tests.
9. Also try: Find a carpool (Hoda's ready carpool `seed-carpool-1`), Ask
   to join with rules and contribution, Looking for one, the nearby map's
   Join, Arabic and dark mode.

## Tests

| Test | Status |
| --- | --- |
| `functions/test/carpools.test.ts` (47): parsing, Cairo date, invite code alphabet; create (admin and member, seats never above the car, own children take seats, no car or expired papers, own approved children at that school, area of the school, bad input, verified only, activity point rounded, daily limit); search (same school only, driving schools, no uid or child names in results, area and 30-minute filters, full hidden, Join's parent filter, activity radius and ≤ 9 queries, hourly limit); join (children's names and grades to the admin, must accept rules and contribution, seats, approval re-checks seats, only the admin decides, decline then ask again, no double requests, cancel, daily limit); consent (waiting parents, withdrawn counts as none, car too small, `checkArrangement` cases, accept and withdraw, approved members only, leaving removes consents and pickup point, fresh consent on rejoin, admin leaves last and closes); pickup sharing; invites (verified only, joins nothing, members only, expiry, bad codes, limit); looking (matching, suggestion at 3, school-only listing, expiry, delete); the "Done when" flow | **Run here: pass** |
| All Functions unit tests | **Run here: 272 pass** (Node 22, `tsc` against stand-in type stubs as in earlier prompts) |
| `tool/test_links_site.py` (association file, bad input, Associated Domains patch) | **Run here: 4 pass**; added to CI |
| `tests/rules/carpools.test.ts`, updated `maps.test.ts` and `deny_all.test.ts` | Written, not run here (CI); type-checked against a stub |
| `test/carpools/carpool_logic_test.dart`: consent and seat rules (same cases as the server), parsing, draft JSON, times, invite path, routes, session redirect for `/c/` | Written, not run here |
| `test/carpools/carpool_screens_test.dart`: tab (empty, my carpools, waiting invite, offline), search (school, area, time, activities, empty, offline, limited, Join from the nearby card), create (4 steps, seats limited by the car, draft sent, no car, no child, server error), detail (visitor joins accepting rules and contribution, seat check, cancel, members with children and badges, consent accept and withdraw with dialogs, admin approve, invite by WhatsApp and copy, leave, not found), invite link (verified, not verified keeps the code, invalid), looking (match suggestion, post); **one line at 320 dp in AR and EN at text x1 and x2** for titles, buttons, chips, section headers, badges and switches, and every rule/day/badge label in a chip | Written, not run here |
| Router and maps tests updated (Carpools tab screen; Join closes the card) | Written, not run here |
| Screenshots `carpools_*` (tab, search, create, member and visitor detail, invite, looking; AR/EN, light/dark) | Written, not run here (CI artifact) |

## Learned from earlier reviews

- Every new collection has rules tests with forged memberships, members
  who left, missing claims and signed-out users.
- Limits on every search-like call (carpools, invites, posts), counted on
  the server in a transaction.
- One-line test for every new label kind at 320 dp, AR and EN, x1 and x2;
  short wording (rules are 1 to 3 words).
- Analyzer habits: no bidi literals, imports sorted, const literals in
  constructor arguments of immutable classes, no redundant default
  arguments, same ProviderScope override count in every pump of a test
  (carpool fakes are part of `authOverrides`).

## Open questions for the owner

1. **Car to start:** a parent needs an approved car to start a carpool. OK?
2. **"Mothers drive" rule:** shown and accepted when joining, but the app
   does not know who is a mother, so it is not enforced. OK, or should the
   account record the parent's role?
3. **Limits:** the numbers in "Rules the server enforces". OK?
4. **Admin leaving:** the admin can leave only as the last member. Should
   the admin be able to hand over to another member (later prompt)?
5. **Invite lifetime:** 14 days, any number of uses. OK?
6. **Looking posts:** visible to every verified parent of the school (area
   is a filter, not a limit), 60 days. OK?
7. **Apple Team ID and links site** per project (SETUP 16) to switch on
   universal links.

## Not done / known gaps

- Notifications for join requests, approvals and new posts (Prompt 8);
  the records are ready for it.
- Members choosing their driving days and the rotation (Prompt 7), which
  must call `checkArrangement`.
- Carpool chat (Prompt 10), Android App Links and website deep links
  (Stages 2 and 3).
- Account deletion must also remove `memberships`, members, requests,
  consents, pickup points and `carpoolWanted` (Prompt 12, with Prompt 5's list).
- A child who leaves a school does not yet leave its carpools (yearly
  re-verification prompt).
- Not verified here: `flutter analyze`, `flutter test`, the rules tests,
  the iOS build with the Associated Domains entitlement.

## Review fixes (docs/reviews/prompt-06-review.md)

- **Blocking 1 fixed:** a parent may `get` their OWN membership ID
  (`{carpoolId}_{uid}` ending in their uid) even when it does not exist,
  so a non-member opening a carpool sees "Ask to join" instead of an error.
  Another parent's ID, existing or missing, stays denied (rules tests
  added, including IDs that only contain the uid elsewhere). The app
  already treats a missing document as "not a member".
- Non-blocking 3: the nearby Join filter no longer shows full carpools.
- Non-blocking 5: when the admin closes a carpool (leaves last), open
  requests are declined and removed.
- Non-blocking 6 (part): approving a requester whose account is missing is
  refused as not verified.
- Non-blocking 9: "looking" posts are read newest first (index on
  `carpoolWanted` schoolId, createdAt descending).
- Non-blocking 10: the kept invite code is cleared on sign out.
- Unit tests added for the above (274 Functions tests pass here).

## For Prompt 7 (from the review)

- Enforce `checkArrangement` **on the server**, inside the transaction that
  gives anyone a driving day, for every driver **including the creator**
  (the creator's `drivingDays` were saved before anyone consented).
- Re-read the driver's vehicle and account there: `car` in `members` is a
  copy taken at approval or creation.
- Re-check the carpool's `seats` against each driver's car when a car is
  re-verified with fewer seats (and lower or flag it).
- Search and `listCarpoolWanted` still show carpools and posts of parents
  who were later suspended; filter them (review item 6).
- Membership-count checks in `createCarpool` and `requestToJoin` run
  outside the transaction; move them in if it matters (item 8).
- Owner questions still open: "looking" posts visibility (item 4, question
  6) and the free-text activity label and contribution note (item 7,
  report path in Prompt 11).
