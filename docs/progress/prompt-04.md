# Prompt 4: Admin web panel (F14) — progress note

Branch: `prompt-04-admin-panel` (from `prompt-03-identity-verification`,
fast-forwarded to 57f5147). Date: 13 Nov 2026. The coordinator gave "go"
on the owner's behalf.

**Status: code complete, not compiled.** No Flutter SDK or package
registry here. See "Verified here vs not run".

## Plan that was followed

1. Functions: admin access guard, admin sign-in in the blocking function,
   admin callables (users, schools and areas, "Other" schools, reports,
   audit log, admin accounts), name check on approvals.
2. Rules: audit log readable by admins with two steps, never writable;
   other panel collections closed; emulator tests; indexes.
3. Bootstrap script (first super admin, TOTP on) and emulator seed.
4. Flutter web panel: entrypoints, session, router, shell, screens, AR/EN
   strings, tests, screenshots.
5. Hosting target, CI build, SETUP section 13, COSTS, this note.

## How it works

**Sign-in (two steps, admins only).** Admins are separate email accounts
with no phone number and the `admin` custom claim (`superAdmin` too for
super admins). The panel signs in with email and password; Identity
Platform then asks for the TOTP code from an authenticator app. The
blocking function (`blockNonCodeSignIn`) allows a password **only** for an
account with the admin claim, no phone number and not disabled; every
other password, email-link, SMS or anonymous sign-in is refused as before.
A parent account always has a phone number and never the claim, so a
parent who sets a password on their own account still cannot use it.
Every admin sign-in is written to the audit log (with the IP from the
blocking event). A new admin with no second factor yet lands on "Add
two-step sign-in" (setup key for the authenticator app, then sign in again
with both steps).

**Server-side checks on every admin call** (`admin_panel/guard.ts`):
admin claim, a second factor on the token
(`firebase.sign_in_second_factor`), and a sign-in less than 8 hours old;
the admin account functions also need `superAdmin`. The second factor is
skipped only when `FUNCTIONS_EMULATOR=true` (the Auth emulator has no
TOTP); no setting turns it off in a cloud project. Prompt 3's
`listVerificationQueue`, `openVerificationCase` and `decideVerification`
now use the same guard.

**Short sessions.** Browser-tab persistence (closing the tab signs out),
15 idle minutes signs out (pointer, scroll or key resets it), 8 hours
maximum enforced by the functions and the rules.

**Parents cannot open the panel**, three ways: the blocking function
refuses their password sign-in; the router sends anything that is not an
admin with two steps to sign-in (`adminRedirect`); every function and the
audit log rule check the claim, the second factor and the session age.

**Panel sections** (navigation rail; Admins only for super admins):

| Section | What it does |
| --- | --- |
| Review (queue) | Cases oldest first with the automated check's advice. A case shows every document with the reviewer's name, email and time watermarked across it (tiled, diagonal), the details, the checks to tick (photos, selfie, head turn, ID valid, licenses) and the **parent and child name check** from spec section 3 ("name contains the father's name" or "birth certificate seen, not stored"). Approve asks for confirmation; reject takes a reason, a note the parent sees, and an optional ID ban (with a second confirmation). |
| Users | Server-side search by name (Arabic spelling tolerant), phone or parent ID; 30 searches per admin per 10 minutes; phones and emails come back masked; nothing is listed before a search. Detail: verification history and actions on the account. Suspend (signed out, "verified" claim removed, earlier status kept), lift suspension, ban (suspension plus the ID hash on the ban list). Admin accounts and the admin's own account are refused. |
| Schools | Active schools by governorate (27 codes), add and edit (names in Arabic and English, governorate, city, pin), areas per school (names and center pin). |
| New schools | Schools parents typed under "Other" (`status: awaiting_review`, spec section 9): correct and approve as new, or merge into an active school (its children move to it). Parents add these from Prompt 4B; the dev seed has two. |
| Reports | Open reports, newest first, with "over 24 h" marked. List only. |
| Log | The audit log, newest first, with load more. Read only. IP addresses shown to super admins only. |
| Admins | Super admins add an admin (email, name, role) and get a one-time password setup link (shown once, never stored or logged), and disable or enable other admins. |

