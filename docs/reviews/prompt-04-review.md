# Review: Prompt 4 (Admin web panel, F14)

Branch: `prompt-04-admin-panel`, head `3b58fb1` (includes the merged
Prompt 3 fixes up to `dfcf499`). Reviewed 13 Nov 2026 by the validator agent.

Scope: Prompt 4's own changes, `git diff prompt-03-identity-verification...HEAD`
(79 files, +10317/-45), including the coordinator's merge fixes `36911d6`,
`b523b88` and `3b58fb1`. Checked against CLAUDE.md (STACK, COST MODE,
SECURITY, PRIVACY, DESIGN, LANGUAGES, TESTS, ENVIRONMENT NOTE),
`docs/WORKFLOW.md`, `docs/spec.md` (F14, section 3 name check, section 7
admin panel controls, section 9 School/Area/Report/Audit log rows,
section 10 admin screens), `docs/build-prompts.md` (Prompt 4 and its
"Done when") and `docs/progress/prompt-04.md`.

There is no Flutter SDK here. `flutter analyze` and `flutter test` were
**not run here**. The CI results below come from GitHub Actions.

## Verdict

**CHANGES NEEDED.**

The only blocking item is CI. The Android release compile fails in
`screen_protector` because the JVM targets do not match. Prompt 4 did not
cause this. It came in with the Prompt 3 merge (`dfcf499`), and Prompt 3
already has the fix (`ff8417a`), which this branch does not have yet.
Merge it and get a green run.

The security design of the panel is sound. A password works only for an
account that has the `admin` claim, no phone number and is not disabled.
The claim is set only by `adminCreateAdmin` (super admin only) or by the
bootstrap script. Every admin callable, Prompt 3's three review callables
included, checks the claim, `firebase.sign_in_second_factor` and an 8-hour
`auth_time` on the server. The audit log rule makes the same checks and is
append-only. User search is rate-limited and returns masked results. The
name check is enforced on the server. Suspend removes the claim and
revokes sessions.

## CI result

Run `43445679836` (push, head `3b58fb1`): **failed** (shown as "cancelled"
because the failing job cancels the run).

| Job | Result |
| --- | --- |
| Flutter analyze, tests and screenshots | **passed** |
| Cloud Functions tests and rules tests (emulators) | **passed** (including `tests/rules/admin.test.ts`) |
| Web, admin panel and Android compile (staging) | Bootstrap, **Build web** and **Build admin panel** passed; **Build Android APK failed** |

## Blocking issues

1. **Android release build fails: the JVM target in `screen_protector` does not match.**
   `.github/workflows/checks.yml:85` (step "Build Android APK"), caused by
   `tool/patch_native.py:177` (`KOTLIN_FIX_BLOCK`, from `dfcf499`). Quoted
   from job `131954370743`:
   ```
   * What went wrong:
   Execution failed for task ':screen_protector:compileReleaseKotlin' (registered by plugin 'org.jetbrains.kotlin.android').
   > Inconsistent JVM Target Compatibility Between Java and Kotlin Tasks
         Inconsistent JVM-target compatibility detected for tasks 'compileReleaseJavaWithJavac' (17) and 'compileReleaseKotlin' (21).
   BUILD FAILED in 6m 34s
   ```
   Fix: merge `prompt-03-identity-verification` (commit `ff8417a`, "compile
   screen_protector's Kotlin for JVM 17 like its Java", which sets
   `compilerOptions.jvmTarget` to `JVM_17` in the same block) into this
   branch. Then rerun CI and confirm that all three jobs pass. When this
   review was written, Prompt 3's own run with that fix (`43446318339`) was
   still in its compile job, so the fix is not yet proven in CI.

## Security checks done (no blocking findings)

