# Review: Prompt 2 (Sign-up with a WhatsApp code, F1 and F44)

Branch: `prompt-02-whatsapp-signup` at `3c12801` (10 commits plus a merge of
`main`). Reviewed 13 Nov 2026 by the validator agent.

Scope: `git diff main...HEAD` (72 files, +5780/-45). I read every changed
TypeScript file, the rules and rules tests, the auth logic, router, sign-up
screens, profile and new components, SETUP.md, COSTS.md and the progress
note. I checked them against CLAUDE.md (COST MODE, SECURITY, PRIVACY, PARENT
ID, DESIGN), `docs/WORKFLOW.md`, `docs/spec.md` (F1, F44, section 3 steps 1
and 2, section 7) and Prompt 2 with its "Done when" list in
`docs/build-prompts.md`.

There is no Flutter SDK here. Results for Dart come from the GitHub Actions
run below.

## Verdict

**CHANGES NEEDED.** Two items block a pass:

1. CI is red: `flutter analyze` reports 17 issues, so the Flutter tests and
   screenshots never ran.
2. The email-link step will probably sign the parent out, and they cannot
   finish that step again afterwards.

The server side is strong. Codes are stored only as HMACs and bound to the
number. Limits apply per number, device and IP. The lockout, the
constant-time compare and the parent ID transaction are correct. The rules
are deny-by-default and the owner can change only `language`. The Functions
tests (66) and rules tests (85) are green in CI.

## CI result

Run `43424836743` (commit `3c12801`, workflow `checks.yml`):

| Job | Result |
| --- | --- |
| Flutter analyze, tests and screenshots | **failure**: `flutter analyze` found 17 issues and exited 1. `flutter test` and the screenshot step were **skipped**. No artifact was uploaded ("No files were found ... test/screenshots/goldens/"). |
| Cloud Functions tests and rules tests (emulators) | **success**: Functions `# tests 66 / # pass 66 / # fail 0`; rules `# tests 85 / # pass 85 / # fail 0` (incl. "the owner cannot change status", "the owner cannot change parentId"). |
| Web and Android compile (staging) | **success**: `flutter build web` and `flutter build apk` compile, so the Dart code has no compile errors. |

## Blocking

1. **`flutter analyze` fails (17 issues); the Dart tests did not run.**
   The exact output from CI:
   ```
   info    • unnecessary_import (firebase_core)            • lib/features/auth/auth_failure.dart:3:8
   info    • prefer_initializing_formals ('this._auth')    • lib/features/auth/auth_repository.dart:55:8
   info    • prefer_initializing_formals ('this._functions') • lib/features/auth/auth_repository.dart:56:8
   info    • prefer_initializing_formals ('this._db')      • lib/features/auth/auth_repository.dart:57:8
   info    • prefer_initializing_formals ('this._installId') • lib/features/auth/auth_repository.dart:58:8
   warning • text_direction_code_point_in_literal  U+2066  • lib/features/auth/phone_number.dart:34:15
   warning • text_direction_code_point_in_comment  U+2069  • lib/features/auth/phone_number.dart:34:21
   warning • text_direction_code_point_in_literal  U+2066  • lib/features/auth/phone_number.dart:36:13
   warning • text_direction_code_point_in_comment  U+2069  • lib/features/auth/phone_number.dart:36:89
   warning • text_direction_code_point_in_literal  U+2066  • lib/features/onboarding/email_screen.dart:182:34
   warning • text_direction_code_point_in_comment  U+2069  • lib/features/onboarding/email_screen.dart:182:42
   info    • use_null_aware_elements                       • lib/features/onboarding/onboarding_layout.dart:94:40
   warning • text_direction_code_point_in_literal  U+2066  • lib/features/profile/profile_screen.dart:123:63
   warning • text_direction_code_point_in_comment  U+2069  • lib/features/profile/profile_screen.dart:123:70
   warning • text_direction_code_point_in_literal  U+2066  • test/auth/auth_logic_test.dart:57:52
   warning • text_direction_code_point_in_literal  U+2069  • test/auth/auth_logic_test.dart:57:69
   info    • prefer_const_literals_to_create_immutables    • test/auth/auth_logic_test.dart:67:47
   17 issues found.
   ##[error]Process completed with exit code 1.
   ```
   Why: CLAUDE.md says no task is done until `flutter analyze` and
   `flutter test` pass. With the analyzer red, none of the widget tests ran.
   That includes the router gate, the wrong and expired code screens, the
   parent ID copy and the screenshots, so none of them is proven yet.
   Fix:
   - Write the bidi isolates as escapes (`'⁦$e164⁩'`), or better,
     add one helper such as `String ltrIsolate(String s)` in
     `lib/design/` and use it in all four places.
   - Remove the `firebase_core` import. `FirebaseException` is re-exported
     by `firebase_auth`.
   - Use initializing formals in `FirebaseAuthRepository`
     (`required this._auth`, which Dart 3.13 allows for private named
     parameters, as the lint suggests).
   - In `onboarding_layout.dart:94` write `<Widget>[?main, ...secondary]`.
   - Make the literal const in `auth_logic_test.dart:67`.

   Then push and confirm that `flutter test` and the screenshot step pass
   too. They may surface more failures.

