# Review: Prompt 6 (Carpools: F5, F6, F25, F26, F31, F32, F36, F39)

Branch: `prompt-06-carpools`, head `dc0abbd` (includes `main` with Prompts 1
to 5 and the design refresh). Reviewed 14 Nov 2026 by the validator agent.

Scope: `git diff origin/main...HEAD` (60 files, +10478/-42). I checked it
against CLAUDE.md (SECURITY, PRIVACY, COST MODE, DESIGN, TESTS),
`docs/DECISIONS.md`, `docs/DESIGN.md`, `docs/WORKFLOW.md`, `docs/spec.md`
(Flows A and B, F5, F6, F25, F26, F31, F32, F36, F39, sections 6, 7 and 9),
`docs/build-prompts.md` (Prompt 6 and its "Done when") and
`docs/progress/prompt-06.md`.

What I ran here: nothing that compiles. There is no Flutter SDK here. The
Dart, Functions and rules results come from CI. The other findings come
from reading the code and working through each attack and race by hand.

## Verdict

**CHANGES NEEDED** (two blocking items, both small).

The server design is sound. Every membership, ownership, status, consent
and pickup-point write goes through a Cloud Function. The rules deny every
app write, and the rules tests cover this, including forged memberships,
members who left, and missing claims. Seats are checked again inside the
approval transaction. Invite codes are 50-bit random, expire, need
verification and are limited per hour. "Looking" posts hold area names only.

The blocking items:

1. The rule on `memberships` denies the visitor's own listener when the
   document does not exist yet. That breaks the carpool screen for a parent
   who has not asked to join, which is the main path in the "Done when".
2. The Android build job did not finish green.

## CI

Run 43526271115 on `dc0abbd`: **not green**.

| Job | Result |
| --- | --- |
| Flutter analyze, tests and screenshots | success |
| Cloud Functions tests and rules tests (emulators) | success (includes the new `tool/test_links_site.py`) |
| Web, admin panel and Android compile (staging) | Web and admin panel succeeded. The step "Build Android APK" ended **cancelled** at 23:35:44Z, after 12.5 minutes, below the job's 30-minute timeout. At 23:52Z the job was still stuck in "Complete job" and the run was `in_progress`. |

## Probes (results)

| Question | Result |
| --- | --- |
| App writes to carpools, memberships, members, requests, consents, pickup points, invites, limits or wanted posts | All denied (`create, update, delete: if false`). Tested in `tests/rules/carpools.test.ts`, including admins writing their own carpool and members changing their role. |
| Who reads the carpool summary | Any verified parent, by ID only. Nobody can list or query it. The summary holds no child names and no home. Unverified and signed-out users are denied (F31). Tested. |
| Children's first names and grades | `members` is readable only by verified, approved members of that carpool. `requests` is readable by the requester and the admin. Search, invite and "looking" answers name no child. This matches spec section 6, "once in a group". |
| Two approvals that together exceed the seats | `decideJoinRequest` reads the carpool in the Firestore transaction and checks `childrenCount + children > seats`. Firestore serialises or retries the second approval, so the seats cannot be exceeded. Tested ("approval re-checks seats"). |
| Seats compared with the car | At creation, `seats <= carInfo(vehicles/{uid}).seats`. The value comes from the verified `vehicles` record and must have `status == approved` and valid papers. `checkArrangement` and `driverStatus` refuse more children than the driver's passenger seats. |
| Driver consent (F26) | Only approved members can consent, never to themselves. Consent can be withdrawn at any time and is kept as a record. Leaving removes every consent given to or by the member. `driverStatus` and `checkArrangement` require every other parent's accepted consent. Members' driving days are not assigned yet (Prompt 7), so no new member can drive. See Non-blocking 1. |
| Invite codes | 10 characters from the 32-character alphabet (`b % 32`, no bias), 2^50 codes, created with `create()` so they never overwrite. They expire after 14 days (TTL plus a check on the server). Opening one needs the claim and a verified account, is limited to 20 opens an hour, checks the format after taking from the limit, and returns only the carpool ID. Joining still needs the admin. |
| Fallback page and AASA | The page is static. It never shows the code or any carpool data, and it sets `noindex`, `no-referrer`, a strict CSP and `DENY` framing. The AASA uses the modern `components` form with `/c/*` only, is served as `application/json`, and the dotfile is deployed (the `ignore` list is overridden on purpose). The Associated Domains entitlement is added only when `INVITE_LINK_DOMAIN` is set and the host name is valid, and is removed otherwise. Tested in Python. |
| Invite route fix (`/c/<code>` → `/carpools/invite/<code>`) | Correct. The top-level redirect goes to the route inside the tab. `invite/:code` and the fixed segments are declared before `:carpoolId`. `sessionRedirect` lets both paths through only after registration is complete. The screen shows "Verify first" and keeps only the code. The code is captured in the router redirect before sign-in, so it is not lost. |
| "Looking for a carpool" | Posts hold first name, school, area names, times, days and the number of children. They have no coordinates. Saves are limited to 5 a day and lists to 30 an hour. Only the parent's own schools are shown. Posts expire after 60 days. The owner can read their own post directly. The suggestion needs three families. |
| Pickup points | Still only the owner and approved, verified members can read them, while the owner is a member too. The point is copied only when the parent switches sharing on, and deleted when they switch it off or leave. |
| Areas readable when signed in | Acceptable. Areas hold admin-managed names and centres, the same kind of data as `schools`, which is already readable when signed in. Lists are capped at 200 and writes stay closed, admins included. Tested in three suites. |
| Rate limits | Counted on the server in a transaction in `carpoolLimits/{uid}`, which the app cannot reach. They cover creates, searches, join requests, invites, invite opens, post saves and post lists. Each limit is taken after the access checks, so a refused call does not use up the limit. |
| `url_launcher` | Justified in the progress note and in `pubspec.yaml`. It is the official plugin and is free. Opening the `https://wa.me` link with `externalApplication` needs no iOS query scheme. No WhatsApp Business cost (COSTS.md). |
| Logs | Callables log only `error.message` and send to Sentry. No names, children, times or coordinates are logged. |
| ARB | 940 keys in each of AR and EN, the same set. |