**No download.** Images come from Prompt 3's 5-minute signed links and are
drawn on the canvas (Flutter web, `NetworkImage` default strategy never
uses an `<img>` element), the browser's context menu is off in the panel,
and there is no save or open button. A screenshot cannot be stopped in a
browser, which is why the watermark carries the reviewer's name. The
links still appear in the browser's network tools for 5 minutes (see open
question 3).

## Hardening after the validator review (non-blocking items)

1. **No client sign-ups:** `blockClientSignUps` (beforeUserCreated)
   refuses every account a client tries to create (password sign-up,
   email link, SMS, social providers). Parents and admins are created by
   our functions with the Admin SDK, which carries no client credential
   (and per Firebase, custom and anonymous auth skip blocking functions).
   Policy `creationAllowed` unit-tested.
2. **Access ends at once:** every admin call reads `admins/{uid}`: refused
   when missing or disabled, or when the token was issued before
   `revokedAt` (set when an admin is disabled, with refresh tokens
   revoked). The audit log rule checks the same record.
3. **Server-side idle limit:** admin calls refuse a session idle for 15
   minutes (`lastActiveAt`, written at most once a minute, or the sign-in
   time if later). The panel calls `adminPing` at most every 5 minutes
   while the admin clicks, types or scrolls; a refused ping signs out.
   The rules do not check idle time (the panel never reads Firestore
   directly).
4. **review.ts grant-admin** needs `--allow`, refuses accounts with a
   phone number or no email, writes the admin record and an audit entry.
5. **Audit:** listing admins (`admin.list`) and opening the audit log
   (`audit.view`, first page only) are logged. A failed admin creation
   deletes the half-made Auth account and record.
6. **TOTP check:** `admins:cloud -- check-totp` and SETUP 13.1 step 4.
   `multiFactorConfig.state` is required by the Admin SDK types (it is the
   SMS switch, kept `DISABLED`), so it stays, without a cast.

## Data model

| Where | What | App access |
| --- | --- | --- |
| `auditLog/{id}` | actorUid, action, target, reasonCode, details (counts and kinds only), ip, time. New actions: admin.signIn, admin.create/disable/enable, user.search/view/suspend/unsuspend/ban, school.create/update/approve/merge, area.create/update; verification decisions now carry `details.nameCheck` | **get/list for admins with two steps and a fresh session**; nobody creates, edits or deletes |
| `admins/{uid}` | email, displayName, role, disabled, revokedAt, lastActiveAt, createdBy, createdAt | none |
| `adminLimits/{uid}` | search rate limit window and count | none |
| `moderations/{id}` | uid, action, reasonCode, note (the parent never sees it), actorUid, time | none |
| `users/{uid}` (new fields) | nameKey, nameTokens (normalized name for search; written on submission), banned, statusBeforeSuspension | owner read (unchanged) |
| `verifications/{id}` (new field) | nameCheck | none |
| `schools/{id}` | nameAr, nameEn, searchKeys, governorate (code), city, location (GeoPoint), status (active, awaiting_review, merged), source, addedBy, mergedInto, createdAt | none until Prompt 4B |
| `areas/{id}` | schoolId, nameAr, nameEn, center | none until Prompt 4B |
| `reports/{id}` | reporterId, targetType, targetId, reason, status, handledBy, createdAt | none |

New composite indexes: verifications (uid, submittedAt desc), auditLog
(target, time desc), schools (status, nameAr) and (status, governorate,
nameAr), reports (status, createdAt desc). The seed's governorates changed
from "Cairo"/"Giza" to the codes `cairo`/`giza`, and seeded children now
use Prompt 3's shape (`ownerUid`, `status`).

## Decisions

1. **Email and password + TOTP** for admins rather than Google sign-in: no
   new package (Google sign-in on mobile needs one; the panel is web only
   but stays simple), TOTP is free in Identity Platform, and the blocking
   function stays one rule ("password only for admin accounts").
