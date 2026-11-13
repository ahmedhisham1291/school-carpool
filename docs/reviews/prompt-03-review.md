# Review: Prompt 3 (Identity verification, F2, F3, F18)

Branch: `prompt-03-identity-verification`, head `57f5147` (includes the
merged Prompt 2 branch). Reviewed 13 Nov 2026 by the validator agent.

Scope: Prompt 3's own changes, `git diff prompt-02-whatsapp-signup...HEAD`
(57 files, +7948/-43). Checked against CLAUDE.md (STACK, COST MODE,
SECURITY, PRIVACY, DESIGN, LANGUAGES, TESTS, ENVIRONMENT NOTE),
`docs/WORKFLOW.md`, `docs/spec.md` (section 3, F2, F3, F18, section 7, and
the Verification, Child, Vehicle and Guardian link rows in section 9),
`docs/build-prompts.md` (Prompt 3 and its "Done when") and
`docs/progress/prompt-03.md`.

There is no Flutter SDK here. `flutter analyze` and `flutter test` were
**not run here**. The CI results below come from GitHub Actions.

## Verdict

**CHANGES NEEDED.**

CI fails at `flutter analyze` with 12 issues. Two logic problems also need a
fix before merge: an ID number can be claimed without submitting a case, and
the token refresh runs before the claim is set. The backend design is
otherwise strong. The national ID is stored only as an HMAC under its own
secret. Duplicate and ban checks run in a transaction. Only an admin can
decide, and the decision sets the status and the `verified` claim. The
bucket has a pending-only upload path and no client reads. Admins get
5-minute signed links, and each view is written to the audit log. Images are
deleted 5 days after the decision. The Valify stub is off and fails closed.

## CI result

Run `43431164538` (push, head `57f5147`): **failed** (shown as "cancelled"
because the first failing job cancels the others).

| Job | Result |
| --- | --- |
| Flutter analyze, tests and screenshots | **`flutter analyze` failed (exit 1, "12 issues found")**; tests and screenshots skipped |
| Cloud Functions tests and rules tests (emulators) | Functions build and unit tests **passed**; emulator user-record tests **passed**; Firestore/Storage rules tests **cancelled, not run** |
| Web and Android compile (staging) | Bootstrap passed (so `flutter pub get` resolved the three new packages); build web **cancelled, not run** |

## Blocking issues

