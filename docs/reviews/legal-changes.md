# Review: branch `legal-changes` (R1-R15, 16 Nov 2026)

Reviewed: 8a0ac62..069324b (15 builder commits plus the progress commit,
main merged in), against CLAUDE.md, docs/architecture/overview.md,
docs/legal/answers.md (R1-R15) and docs/progress/legal-changes.md.
Validator fixes: ee0279c, 1fdec8d, 44a55f6, the CSP/threat-model commit,
the unused-import commit and the consent-copy/terms-test commit (see git log).

## Verdict: PASS (after the validator fixes below)

The final CI run and hash are at the end. No blocker is left open.

## Blockers (fixed here)

- **B1: CI was red on flutter analyze.** `test/design/one_line_test.dart`
  still set the old `consent:` draft field. `consent_copy_test.dart` used
  `OfflineStateView` without importing it and later had an unused
  `flutter_riverpod` import. There was also an import-order info in
  `signup_screens_test.dart` and an angle-bracket doc comment in
  `trip_models.dart`. Fixed: the draft now uses `consentId`, `consentFace`
  and `signedName: 'Mona Hassan'`, the imports are corrected and the doc
  comment uses backticks.
- **B2: R6 changed state on GET.** The contact page gave links
  `/ec/<token>/yes` and `/ec/<token>/stop`, and a GET of either confirmed or
  stopped. That breaks the rule that GET never changes state: a WhatsApp
  preview, a mail scanner or browser prefetch could answer for the contact.
  Fixed: the answers are now `<form method="post">` buttons, and
  `contactRequest()` maps GET and HEAD to "view" on every path. Only
  `POST /ec/<t>/yes|stop` answers, and other methods get 405. The global
  links-site CSP had `form-action 'none'`, which would have blocked the
  buttons, so it is now `'self'` on the links site only. The admin panel
  keeps `'none'`, and the `tool/test_hosting_headers.py` test is updated.
  The page also sends its own CSP, `Referrer-Policy: no-referrer`
  (the token is in the URL), `X-Frame-Options: DENY`, nosniff and noindex.
  Tests were added for POST-only answers, no `<a>` links and the method
  mapping.
- **B3: R6 had no rate limit.** Added `WindowLimiter`, held in memory: 20
  requests per minute per address (best effort, first X-Forwarded-For) and
  120 per minute per instance. With `maxInstances` 5 this caps the
  Firestore reads an attacker can cause. The token is 256-bit, so the limit
  protects cost, not guessing. Unit-tested.
- **B4: Flutter tests failed.**
  - The consent copy screen used a lazy `ListView`, so the fingerprint and
    "Download copy" were never built below the fold. The screen-reader and
    320 dp tests failed. It is now a `SingleChildScrollView` with a
    `Column`, so the short page is built at once.
  - The terms test called `pumpAndSettle` after a successful accept, but
    the spinner stays until the router moves on. It now pumps 3 times.
- **B5: The demo seed had no R3 records.** The App Review demo accounts
  got the new versions and the R4 `teenAgreement` record, but their signed
  consents had no `signature`, so Privacy showed "No copy yet". Now
  `review_demo_lib.ts` writes a signature for each signed kind: the hash of
  the real text, `deviceAuth`, and `nameHash`/`appVersion` set to
  "review-demo". It also writes `users.signedNames`.

## Checks

### 1. Nobody locked out

- **R5:** `signUpOpen(env, s)` is `env !== "prod" || pdpcLicensed`, so dev
  and staging are always open. In prod the gate runs only after a correct
  code and before any account is created. Existing accounts (Auth user
  plus `users` doc), App Review phones (`isReviewPhone`) and demo accounts
  (which have accounts) get in. The admin panel signs in with email, TOTP
  and `signInWithEmailAndPassword`, which never goes through
  `verifyCode`. `config/launch` is server-only, as the rules test shows.
  Switching it needs a super admin, a re-auth within 30 minutes and an
  audit entry, all in one batch.
- **R3 on a phone without a passcode:** `DeviceAuthResult.unavailable`
  falls back to `recentSignIn`, which the server accepts within 10 minutes
  of `auth_time`. Cancelling sends nothing. Older sign-ins get
  "sign in again or set a passcode" (see N5).
- **Terms bump `2026-11-17`:** `RegistrationStage.termsUpdate` asks once,
  and `termsUpdateOpen()` keeps Privacy (delete, export) reachable, as the
  test shows. `acceptConsents` is a no-op once the version is current.
- **Demo seed:** current `CONSENT_VERSIONS` and
  `VERIFICATION_CONSENT_VERSIONS`, including `teenAgreement`, plus the R3
  signatures (B5).

### 2. Security

- **signInLog:** the rules deny reads, lists, creates, updates and deletes
  for everyone, including admins, super admins and the parent with MFA. The
  emulator test is green.
- **Disclosure:** `adminDiscloseSignInLog` requires a super admin, MFA
  through `requireAdminCaller`, a sign-in less than 30 minutes old, App
  Check, and a valid order reference, authority and date. The audit entry
  is written before anything is decrypted or returned. It holds the hashed
  phone target, never the number.