- **Admin sign-in** (`functions/src/auth/sign_in_policy.ts:34-48`,
  `blocking.ts:17-38`). A password is allowed only when `isAdminAccount` is
  true: the account has `admin: true`, no `phoneNumber` and is not disabled.
  A parent's auth record always has a phone (`accounts.ts:115`) and never
  the claim. So a parent who sets a password on their own account through
  the REST API is still refused, and so is an attacker who signs up a new
  password account. Email-link, phone and anonymous sign-in stay blocked,
  and so do password-reset and email-sign-in emails. Every admin password
  sign-in is written to the audit log with the IP.
- **Getting the claim.** Only `FirebaseAdminAccounts.setRole` (behind
  `adminCreateAdmin` with `{ superAdmin: true }`), `scripts/admins.ts` and
  the Prompt 3 `review.ts grant-admin` command set it. `createAdmin` refuses
  an email that already exists (`auth/email-already-exists`), so an account
  an attacker registered in advance cannot be promoted. Custom tokens are
  minted without developer claims.
- **TOTP on every admin callable.** `adminCall` wraps all 14 panel
  callables with `requireAdminCaller`, and `requireAdmin` in
  `verification/callables.ts:168` now uses the same guard. The bypass
  applies only when `FUNCTIONS_EMULATOR === "true"`. Rules: `isAdmin()`
  checks the claim, `sign_in_second_factor` and an 8-hour `auth_time`.
  Rules tests cover a parent with MFA, a `superAdmin`-only claim, an admin
  without MFA and an old session.
- **Session limits.** The 8-hour maximum is enforced on the server
  (functions and rules). The 15-minute idle limit and tab-only persistence
  are enforced in the client only (see non-blocking 2).
- **Super admin only.** Creating, listing, disabling and enabling admins
  all require `superAdmin`. The router hides Admins from regular admins.
  An admin cannot act on their own account or moderate another admin.
- **Audit log.** The rule is `create, update, delete: if false`, with tests
  for admins, super admins, parents and signed-out visitors. Every change
  writes its entry in the same batch or transaction as the change: school
  and area saves, merges, moderation, admin create and disable. Searches,
  user views, case views and decisions are logged too. The search text is
  never logged, only `by` and `results`.
- **User search.** 30 searches per admin per 10 minutes, counted in a
  transaction. At most 20 results. Phones and emails are masked. Nothing is
  listed before a search. No PII goes to `logger` or Sentry (`run()` logs
  only `error.message`).
- **Document viewer.** The image is drawn on the canvas (not an `<img>`
  element), with a tiled diagonal watermark (name, email, time). The
  context menu is off and there is no save button. The 5-minute signed
  links and the view logging come from Prompt 3. Storage CORS is limited to
  the admin site, GET only.
- **Name check.** `decideVerification` refuses an approval of a case with
  children when `nameCheck` is missing (`flow.ts`, `name-check-missing`).
  `nameCheck` is refused on a rejection. It is stored on the case and in
  the audit entry.
- **Suspend and ban.** The `verified` claim is removed before the status is
  written and restored if the write fails. Refresh tokens are revoked. A
  ban adds the national ID hash to `bannedIds`, so the same ID cannot
  register again. `verifyCode` refuses suspended accounts.
- **Schools.** 27 governorate codes, name lengths, coordinates inside an
  Egypt box, edits to merged or awaiting schools refused, merge only from
  `awaiting_review` into `active`, at most 400 children per batch.
- **Parents kept out.** The blocking function refuses them, the router
  (`adminRedirect`) sends anyone who is not a two-step admin to sign-in,
  and the functions and rules refuse them. Widget tests cover both cases.
- **Coordinator merge fixes.** `b523b88` (`"password" as const`) and
  `3b58fb1` (`contains('openCase:case1')`) are correct and harmless. For
  `36911d6` (`multiFactorConfig.state: "DISABLED"`), see "Not verifiable".
- **Hosting.** Separate `admin` target, `X-Frame-Options: DENY`,
  `frame-ancestors 'none'`, `no-referrer`, `noindex`.