1. **`flutter analyze` fails: 12 issues. CI runs it with infos fatal (the default).**
   Quoted from the job log:
   ```
   warning • Returning a 'Future' without 'await' inside a try block • lib/features/verification/capture_screen.dart:185:7 • unawaited_return_in_try_block
   info • Use the null-aware marker '?' rather than a null check via an 'if' • lib/features/verification/verification_draft.dart:186:5 • use_null_aware_elements
   info • (same) • lib/features/verification/verification_draft.dart:187:5
   info • (same) • lib/features/verification/verification_draft.dart:188:5
   info • (same) • lib/features/verification/verification_draft.dart:189:5
   info • Use an initializing formal ('this._storage') • lib/features/verification/verification_repository.dart:37:8 • prefer_initializing_formals
   info • (same, '_functions') • lib/features/verification/verification_repository.dart:38:8
   info • (same, '_db') • lib/features/verification/verification_repository.dart:39:8
   info • Use 'const' literals as arguments to constructors of '@immutable' classes • test/verification/verification_logic_test.dart:216:41 • prefer_const_literals_to_create_immutables
   info • (same) • test/verification/verification_logic_test.dart:220:25
   info • (same) • test/verification/verification_logic_test.dart:228:59
   warning • Unused import: 'package:school_carpool/features/verification/capture_screen.dart' • test/verification/verification_screens_test.dart:14:8 • unused_import
   ```
   Fix:
   - `capture_screen.dart:185`: change the line to `return await compressor.compress(...)`.
   - `verification_draft.dart:186-189`: use null-aware map entries, e.g. `VerificationDocument.idFront.fileName: ?idFront`. Do the same on lines 191 and later if the analyzer flags them next.
   - `verification_repository.dart:33-43`: use initializing formals, as the lint suggests (`required this._storage`, `required this._functions`, `required this._db`; the lint fires only when the SDK's language version accepts them). If that is not wanted, use positional `this._storage` parameters, or add `// ignore: prefer_initializing_formals` with a reason.
   - `verification_logic_test.dart:216, 220, 228`: add `const` to the map literals.
   - `verification_screens_test.dart:14`: remove the import.

   Then push again so that `flutter test`, the screenshots, the **rules tests** and the web/Android builds actually run. None of them has run on this branch yet.

2. **Anyone can claim someone else's national ID number without submitting a case, and the claim is never released.**
   `functions/src/verification/flow.ts:184-206`. `claimNationalId(hash, uid)` writes `nationalIds/{hash}` **before** the upload check. When uploads are missing, the call fails with `missing-upload`, but the claim stays. No case is created, so no reviewer ever sees it, and no rejection ever releases it. Any signed-up account can call `submitVerification` with a real person's ID number and no images. That person is then refused with "already used by another account" when they try to register. The claim only moves if the same squatter later submits a different number (`store.ts:90-92`).
   Fix: do the hash claim only once nothing else can fail. Run the missing-upload check (and the child ownership checks) first. Better still, make the claim part of the same commit as the case: claim inside `saveSubmission`'s transaction, or release the claim in a `catch` when any later step throws. Add a unit test: a submission refused for missing uploads leaves no `nationalIds` entry, and a second account can then use that ID.

3. **The app refreshes its token before the server sets the `verified` claim, so the new token usually lacks the claim.**
   `functions/src/verification/flow.ts:318-320` commits the status change (`saveDecision`) first and only then calls `claims.setVerified`. `lib/features/auth/session.dart:77-80` calls `getIdToken(true)` as soon as the `users/{uid}` snapshot shows the new status. That snapshot arrives within milliseconds of the commit, before `getUser` and `setCustomUserClaims` have finished. The refreshed token then carries no `verified` claim, and the next automatic refresh can be up to an hour later. The router works from the status, so the "app opens fully" check still passes. But every rule and function that checks `request.auth.token.verified` (SECURITY: "verified ... are custom claims"; later prompts) would deny the parent for up to an hour. Rejection and ban have the same problem when clearing the claim.
   Fix: after `setVerified` (and `revokeSessions`), write a marker such as `users/{uid}.claimsUpdatedAt = serverTimestamp()` from the function. The app then refreshes the token when that marker changes, not when the status changes. Also refresh on the first snapshot when `status == verified` but the cached token lacks the claim. Add a unit test for the order (claim set before the marker is written).

## Non-blocking

1. **GCS soft delete keeps "deleted" images for 7 more days.** New Firebase/GCS buckets have a 7-day soft-delete policy by default. Images removed by `purgeVerificationImagesDaily` stay restorable for up to about 13 days after the decision. Spec section 7 says "within 7 days of the decision (... backups too)". Add a SETUP.md step to turn off soft delete on the bucket in every project (`gcloud storage buckets update gs://<bucket> --clear-soft-delete`), or to set a retention that still totals 7 days or less. Record it in COSTS.md too.
2. **Unbounded upload names.** `storage.rules:22` allows `school_id_[a-z0-9]{1,20}.jpg`, so one parent can upload any number of 3 MB files (cost abuse, cleaned only after 3 days). Limit the refs to what the server accepts (for example `school_id_c[0-9]`, with `MAX_CHILDREN = 10`). Do the same for `REF` in `submission.ts:126` and in the app.
3. **Prod KYC config.** With `KYC_PROVIDER=fake` (the default) in prod, `createKycProvider` throws inside `deps(true)` (`callables.ts:101`), so every submission fails with `internal`, not "error → manual review". Either set `KYC_PROVIDER=valify` in `functions/.env.prod` now (the stub fails closed), or say so in SETUP.md section 12.
4. **Design: one-line labels, short wording (new rule).** Buttons and titles are short in both languages. Two checkbox labels are sentences and will wrap: `verifyConsentLabel` ("I agree that my ID, my face photos and my children's details are used to verify my account" / Arabic equivalent) and `verifyDrivesLabel`. Shorten the labels (e.g. "I agree to the ID check" / "أوافق على التحقق") and move the detail into the helper text. `driverSeatsHelper` and `captureErrorDenied` are long but are body text, so they are fine.
5. **Compression comment.** `image_compressor.dart:1-5, 18-23`: `minWidth`/`minHeight` in flutter_image_compress set the *shorter* side (a 4032×3024 photo becomes about 2133×1600), not the longest. When compression fails on the phone, the original is sent and may go over 3 MB, which the rules then reject with a generic upload error. Fix the comment, and on mobile treat a compression failure as a capture error.
6. `functions/scripts/review.ts:45`: the default bucket `${projectId}.appspot.com` is wrong for projects created after Oct 2024 (`.firebasestorage.app`). Approve and reject do not touch files, so this is harmless today.
7. F2 and F3 app code landed in one commit (noted in the progress note). CLAUDE.md asks for one feature ID per commit; keep them split from now on.
8. `purgeVerificationImages` lists the whole `verification/` prefix every day. That is fine at pilot size; switch to per-case prefixes or a lifecycle rule on `pending/` (age 3 days) when volume grows.

## Checked and fine

- **ID hash**: `HMAC-SHA256("nid:v1:"+digits)` with `NATIONAL_ID_HMAC_KEY` (Secret Manager, separate from `OTP_HMAC_KEY`). The fixed key is used only under `FUNCTIONS_EMULATOR`. The number is never stored or logged. Only `idExpiry` is kept from the back of the ID.
- **Duplicate / ban**: one transaction over `bannedIds` and `nationalIds`. A rejected ID is released and a banned ID is kept. Unit tests for both passed in CI.
- **Decisions**: `requireAdmin` checks the `admin` claim. A reviewer cannot decide their own case or decide twice (transaction). `verified` status, `verifiedAt` and the claim are set only by `decideVerification`. Rules keep `status`, `verification`, `firstName` and `idExpiry` read-only for the app. Each decision and each case view goes to `auditLog`.
- **Storage**: deny by default. The owner can only create or replace known JPEG names (>0 B, <3 MB) in `verification/{uid}/pending/`. Nobody can read, list or delete, admins included. Files are copied to `cases/` on submit and the pending copies deleted. Admins get 5-minute V4 signed URLs.
- **Retention job**: daily 03:10 Cairo, `minInstances` 0 (global option), purge 5 days after the decision. Stale pending files (3 days) and orphaned case folders are deleted. Covered by unit tests, which passed in CI.
- **KycProvider**: the fake reads `config/kyc.fakeResult` and is refused in prod. Valify stays off behind `VALIFY_ENABLED=false`, and its secrets are not bound. `check` always throws, so the result is `error` and a person reviews. The result is advisory.
- **App**: `camera` only, no gallery or picker code. The temp file is deleted right after reading, and the draft lives only in memory. Compression drops EXIF. `SecureScreen` is on the flow, capture, child form and driving form, and the limits are documented. Each image is its own upload with SDK retry, and a retry sends only what is missing. No Sentry or `debugPrint` call carries PII.
- **Rules tests** (`tests/rules/verification.test.ts`) cover every new collection and the Storage paths, but CI has not run them yet (see blocking 1).
- **ARB**: 321 keys in each file. `@@locale` ar/en, Arabic is the template, and plurals have the Arabic forms. No empty strings.
- **Design tokens**: no hard-coded spacing, colors, radii or font sizes in the new screens and components. Each screen has one primary action. A confirmation appears before removing a child. Loading, empty, error and offline states are listed in the progress note and exist in code. The new components are in the gallery.
- **Packages**: `camera` 0.12.2 (`flutter/packages` tag `camera-v0.12.2`), `flutter_image_compress` 2.5.1 (tag `flutter_image_compress-v2.5.1`) and `screen_protector` 1.5.3 (tag `1.5.3`) all exist; I checked them with `git ls-remote`, because pub.dev is blocked here. CI `pub get` resolved them, and the analyzer reports no errors on the `ScreenProtector` / `camera` API calls.
- iOS `NSCameraUsageDescription` (AR/EN) is already set by `tool/patch_native.py`, and `enableAudio: false` means no microphone prompt.

## "Done when" coverage

| Check | Status |
| --- | --- |
| Submit on iPhone, see "pending" | Code present; not verifiable here |
| Approve in the emulator → app opens fully | Router gate on status: yes. Claim timing: see blocking 3 |
| Rejected case shows the reason | Status screen with reason, note and "Fix and resubmit"; widget test written, not run |
| Second account with the same ID refused | Yes, unit test passed in CI (but see blocking 2) |
| Test shows the deletion job removing images | Yes, `purgeVerificationImages` tests passed in CI |

## Not verifiable here

- `flutter test`, golden screenshots, rules tests on the emulators and the web/Android builds: none has run in CI yet because analyze failed first.
- Camera, liveness prompt, screenshot blocking on iOS (the secure-layer behaviour), and upload resume after a network drop: these need a real iPhone.
- V4 signed URLs need the "Service Account Token Creator" role in the cloud (documented), and do not work against the Storage emulator without credentials.