- **Encryption:** AES-256-GCM with a random 12-byte IV per value and the
  auth tag checked. The key comes from the `SIGNIN_LOG_KEY` secret through
  SHA-256. The emulator-only key is used only under `FUNCTIONS_EMULATOR`.
  Logs show only "is not set" or an error message, never the key, number
  or IP.
- **Phone hash:** keyed HMAC. The lookup key is now derived separately
  from the encryption key (44a55f6).
- **R6:** fixed as B2 and B3 above. The token is 32 random bytes in hex
  and serves only this page. A new number gets a new token, and the token
  is deleted with the contact or the account. The response holds only the
  parent's first name, HTML-escaped. There is no App Check because the
  contact is not an app user (justified in the threat-model row added
  here). The Hosting rewrite `/ec/**` points to `emergencyContactReply` in
  europe-west1, and a test checks it.
- **Consent copy download:** the uid comes from auth through `gatedCall`.
  The file is written to `exports/{uid}/`, which is deleted after 1 day,
  and the V4 signed URL lasts 1 hour. Only the owner can get it.

### 3. Deletion

- **Still deleted with the account:** `IMMEDIATE_TARGETS` is unchanged.
  The users doc, including `signedNames`, goes last. Emergency contacts go
  as before. `signInLog` is listed in `NOT_DELETED`. Consents moved to
  `CONSENT_TARGETS`, removed 3 years after closure.
- **Older deletion records:** a `closedAccounts` record purged under the
  1-year rule reads `consentsPurgedAt = purgedAt`, so it is done. An old
  `ptarget:0` step is treated as done. The consent phase runs only after
  the records purge with no failures, and it saves `consentsPurgedAt`, so
  it is idempotent.
- **R12:** only `verification/{uid}/cases/{caseId}/` is deleted, with its
  thumbnails. The face reference (`faceRefs/`) and the driver photo
  (`driverPhotos/`) are copies made at approval and are not touched. Cases
  awaiting review are skipped. The composite index status, imagesDeletedAt,
  decidedAt is added, and cases have carried `imagesDeletedAt: null` since
  creation.
- **R11:** `routeArchives` are deleted by `purgeAt` or by `endedAt` older
  than 90 days (the field exists). `tool/storage_lifecycle.json` is valid
  JSON. The only rule that changed is `routeArchive/` (400 to 120 days, a
  safety net after the 90-day job), so no other prefix is affected.

### 4. Name normalisation

The app and the server run the same steps in the same order: diacritics,
tatweel, alef/teh marbuta/yeh/waw/yeh forms, non-letters to a space, then
joining عبد/abd/abdel. They also use the same `nameMatches`. The Dart and
TS test files share the same examples and both pass (CI). See N4 for edge
cases.

### 5. Architecture, ARB, one-line labels, states

- **Architecture and wrapper:** the architecture tests pass in the
  Functions suite. The new callables use `runCallable` and the
  `onRequest` HTTP function follows the `tripLocation` pattern.
- **ARB:** AR and EN have the same keys (checked).
- **One-line labels:** the one-line test passes in CI, including at
  320 dp in Arabic.
- **States:** the consent copy screen has loading, empty, error and
  offline states, and all of them are tested.

### 6. CI

The full run is green (see the end). Functions unit tests here: 962 pass,
0 fail.

## Notes (not blocking)

- **N1:** the disclosure reads the ciphertext before writing the audit
  entry, because the count needs the read. Nothing is decrypted or
  returned before the audit, which is acceptable.
- **N2:** `byUid`/`byPhoneKey` use `limit(500)` with no `orderBy`. Past
  500 lines in 180 days, the newest lines could be missed. Add
  `orderBy("at","desc")` with an index if that ever happens.
- **N3:** the contact token is stored as plain text on the parent's own
  `emergencyContacts/{uid}`, which the parent can read so the app can
  rebuild "Send the link". `tripLocation` stores a hash instead. This is
  acceptable because it is the parent's own document, the token has a
  single purpose, and a new number rotates it.
- **N4:** for Latin text the server uses NFKD/NFKC, while the app maps a
  fixed list of accents. Neither side folds Persian ی/ک. On those rare
  inputs the app is stricter than the server, so the server still decides.
  Add ی→ي and ک→ك on both sides if testers hit it.
- **N5:** after a terms bump, a phone with no passcode and a sign-in older
  than 10 minutes gets "To sign, sign in again or set a phone passcode."
  The screen has no "Sign in again" button. This is not a lockout, because
  Privacy is reachable and a passcode works, but a button would help.
- **N6:** the R6 limit is held in memory per instance (best effort). The
  hard cap is `maxInstances` 5.
- **N7:** check the goldens and screenshots of the new screens (consent
  copy, Opening soon, signing) in the CI artifact, in Arabic and English,
  light and dark.
- **N8:** the builder notes that a route under an open safety report is
  not held past 90 days.
- **N9:** `SIGNIN_LOG_KEY` cannot be rotated while lines younger than 180
  days exist, as documented in `config.ts`.

## CI

Full run (`full=true`) **43908353321 on 40372d7: green**. It covers flutter
analyze, flutter tests and screenshots, Functions unit tests, Functions on
the emulators, Firestore and Storage rules tests, the Python tools, and
the web, admin and Android compile. This review file is the only change
after that commit (docs only).