- **Design and translations.** No hard-coded colors, sizes, spacing or
  radii in `lib/admin`. Labels use `OneLine`. ARB parity: 592 keys in each
  file, every `l10n.admin*` used in the code exists, and Arabic plurals are
  complete. Every screen has loading, empty, error and offline states. The
  screenshots (15 screens, AR/EN, light/dark) are produced by the CI test
  job, which passed.
- **Costs.** `minInstances` stays at 0. TOTP has no per-message cost. The
  admin web build runs on GitHub Actions, not Codemagic. `docs/COSTS.md`
  has an "Admin panel" section.

## Non-blocking

1. **A disabled admin keeps access for up to 1 hour.** `setAdminDisabled`
   disables the account and revokes refresh tokens, but `onCall` does not
   check revocation, and `requireAdminCaller`
   (`functions/src/admin_panel/access.ts:16`) does not read
   `admins/{uid}.disabled`. An admin who was removed (or whose account was
   stolen) can keep opening ID images until the current ID token expires.
   Fix: in `requireAdminCaller`, also refuse when `admins/{uid}` is missing
   or `disabled`, or compare `auth_time` with
   `getUser(uid).tokensValidAfterTime`. Do this before the pilot.
   Suspended parents have the same 1-hour window with an old `verified`
   token. That belongs to Prompt 3 and later prompts.
2. **The 15-minute idle limit is enforced in the client only.** An ID
   token taken from the tab works for up to 1 hour and refreshes for up to
   8 hours. That matches "short sessions" in the spec, but if the idle
   limit must hold on the server, keep a `lastActiveAt` on `admins/{uid}`
   updated by each callable and refuse after 15 minutes.
3. **Password sign-up is open.** There is no `beforeUserCreated` blocker.
   Anyone can create email/password accounts (sign-in is then refused).
   That fills Auth with junk accounts and can take an email in advance so
   that `createAdmin` fails with `already-exists`. Add a
   `beforeUserCreated` that refuses every client sign-up. Accounts are
   created only through the Admin SDK, which blocking functions do not
   affect.
4. **`review.ts grant-admin`** (`functions/scripts/review.ts:86-92`) still
   sets `admin: true` on any uid, including a parent's, in the cloud dev
   and staging projects. SETUP 13.2 says not to use it. Remove it or limit
   it to the emulators so a parent account can never carry the claim.