2. **The email-link step probably signs the parent out, and they cannot
   finish it again.**
   `lib/features/auth/auth_repository.dart:133-137` and
   `lib/features/onboarding/email_screen.dart:286-345`.
   The link from `verifyBeforeUpdateEmail` changes the account's email
   address. Firebase revokes refresh tokens when "a major account change is
   detected for the user. This includes events like password or email
   address updates" ([Firebase, Manage user sessions](https://firebase.google.com/docs/auth/admin/manage-sessions)).
   `confirmEmail()` calls `_currentUser().reload()` first. With the session
   revoked, that call is expected to fail with `user-token-expired` (mapped
   to "unknown"), and FlutterFire then signs the user out. So
   `confirmEmail` on the server is never called.

   The parent lands on Welcome and signs in again with a new WhatsApp code.
   Their record still has `emailVerified: false`, so the router sends them
   to the email screen in its *entry* state (`_sentTo == null`). That state
   has no "I have confirmed" button and makes no automatic check, so the
   only way out is to request another link for the same address.

   This breaks the "Done when" path ("confirm my email, accept the terms,
   and land on verify your account"). I could not run it on a device, but
   the token revocation is documented behaviour.

   Fix:
   - Drop the client `reload()`, or ignore its failure. The server's
     `confirmEmail` already reads the truth with Admin `getUser`.
   - Call `confirmEmail` once when the email screen opens, so a parent who
     signs in again moves straight to terms.
   - Map `user-token-expired` and `requires-recent-login` to a clear
     "Sign in again to continue" message.
   - Add a widget test: email stage, the fake repository's `confirmEmail`
     returns true on open, the router moves to terms.
   - Check it once on the iPhone with the dev project.

## Non-blocking

Security

3. **A stranger can lock a parent out for an hour.** Ten wrong codes in an
   hour lock the *number* (`otp_flow.ts:275-282`). Anyone who knows the
   number can request two codes (60 s apart) and type 10 wrong ones. Brute
   force is already capped by 5 tries per code and 5 codes per hour (at
   most 25 guesses out of a million). Consider counting failures per device
   and IP as well, and locking only those, or locking checks but not new
   codes. At least record the trade-off in the progress note.
4. **The IP limit can turn into one global limit.** `clientIp`
   (`callables.ts:63-71`) takes the *last* `X-Forwarded-For` entry. If that
   entry is a Google front-end address rather than the caller, every parent
   shares one IP key, and sign-in stops for everyone after 60 codes an
   hour. The builder flagged this as unverified (decision 4). Before the
   pilot, log `ipKey` prefixes for a few test calls from different
   networks to confirm they differ. Also add a unit test for `clientIp`
   and make `maxSendsPerIp` a param so it can be raised without a deploy.
5. **App Check tokens can be replayed.** `requestCode` costs money (one
   WhatsApp message per call), and a captured App Check token can be
   reused. Consider `consumeAppCheckToken: true` on `requestCode` and
   `limitedUseAppCheckToken: true` on the client callable. This is listed
   under "Not done"; keep it on the list before prod.
6. `MetaWhatsAppSender.sendCode` (`whatsapp/sender.ts:96`) has no timeout.
   Pass `signal: AbortSignal.timeout(10_000)` so a slow Graph API cannot
   hold the function until its 60 s limit.
7. `acceptConsents` does not check on the server that the email step is
   done, and it can be called repeatedly, which appends records and
   overwrites `whatsappOptIn`. Only the app enforces the order. That is
   harmless now, but add the check when consent withdrawal arrives.
8. Staging also uses the fake sender, so valid codes for real tester
   numbers (masked) appear in Cloud Logging. That is acceptable for fake
   data. Keep the Logs Viewer role limited to the team.

Tests

9. There is no emulator test for `ensureUserRecord` (one transaction
   creating `users/{uid}` and `parentIds/{id}`, with a retry on a taken
   ID) or for the callables wiring. `consents.test.ts` only covers
   validation and `newUserRecord`. Add a small Functions emulator test.
   The 10,000-ID test and the rules tests are good.
10. There is no widget test for the email screen and none for the welcome
    and terms screens' error and offline states. Item 2 needs one.

Design and languages

11. ARB parity is good: 167 keys in each file, every `l10n.*` used in code
    exists, and the placeholders match (the three plural messages are
    fine). The legal texts are drafts marked "draft". The owner and the
    lawyer have to replace them (open question 1).
12. Tokens: no hard-coded colors, sizes, radii or durations in the new
    screens and components. Body text is `bodyMedium` (16) or larger.
    Padding is `EdgeInsetsDirectional`. The code and phone fields read
    left to right. The resend countdown keeps the 48 dp minimum. Not
    checked visually: the code screen has four controls in the fixed
    bottom area, so check it at 200 % text size on a small iPhone once
    screenshots exist.

Process

13. Commit `c0ea62a` refers to the profile screen added in the next commit
    (noted by the builder). The branch head compiles, so this is fine.

## Rule checks

| Rule | Result |
| --- | --- |
| Code hashing | HMAC-SHA256 with `OTP_HMAC_KEY` (Secret Manager). The code hash is bound to the number's key. Phone, device and IP are stored only as keyed-hash document IDs. A unit test proves that no plain code, number, device ID or IP is stored. The emulator key is used only when `FUNCTIONS_EMULATOR=true`; in the cloud a missing key fails closed. |
| Expiry, single use | 5-minute expiry. The code is deleted on success, on expiry, after 5 tries and on lockout. A new request replaces the old code. TTL on `expireAt` is documented (SETUP 11.4). |
| Rate limits, lockout | 60 s cooldown; per hour 5 codes per number, 10 per device, 60 per IP; 10 failures lock the number for 1 h. Transactions return refusals instead of throwing, so counters commit. The send happens after the commit. See items 3 and 4. |
| Timing-safe compare | `timingSafeEqual` on equal-length buffers (`hash.ts`). |
| Enumeration | `requestCode` behaves the same whether an account exists or not. "Suspended" is returned only after a correct code. |
| App Check | `enforceAppCheck: ENFORCE_APP_CHECK` on all four callables. The value is true in `.env.dev`, `.env.staging` and `.env.prod`, and false only in `.env.local` (emulators). |
| Custom token | `createCustomToken(uid)` with **no claims**. "verified" and "admin" are left to later functions. The Token Creator IAM step is in SETUP 11.2. |
| Parent ID | 32-symbol alphabet with no 0, O, 1 or I; unbiased 5-bit mask over `crypto.randomBytes`; random, not derived from the phone or ID number. `parentIds/{id}` is created with `tx.create` in the same transaction as the user record and is never deleted, so an ID is never reused. Only Functions write it (rules closed). The 10,000-ID test passes in CI. |
| Firestore rules | Deny by default. On `users/{uid}`: `get` by the owner only (no list), and `update` only when the changed keys are exactly `language` with the value `ar` or `en`. Consents are read-only for the owner. `parentIds`, `otpCodes` and `otpLimits` are closed even to an admin claim. The rules tests cover status, parentId, role, email, emailVerified, phone, terms and whatsapp fields, create and delete, and other users. **85/85 pass in CI.** |
| Privacy | The fake sender logs `+20********01` and the code (dev and staging only; refused when `APP_ENV=prod`). Meta errors keep only the numeric codes, never the body. Unexpected errors log `error.message` only, never the request data, and go through the Prompt 1 Sentry scrubber. I found no phone number in any log line. |
| Consent records | One append-only record per document (terms, privacy, conduct, plus whatsapp when ticked) with type, version, `acceptedAt`, `withdrawnAt`, `source`. Old versions are refused ("update the app"). WhatsApp alerts are opt-in (open question 2). |
| Email | Sent with `verifyBeforeUpdateEmail`. The server copies the address only after Auth reports it verified. **See item 2.** |
| Cost mode | `MIN_INSTANCES_SIGNIN` and `MIN_INSTANCES` are 0 in every `.env`. Dev and staging use the fake sender (no WhatsApp cost). WhatsApp is used only for codes. Free TTL cleanup. COSTS.md has the sign-in section. No new paid dependency. |
| Dependencies | No new packages (Flutter or npm). |

## Prompt 2 "Done when" coverage

| Item | Status |
| --- | --- |
| Register with a phone number, enter the code | Built (screens, functions, router). Not run on an iPhone. |
| Confirm my email | **Built, but item 2 is likely to break it.** |
| Accept the terms, land on "Verify your account" | Built; the router gate is tested in Dart, but the tests did not run (item 1). |
| Parent ID on the profile with a copy button | Built, with a widget test (not run, item 1). |
| Wrong or expired code refused | Functions unit tests pass in CI. The widget tests have not run. |
| Rules tests: user cannot change status or parent ID | **Pass in CI.** |
| Test with 10,000 parent IDs, no repeat | **Passes in CI.** |
| In dev, code printed in the emulator log | Done (fake sender, masked number). |
| Consent record per document incl. WhatsApp | Done. |

## Not verifiable here

- `flutter test` and the screenshots (skipped in CI because of item 1), so
  there are no AR/EN light/dark images of the new screens yet.
- The whole flow on an iPhone, including iOS one-time-code autofill from
  WhatsApp and the real behaviour of item 2.
- Which `X-Forwarded-For` entry Cloud Run gives the function (item 4).
- The Meta authentication template payload against a live WhatsApp Business
  account. The code matches the documented copy-code shape (body parameter
  plus `button`/`url` index 0).
- Text at 200 %, VoiceOver labels and contrast of the new warning colors
  on a device.

---

# Re-review (round 2)

Branch `prompt-02-whatsapp-signup` at `aa212ba`. Reviewed 13 Nov 2026 by
the validator agent. Scope: `git diff 3c12801..HEAD` (the fixes after round
1), with a security reading of every changed TypeScript file and the Dart
auth and email-screen changes.

## Verdict

**PASS.** Both blocking items are resolved, CI is fully green, and I found
no new blocking security issue. The non-blocking points below should be
handled before the pilot, not before merging.

## CI

Run `43429029313` (head `aa212ba`, branch `prompt-02-whatsapp-signup`),
confirmed with `gh api`: overall **success**.

| Job | Result |
| --- | --- |
| Flutter analyze, tests and screenshots | success |
| Cloud Functions tests and rules tests (emulators), incl. the new emulator tests | success |
| Web and Android compile (staging) | success |

## Earlier items

| # | Item | Status |
| --- | --- | --- |
| 1 | `flutter analyze` 17 issues | **Resolved.** `ltrIsolate` helper in `lib/design/bidi.dart`, import removed, initializing formals (positional), null-aware element, const literal. Analyzer, widget tests and screenshots green. |
| 2 | Email link signs the parent out | **Resolved.** No client `reload()`; `confirmEmail` returns a fresh custom token on the change to confirmed and the app signs in with it; check on open and on resume; `user-token-expired`, `invalid-user-token`, `requires-recent-login`, `user-not-found` and callable `unauthenticated` map to "Sign in again" with a button; on the next WhatsApp sign-in `ensureUserRecord` copies the verified email from Auth, so the parent goes straight to terms. Widget and emulator tests added. Still to try once on an iPhone. |
| 3 | Stranger locks a parent out | **Changed, see N1.** Lock is now per number and device; a daily cap per number was added. |
| 4 | IP key may be global | **Resolved for now.** `clientIp` in its own file with a unit test, `CLIENT_IP_HOP` and `OTP_MAX_SENDS_PER_IP` params, a hash-prefix log outside prod and SETUP 11.7 to check two networks. |
| 5 | App Check replay | Still deferred, listed under "Not done". Keep it before prod. |
| 6 | WhatsApp call timeout | **Resolved.** `AbortSignal.timeout(10_000)`, tested. |
| 7 | `acceptConsents` order on the server | Deferred (unchanged), acceptable. |
| 9 | Emulator test for `ensureUserRecord` | **Resolved.** 6 emulator tests, run in CI. |
| 10 | Email screen widget test | **Resolved** (signup_screens_test). |

## Security re-check

- **`confirmEmail` token.** `uid` comes only from `request.auth` (no input
  is read), so it can mint a token only for the caller's own account. It
  reads the truth from Admin `getUser`, refuses a suspended record, and
  writes and mints only when `emailConfirmationIsNew` (record not yet
  verified, or a different address); a repeat call gets `{ verified: true }`
  without a token. The custom token has no claims. Revocation: the
  callable does not check `checkRevoked`, which is what lets the revoked
  session after the email change get its one fresh token; the window is
  the ID token's remaining life (at most 1 h), once, for the same uid.
  Acceptable. See N3.
- **Blocking functions.** `beforeUserSignedIn` and `beforeEmailSent` from
  `firebase-functions/v2/identity` (v7) with `HttpsError` from the same
  module; this compiles in CI. The method is read from
  `credential?.signInMethod`, falling back to
  `additionalUserInfo?.providerId`. For password and email-link sign-in
  the SDK reports `password` / `emailLink`, phone gives `phone`, anonymous
  gives `anonymous`; all four are refused. Custom-token sign-in is not in
  the list and `undefined` is allowed, so the WhatsApp path cannot be
  blocked by this policy. `beforeEmailSent` refuses `PASSWORD_RESET` and
  `EMAIL_SIGN_IN` and lets `VERIFY_AND_CHANGE_EMAIL` through, so the email
  step still works. Not exercised by any emulator test; the builder lists
  the real-project check (owner step 7). See N2.
- **Lockout and cap.** Lock key is `HMAC(lock:phone:device)`; the daily
  failure count lives on the number's limit document, rolled over 24 h,
  and is checked in both `requestCode` and `verifyCode`. All writes are in
  the transaction and refusals are returned, so counters commit. A right
  code resets only the device lock, not the daily count (correct). No
  plain value in any key (tested). Brute force stays bounded: at most 25
  guesses an hour and 30 a day per number out of 10^6.
- **Logs.** The only new log line is `ipKeyPrefix` (10 hex chars of a keyed
  hash), outside prod only. Blocking functions log nothing; their error
  messages carry no PII. No phone, code, email or IP in any new log.

## Non-blocking

- **N1. The daily cap is a longer lockout for the same effort.** Device IDs
  come from the client, so a stranger can rotate them past the per-device
  lock. Reaching 30 failures needs 6 codes (5 per hour per number, 60 s
  apart), so a little over one hour, not "6 codes over 6 hours" as the
  progress note says. The parent is then closed for the rest of that 24 h
  window, and the attack can be repeated daily. Before the pilot: correct
  the note, make `maxFailuresPerPhonePerDay` a param, and consider an
  admin unlock (or letting a known device of the account through) plus an
  audit entry for a daily lock. The shared 5-codes-per-hour send cap per
  number is the same kind of nuisance and predates this round.
- **N2. Blocking functions are on the sign-in path with `minInstances` 0.**
  Identity Platform gives a blocking function about 7 s; a cold start
  plus a failure would stop every sign-in, including custom-token ones.
  Check the cold-start time on dev, keep them tiny (they are), and note in
  COSTS.md that raising their `minInstances` is the fix if sign-ins time
  out. Also confirm on dev that a custom-token sign-in passes and that a
  password reset from the console's REST call is refused.
- **N3. `confirmEmail` could require a recent email change.** Optional
  hardening: mint the token only when the record was unconfirmed and the
  Auth user's `tokensValidAfterTime` is recent (the revocation from the
  link), so an old ID token from a session revoked for another reason
  cannot use it.
- **N4.** Item 5 (App Check replay on `requestCode`) is still open; it
  protects WhatsApp cost and should land before prod.

## Not verifiable here

The full flow on an iPhone (email link, session revocation and re-sign-in),
blocking functions on a real Identity Platform project, and the
`X-Forwarded-For` hop on Cloud Run.