2. **Panel reads everything through functions**, never Firestore
   directly: one code path that also works on the emulators (where the
   rules' second-factor check cannot pass). The audit log rule still lets
   admins with two steps read it directly, as the prompt asks; nothing in
   the panel depends on it.
3. **Name check enforced on the server:** `decideVerification` refuses to
   approve a case with children without `nameCheck` (`match` or
   `birth_certificate`); the review script passes `match` by default.
4. **Map pin as typed coordinates** ("latitude, longitude" copied from
   Google Maps, Arabic digits accepted, refused outside Egypt's box) with a
   placeholder where the map goes. Google Maps for the web is not set up
   (needs a restricted browser key and `google_maps_flutter`); SETUP 13.6.
5. **No QR code** on the authenticator setup screen (would need a QR
   package): the setup key is shown grouped by 4 with a copy button;
   authenticator apps accept it typed in.
6. **Setup links instead of passwords:** the super admin never knows a new
   admin's password. The link is generated by the Admin SDK (not emailed,
   so the blocking function's ban on password-reset emails stays).
7. **Moderation notes** live in `moderations` (server only), not on the
   user record the parent can read.
8. **Admin components** (`OneLine`, `AdminPage`, `AdminAsyncView`,
   `AdminFact`, `WatermarkedImage`) live in `lib/admin/widgets` and are in
   the panel's own gallery (`/dev/admin-gallery`, dev only) instead of the
   app gallery, to avoid clashing with the design refresh running in
   parallel. They use only shared tokens and components.
9. **One-line rule:** every label, button, tab, list title and app bar
   title in the panel is short and uses `OneLine` (maxLines 1, softWrap
   false, ellipsis) where the panel draws text itself. `AppButton` and
   `AppListRow` titles come from the shared components; the design agent's
   refresh owns their one-line behavior.
10. **Forms:** the school, area, admin and moderation forms are single short
    forms (2 to 5 fields) checked as typed, not multi-step; the sign-in has
    a 2-step progress indicator.

## Screen states

| Screen | Loading | Empty | Error | Offline |
| --- | --- | --- | --- | --- |
| Sign-in | button spinner | n/a | wrong password or code, not an admin, too many tries | message |
| Two-step setup | skeleton | n/a | message + retry | message + retry |
| Review queue | skeleton rows | "All caught up" | error view + retry | offline view + retry |
| Case | skeleton; image skeleton per document | images deleted (note) | error view + retry; decided meanwhile (note) | offline view + retry |
| Users | skeleton | before search (what to type); no results | rate limited (wait 10 minutes) | offline view |
| User | skeleton | no history (note) | error view; refused (own account, admin) | offline view |
| Schools / New schools | skeleton | empty view | error view + retry | offline view + retry |
| School form | skeleton (edit) | n/a | field errors as typed; server refusal | inline message |
| Reports / Log / Admins | skeleton | empty view | error view + retry | offline view + retry |

## How to test it (the "Done when" check)

On the emulators (quickest):

1. `firebase emulators:start --project demo-school-carpool`, then
   `npm --prefix functions run seed:emulator`.
2. `flutter run -d chrome -t lib/admin/main_admin_dev.dart`.
3. Sign in as `reviewer@example.com` / `dev-only-password` (the second step
   is skipped on the emulators only).
4. Review: open the first case, tick the checks, choose the name check,
   **Approve**. Open the second, **Reject** with "Selfie does not match".
5. Schools > **Add school**: names, Cairo, city, pin `29.9602, 31.2569`, Save.
6. Log: the two decisions, the case openings and the new school are there.
7. Parent check: in the app, sign in as a parent; then try the panel with a
   parent's email: "This account cannot open the admin panel."

Two steps for real (cloud dev project): SETUP 13.1 to 13.3 (TOTP on, first
super admin with the printed link, Hosting site), open the site, set the
password from the link, sign in, add the authenticator app, sign in again
with the code, then steps 4 to 6 (cases come from parents verifying in the
app, Prompt 3).

## Tests

| Test | Status |
| --- | --- |
| `functions/test/admin_panel.test.ts`: access (claim, second factor, 8 h, super admin), name normalization, search planning, masked phones and emails never logged in clear, rate limit, suspend/unsuspend/ban (claims, sessions, ban list), refusals, schools (validation, Egypt box, create/edit/areas, approve, merge with children), admin accounts (role, one-time link not stored), reports, audit log (IP for super admins only) | **Run here: pass** |
| `functions/test/sign_in_policy.test.ts`: password only for admin accounts; parents, disabled admins, phone accounts refused | **Run here: pass** |
| `functions/test/verification_flow.test.ts`: name check required to approve a case with children; decision parsing | **Run here: pass** |
| All Functions unit tests | **Run here: 168 pass** (Node 22, `tsc` against stand-in type stubs, small runtime stubs for firebase-admin/functions) |
| `tests/rules/admin.test.ts`: audit log read by admins with two steps and a fresh session; no create/edit/delete by anyone; parents, admins without the second factor or with an old session refused; admins, adminLimits, moderations, reports, schools, areas closed; admins cannot read users or cases directly | Written, not run here |
| `test/admin/admin_logic_test.dart`: session from the token, router gate, pin input, parsing, error mapping | Written, not run here |
| `test/admin/admin_screens_test.dart`: two-step sign-in, parent refused, parents never reach a panel screen, setup screen, queue, approve with checks and name check, reject, user search with masked phone, rate limit, suspend, school form with pin check, merge, audit log, Admins for super admins only | Written, not run here |
| Screenshots `admin_*` (15 screens, AR/EN, light/dark, 1280 wide) | Written, not run here (CI artifact) |
| CI: admin web build added to the builds job | Written, not run here |

## Verified here vs not run

Run here: Functions unit tests (150 pass) and a type-check of all Functions
code including the scripts (only stub gaps remain); ARB parity (587 keys
each, every `l10n.admin*` used exists); import order and bidi-character
scan of the new Dart files; duplicate type names. Checked against sources:
FlutterFire `firebase_auth` 7.0.1 MFA API (`TotpMultiFactorGenerator`,
`TotpSecret.secretKey`, `generateQrCodeUrl`, `MultiFactorResolver`,
`IdTokenResult.signInSecondFactor/authTime`, `Persistence.SESSION`),
`FirebaseFunctionsException` constructor, `NavigationRail.trailingAtBottom`
(material_ui), `NetworkImage` web strategy, `BrowserContextMenu`,
firebase-functions identity event (`data.customClaims`, `ipAddress`), and
Identity Platform pricing (only SMS is charged per message).

Not run: `flutter analyze`, `flutter test`, `flutter gen-l10n`, the web
build, screenshots, rules tests and Functions tests with real packages on
the emulators. Expect small analyzer fixes on the first CI run.

## Open questions for the owner

1. **Maps for the web:** set up a Maps JavaScript key for the admin site
   and add `google_maps_flutter` (new package) for a real pin picker?
2. **QR code** on the authenticator setup screen (adds a small QR
   package), or keep typing the setup key?
3. **Stronger "no download":** images could be streamed through a function
   and watermarked on the server (needs an image library such as `sharp`
   in Functions) so no image link ever reaches the browser. Worth it?
4. **Audit log retention:** how long to keep entries (lawyer).
5. **Session lengths:** 15 minutes idle and 8 hours maximum. OK?
6. **Unban:** a ban cannot be lifted in the panel. Should a super admin be
   able to lift one (with a reason)?
7. **Hosting domain** for the panel (a custom domain, or `<site>.web.app`).

## Not done / known gaps

- Report handling (Prompt 9 with chat); reports are a list only.
- A real map in the panel (open question 1).
- Parents adding "Other" schools and the schools import (Prompt 4B); the
  queue works with the seeded ones.
- A brand-new admin who has not added the authenticator app yet can sign
  in with the password alone until they do (to reach the setup screen); no
  function or rule lets them do anything else. Pass the setup link
  directly and have them finish setup at once.
- Name search finds names written on verification from now on (the
  `nameKey` field); existing dev records need the seed rerun.
- Admin sign-in emails or alerts on new devices (spec section 7 asks for
  this for parents; admins could get it later).
- The panel is laid out for desktop and tablet widths; phone widths work
  but are not tuned.
- Codemagic is unchanged (iOS only); the panel builds in GitHub Actions.