## Blocking

1. **The carpool screen fails for any parent who has no membership in that
   carpool yet.** The rule is at `firestore.rules:181`:
   `allow get, list: if signedIn() && resource.data.uid == request.auth.uid;`.
   The screen listens to `memberships/{carpoolId}_{uid}`
   (`lib/features/carpools/carpool_repository.dart:96`). For a parent who
   has never asked to join, that document does not exist. `resource` is
   then `null`, `resource.data` is an evaluation error, and the read is
   denied. `carpool_detail_screen.dart:101` takes `membership.error` and
   shows the error view instead of "Ask to join".

   This affects every way into the screen: a search result, an invite link
   and the nearby card's Join. It breaks the "Done when" step "the other
   finds it, asks to join" in the real app. The widget tests use fakes, and
   no rules test reads a missing own membership, so CI cannot catch it.

   Fix: make `get` work on a missing document without leaking another
   parent's document. For example:
   `allow get: if signedIn() && (resource == null || resource.data.uid == request.auth.uid);`
   Keep `list` as it is. Add rules tests for:
   - `as("zed").doc("memberships/k1_zed").get()` succeeds when the document
     is missing;
   - `memberships/k1_bob` stays denied to alice.

   A second option is to treat `permission-denied` on this stream as `null`
   in the app. The rules fix is cleaner.

2. **CI is not green.** In run 43526271115, the step "Build Android APK
   (debug-signed until Stage 3)" ended `cancelled` after 12.5 minutes, and
   the run was still `in_progress` when this review was written. CLAUDE.md
   says Android must keep compiling in CI. Fix: re-run the job, or push the
   fix for item 1, and get a green "Web, admin panel and Android compile"
   job on the final head. If the build fails, look first at `url_launcher`
   (a new Android plugin) with the Kotlin and AGP setup in
   `tool/patch_native.py`.

## Non-blocking

1. **The creator's driving days exist before anyone consents.**
   `createCarpool` saves the creator's `drivingDays`. Parents who join
   later have not accepted the creator as a driver. No schedule exists yet,
   so nothing is broken now. Prompt 7 must run `checkArrangement` for every
   driver, the creator included, and also inside the transaction that
   assigns a day. "Re-checked on the server" today means only a pure helper
   that nothing calls. Prompt 7 must also re-read the driver's vehicle and
   account, because `car` in `members` is a copy taken at approval or
   creation (`flow.ts:632`, `flow.ts:379`).
2. **Car seats are not re-checked after the car changes.** The carpool's
   `seats` is checked against the creator's car only once, at creation. If
   the car is re-verified with fewer seats, nothing lowers it. Add this
   check in Prompt 7.
3. **`searchCarpools` with `parentUid` (`flow.ts:517-526`)** shows which
   carpools at a shared school any uid is an approved member of. It also
   shows full carpools. The risk is low (no names, and the school is
   limited). Consider allowing it only for uids that `searchNearby` returned
   to the caller, or dropping the full-carpool exception.
4. **Who sees "looking" posts.** F32 says "same school and area". The
   implementation shows the whole school, with area as a filter. It also
   includes parents who only *drive* to that school, and those can be
   self-declared in Prompt 5. This is raised as open question 6. Get the
   owner's answer before the pilot.
5. **Closing a carpool leaves open requests as `requested`.** Those requests
   count toward `MAX_MEMBERSHIPS` until the requester cancels. Decline them
   in `leaveCarpool` when the admin closes the carpool.
6. **Suspended parents' carpools and posts stay visible.** Search and
   `listWanted` do not filter out records whose creator or poster is now
   suspended or unverified. `decideJoinRequest` passes when the requester's
   account is missing (`requester &&`, `flow.ts:630`). Treat a missing
   account as not verified.
7. **The activity `label` is free text from a Places pick.** Any verified
   parent can read it. A creator could choose a home address as the
   "activity place". Consider showing only the place name, or checking
   that the place type is not a street address. The contribution `note`
   (120 characters) is free text shown to every verified parent too. Ask
   for a report path in Prompt 11.
8. **The membership checks in `createCarpool` and `requestToJoin` run
   outside the transaction** (`MAX_MEMBERSHIPS` and `MAX_ADMIN_CARPOOLS`).
   Parallel calls can go one over. This is minor, and the daily limits cap
   it.
9. **`wantedForSchool` takes 200 posts with no ordering.** In a busy school
   it may miss the newest posts. Order by `createdAt` descending and add the
   index.
10. **The pending invite code stays in `shared_preferences` after sign
    out.** It is harmless, because a verified account is still needed, but
    clear it on sign out.

## Done-when coverage

- Carpool created on the iPhone: covered (create flow and screens).
- The second fake parent finds it and asks to join: covered by
  `functions/scripts/carpool.ts`. In the app, a non-member opening the
  carpool hits Blocking 1.
- Approved: covered.
- Both accept each other as drivers: covered (the consent switches and the
  script).
- An invite link opens the right carpool: covered once SETUP 16 is done
  (Team ID, links site, `INVITE_LINK_DOMAIN`). With the current rules, the
  carpool screen after an invite also hits Blocking 1.