5. **Setup link.** `passwordSetupLink` is a password-reset link that works
   for 1 hour. Until the new admin enrolls TOTP, whoever holds the link can
   set the password and enroll their own authenticator. This is already
   listed in "Not done". Add a short note on the Admins sheet ("send it
   privately, it works once, for 1 hour").
6. Some list views are not in the audit log: `adminListReports` shows
   reporter and target IDs, and `adminListSchools`, `adminGetSchool`,
   `adminListAdmins` and `adminListAuditLog` are not logged either. The
   spec asks for every admin *action*, so this is acceptable. Consider
   logging the reports list once report handling arrives in Prompt 9.
7. `FirebaseAdminAccounts.create` followed by `setRole`: if `setRole` or
   the batch fails, an Auth account remains without an `admins` document.
   A retry then fails with `already-exists`. Delete the user when a later
   step fails.

## Not verifiable here

- **`multiFactorConfig.state: "DISABLED"` (`functions/scripts/admins.ts`,
  `36911d6`).** The Admin SDK type needs `state`. Google's TOTP example
  sets only `providerConfigs`. The REST field `mfa.state` is described as
  whether MFA is enabled for the project, and it is not clear that it
  covers SMS only. After running `admins:cloud -- enable-totp` on the dev
  project, check with `getProjectConfig()` that TOTP is `ENABLED`, and
  enroll and sign in once with TOTP. If enrollment is refused, set
  `state: "ENABLED"` with `factorIds: []` (no SMS) instead.
- When `beforeUserSignedIn` runs relative to the TOTP step in a real
  Identity Platform project. This does not affect security, because the
  guard and the rules check the token, but the audit "admin.signIn" entry
  may be written before the second step.
- The "Done when" flow (open the panel, sign in with two steps, approve and
  reject, add a school with a pin, see it all in the log, a parent cannot
  open the panel) needs a deployed dev project with TOTP. It is covered by
  widget tests and the emulator steps in the progress note, but nobody has
  run it in a browser.
- Whether the canvas-only image drawing holds in the deployed web
  renderer (CanvasKit or skwasm) and with the CORS settings on the real
  bucket.

---

# Re-review (head `d9af8ef`)

Reviewed 13 Nov 2026. Changes since `32dfb98`: `1a580e1` (merge of `main`,
which brings Prompt 3's Android JVM 17 fix `ff8417a`), plus the hardening
commits `edfc7ee`, `2d3ead8` and `d9af8ef`.

## Verdict

**PASS.**

## CI result

Run `43449231942` (push, head `d9af8ef`): **success**. All three jobs passed:
Flutter analyze, tests and screenshots; Cloud Functions tests and rules
tests (emulators); and the web, admin panel and Android compile.
Blocking item 1 is fixed.

## Critical check: `beforeUserCreated` does not break parent sign-up

- **How a parent account is created** (`functions/src/auth/accounts.ts:96-125`).
  `verifyCode`, through `signInWithPhone`, calls `findOrCreateAuthUser`. That
  function first tries `auth.getUserByPhoneNumber`. If the user does not
  exist, it creates them with **`auth.createUser({ phoneNumber })` (Admin
  SDK) before** `createToken`, which calls `auth.createCustomToken(uid)`. The
  app then signs in with a custom token for a uid that **already exists**.
  So a parent sign-up never asks the client to create an account.
- **What Firebase triggers.** Identity Platform's blocking-functions page
  says: "Anonymous and custom authentication don't support blocking
  functions." It also says that `beforeCreate` "Triggers before a new user is
  saved ... and before a token is returned to your client app". A Firebase
  maintainer confirms: "Creating users using the Admin SDK will not trigger
  Auth Blocking functions" (firebase-tools issue #6235). So
  `blockClientSignUps` does not run for the parent's `createUser`, for the
  custom-token sign-in, or for `createAdmin` or the bootstrap script.
- **Defense in depth.** If either path ever did reach the function,
  `creationAllowed` (`sign_in_policy.ts`) allows `undefined` and `"custom"`.
  It refuses `password`, `emailLink`, `phone` and federated providers. That
  covers `createUserWithEmailAndPassword`, which was non-blocking item 3.
  Anonymous sign-up cannot be blocked by a blocking function at all, so it
  must stay off in the console. SETUP already says so (around line 317).
- **Related finding.** The same Identity Platform page says that with MFA,
  `beforeSignIn` "triggers after the user verifies their second factor".
  The `admin.signIn` audit entry is therefore written after the TOTP step.
  This settles the second "Not verifiable" item.

## The other fixes, checked

- **Revocation and disabled admins** (non-blocking 1). `requireAdminCaller`
  is now async and reads `admins/{uid}`. It refuses an admin with no record
  or a disabled one (`not-admin`), and refuses a token whose
  `max(iat, auth_time)` is older than `revokedAt` (`session-revoked`).
  `setDisabled` writes `revokedAt` in the same batch as its audit entry.
  In the rules, `isAdmin()` now checks that the record exists, that
  `disabled != true`, and that `iat` is later than `revokedAt`. New rules
  tests cover a missing record, an old token, a new token and a disabled
  admin. Every call site awaits the async guard, including Prompt 3's
  three review callables.
- **15 minutes idle on the server** (non-blocking 2). The guard refuses
  `session-idle` when more than 15 minutes have passed since
  `max(lastActiveAt, auth_time)`. `lastActiveAt` is written at most once a
  minute. The panel calls `adminPing` while the admin is active, and both
  `session-idle` and `session-revoked` sign the panel out.
- **`grant-admin`** (non-blocking 4). It now needs `--allow` and refuses an
  account with a phone number (a parent) or without an email. It writes the
  admin record and an audit entry. Prod is still refused.
- **Audited list views** (non-blocking 6). `admin.list` and `audit.view`
  (written once per opening of the log, not per page) are now logged.
- **No orphan accounts** (non-blocking 7). `accounts.create` runs outside
  the `try`, so an `already-exists` refusal never deletes the existing user.
  Any later failure deletes the new Auth user and, if it was saved, the
  admin record.

## Non-blocking (new)

1. The rules' `isAdmin()` does not apply the 15-minute idle limit; only the
   functions do. The panel reads everything through functions, so this
   matters only for a direct `auditLog` read with a stolen token. That read
   is still limited by revocation, the 8-hour limit and the token's 1-hour
   lifetime. Acceptable; note it for the penetration test.
2. Every admin call now does one extra Firestore read, plus at most one
   write a minute. Each rules evaluation that reads the admin record also
   costs one read. Both are negligible at pilot size.
3. The setup-link item (old non-blocking 5) still stands as documented. The
   one-hour `passwordSetupLink` must be handed over privately.

## Still not verifiable here

- `multiFactorConfig.state: "DISABLED"`: run the new `check-totp` step
  (SETUP) once on the dev project and confirm that TOTP shows `ENABLED`.
- The "Done when" flow with real TOTP in a deployed dev project.
- That canvas-only image drawing holds on the deployed web renderer with
  the real bucket's CORS.

Sources: Identity Platform, "Customize the authentication flow using
blocking functions"
(https://docs.cloud.google.com/identity-platform/docs/blocking-functions);
firebase-tools issue #6235
(https://github.com/firebase/firebase-tools/issues/6235). The Firebase-hosted
blocking-functions pages could not be fetched (robots).

---

# Re-review 2 (head `a6d414d`)

Reviewed 13 Nov 2026. This round checks the work after `f55384c`: the
merges of `main` (design refresh and design follow-ups) in `d1b8758` and
`0bb6466`, and the follow-up `a6d414d`. Only Prompt 4's own adaptation was
reviewed, not the content merged from `main`.

## Verdict

**PASS.**

## CI result

Run `43452558092` (push, head `a6d414d`): **success**. All three jobs passed:
Flutter analyze, tests and screenshots; Cloud Functions tests and rules
tests (emulators); and the web, admin panel and Android compile.

## Checks

- **Behavior and security logic did not change.** The adaptation touched
  none of `functions/`, `firestore.rules`, `storage.rules`, `tests/rules/` or
  `firebase.json`, and `main` did not change them either. In `lib/admin`
  (11 files, +222/-102) the changes are presentation only:
  - `OneLine` became the shared `OneLineText`, with `scaleDown` for the
    sign-in and setup titles and the rail labels;
  - `adminToast` became `showAppSnackBar`;
  - the app bar title became `AppBarTitle`;
  - the `NavigationRail` is wrapped in
    `MediaQuery.withClampedTextScaling(AppTypeScale.maxNavTextScale)`;
  - list rows inside padded content use `inset: false`.

  The router, session, idle timer and ping, the guards, the API calls, the
  confirmations and the watermark painter are all unchanged.
  `WatermarkedImage` changed only in the text component of its
  "image missing" state.
- **ARB parity.** 607 keys in each file and no missing keys. Every
  `l10n.admin*` used in `lib/admin` exists. The label `adminNavOther`
  changed from "New schools" / "مدارس جديدة" to "Other" / "أخرى", the same
  in both languages. This matches the parents' "Other" choice in spec F4.
- **One-line rule.** Every label in the panel now uses the shared
  `OneLineText` or `AppBarTitle`. Rail labels scale down instead of
  wrapping. The new `test/admin/admin_one_line_test.dart` checks this at
  1024 px and 320 dp, and it passed in CI.

## Non-blocking

None new. The earlier non-blocking items and "Not verifiable" items still
stand (TOTP `check-totp` on the dev project, the "Done when" flow with
real TOTP, canvas drawing on the deployed renderer).
