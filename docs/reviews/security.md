# Review: branch `security` (security review, 16 Nov 2026)

Reviewed: f64541c..fa4c919 (11 builder commits), plus validator commits
d13ee6d (breach deadlines), 749a4b4 (app money default), the rules-test
compile fix, and the merge of origin/main 93b6b61 (architecture: shared
callable wrapper, collection constants, architecture tests).

## Verdict: PASS (after the validator fixes below)

No blocker left. One open item from the builder (app shows Settle up when
`config/features` is missing) was fixed here as B1.

## Blockers (fixed)

- **B1 Money default in the app.** The server treated a missing
  `config/features` as all money off, but `FeatureSwitches.pilot` in the
  app still had `settleUp: true`, so a project without the document showed
  Settle up entries (callables refused). Fixed: `settleUp: false`; tests
  that meant "Settle up on" now use `pilot.copyWith(settleUp: true)`
  (feature_switches, privacy, carpools, admin settings, screenshots).
  owner-actions item 21 and progress updated.
- **B2 Breach notice wording (coordinator / legal-egypt).** runbook.md and
  SECURITY.md said parents are told "without undue delay where there is a
  risk". Law 151 Executive Regulations: PDPC within 72 hours, data
  subjects within 3 working days of notifying the PDPC, no risk threshold.
  Both now state that and point to docs/legal/breach-runbook.md.

- **B3 Rules tests did not compile** (written, not run by the builder):
  `security_review.test.ts` passed `UploadTask` to `assertFails`/
  `assertSucceeds`, and `admin.test.ts` put `sign_in_second_factor` in a
  typed `firebase` literal. Fixed (`.then(() => undefined)`, identity built
  with `withMfa`). Full CI run 43886466536 on that head: green.

## Merge with main (architecture)

origin/main 93b6b61 merged cleanly (27dddb3). The security changes sit on
the step-up options of `requireAdminCaller` / `adminCall`, the
`USERS` constant and `appEnv()`, which the wrapper does not touch; no new
collection literal or callable without App Check. Functions unit tests
here: 910 pass, 0 fail (architecture tests 6/6).

## Merge with main (legal-egypt)

origin/main 2142092 merged. Conflicts resolved to main's side where
legal-egypt did the same work more widely: `PILOT_DEFAULTS` /
`FeatureSwitches.pilot` (all off, plus the new `contributions` switch,
`MONEY_FEATURES` = wallet, settleUp, contributions) and the matching Dart
and Functions tests; SECURITY.md incident steps 5-6 (legal clock lives in
docs/legal/breach-runbook.md). Kept from this branch: super-admin step-up
on `adminSetFeature` (covers `contributions` too), TOTP-only, suspension
rules. runbook.md now starts the clock with Admin panel > Incidents and
links the legal runbook. The new incident callables use
`requireAdminCaller` (TOTP applies; no step-up, so reporting is never
delayed). Functions unit tests here: 927 pass, 0 fail.

## Checked, no change needed

1. **Suspension in rules.** `notBlocked()` reuses `userRecord()` /
   `hasUserRecord()` already read by `sessionValid()` and `deviceChecked()`
   (same document, so no extra `get()`/`exists()` against the 10/20 limit,
   no extra read cost). A missing `users/{uid}` passes (`!hasUserRecord()`),
   so parents mid-sign-up are not locked out. The parent's own
   `users/{uid}` read still uses `sessionValid()` only, so the app can show
   the suspended state. Admin reads use `isAdmin()` and are unaffected.
   `FirebaseClaimsService.revokeSessions` writes `sessionsValidAfter` the
   same way `privacy/callables.ts` already did; callers (suspend, ban)
   always act on an existing user.
2. **TOTP-only.** Functions (`hasTotpFactor`) and rules
   (`sign_in_second_factor == 'totp'`) agree; Identity Platform puts
   `"totp"` there for TOTP sign-ins, which is the owner's factor. Rules and
   functions tests cover SMS (`phone`) and odd values. Emulators unchanged
   (`mfaRequired()` off; the rules already required the claim before).
3. **Step-up (< 30 min).** Applied to photos, routes, device-check
   clearing, moderation, admin accounts, feature switches. Checked after
   the 8-hour and super-admin checks. `reauth-required` maps to
   `sessionExpired` ("Your session ended. Sign in again.").
4. **APP_ENV fails closed.** `functions/.env.local` (emulators,
   `demo-school-carpool`), `.env.dev`, `.env.staging`, `.env.prod` all set
   APP_ENV; the emulators also set `FUNCTIONS_EMULATOR=true`. Unit tests
   pass in CI.
5. **Setup script IAM.** Token Creator is added on the functions SA itself
   first, then the project-wide binding is removed only if present
   (idempotent; failure falls back to a TODO). The functions only sign as
   themselves (`getSignedUrl`, `createCustomToken`); Secret accessor,
   Eventarc receiver and the Storage agent's Pub/Sub grant are untouched.
6. **OTP allowance.** "Known" needs a `knownDevices` record written only
   after a correct code on that phone + device. A known device gets its own
   cooldown and hourly cap (lock record), but the device and IP caps still
   apply and the number's counter is still incremented, so unknown devices
   stay capped as before. The lock record keeps `lockedUntilMs` and the
   failure fields (spread). No new bypass found.
7. **Headers.** Admin enforced CSP is only `frame-ancestors`, `base-uri`,
   `object-src`, `form-action 'none'` (Flutter's autofill form calls
   preventDefault, so no navigation); full policy report-only (now also
   lists the Maps script and tile hosts, injected into the shared
   web/index.html when a web Maps key is set). COOP same-origin is safe:
   the panel uses email/password + TOTP, no popups. Links site pages
   (hosting/links) have no forms, base or external assets.
8. **CI.** `persist-credentials: false` on the three check jobs only; the
   `locks` job keeps the default credentials and `contents: write`, so it
   still pushes. Fail-fast uses `GH_TOKEN` env, not the git config.
   `npm audit` is report-only. `tool/test_ci_security.py` asserts this and
   runs in the Python tool tests.

## Notes (not blocking)

- **N1** Step-up has no in-place re-authentication: the action shows
  "Your session ended. Sign in again." while the panel stays signed in;
  the admin uses Sign out in the rail and signs in again. A dedicated
  message, or an automatic sign-out on `reauth-required`, would be clearer.
- **N2** The panel's own check (`admin_session.dart`) accepts any second
  factor; an SMS-enrolled admin passes the panel check and then gets
  `mfa-required` from the server. Harmless (owner uses TOTP; SMS MFA is to
  stay off per owner-actions item 4).
- **N3** HSTS `includeSubDomains` on a custom apex domain would apply to
  every subdomain; fine on `*.web.app` and on dedicated subdomains.
- **N4** `functions/src/features/model.ts` has two doc comments stacked on
  `PILOT_DEFAULTS` (cosmetic).
- **N5** Builder open items stand: dedicated functions service account,
  enforcing the admin CSP after the console check, phone-number change not
  signing other phones out, a stranger's code replacing the pending one.
- The first full run on fa4c919 (43885336778) was cancelled after
  1m27s; the next run showed B3 as the cause (fail-fast).

## CI

Full run (`full=true`) on the merged head: see the coordinator report.
