# Prompt 3: Identity verification (F2, F3, F18) — progress note

Branch: `prompt-03-identity-verification` (from the Prompt 2 branch, which
is still under review). Date: 13 Nov 2026. The coordinator gave "go" on the
owner's behalf.

**Status: code complete, not compiled.** No Flutter SDK or package
registry here. See "Verified here vs not run".

## Plan that was followed

1. Functions: national ID check and keyed hash, `KycProvider` (fake and
   Valify stub), submission validation, submit / decide / view / remove
   child, daily image deletion job, reviewer script.
2. Rules: Storage (own pending folder only, no reads) and Firestore
   (children, vehicles, server-only collections), index, emulator tests.
3. App: camera capture with liveness prompt, compression, screenshot
   blocking, draft in memory, resumable uploads, six verification steps,
   status screens, Children and Driving screens under Profile, gallery
   components, AR/EN strings.
4. Tests, screenshots, SETUP.md section 12, COSTS.md, this note.

## How it works

1. The parent (status `unverified` or `rejected`) opens **Start
   verification**: your details (name as on the ID, 14-digit number checked
   as typed, ID expiry date), ID front and back, live selfie, children
   (name, age, grade, typed school name, school ID photo), driving
   (optional: plate, model, color, passenger seats, both expiry dates,
   license and car license photos), then review and consent.
2. **Send for review** uploads each compressed image to
   `verification/{uid}/pending/{name}` (one upload per image; a retry sends
   only what is missing) and calls `submitVerification`.
3. The function checks everything again, refuses a **banned** or
   **duplicate** national ID (keyed hash only), copies the images to
   `verification/{uid}/cases/{caseId}/`, deletes the pending copies, runs
   the **KycProvider**, writes the case (`awaiting_review`), the children
   and car (`pending`), consent records (`id`, `face`, `childData`), and
   sets the account to `pending`.
4. Only `decideVerification` (callable, **admin claim required**) approves
   or rejects with a reason code (and optional note, optional ban). Approve
   sets status `verified` and the **`verified` custom claim**; the app
   refreshes its token when the status changes, and the router opens the
   full app. Reject shows the reason and **Fix and resubmit**; the ID claim
   is released so its real owner can still register. Ban adds the hash to
   `bannedIds`, suspends and signs the account out.
5. `purgeVerificationImagesDaily` (03:10 Cairo, minInstances 0) deletes
   case images 5 days after the decision (so always within 7 days),
   uploads never submitted after 3 days, and orphaned case folders.

A verified parent later adds, edits (new photo, reviewed again) or removes
children on **Profile > Children**, and adds or changes the car on
**Profile > Car and license**. A rejected update does not unverify the parent.

## Data model

| Where | Fields | App access |
| --- | --- | --- |
| `users/{uid}` (new fields) | firstName, lastName, idExpiry, verifiedAt, verification {caseId, scope, status, reasonCode, note, submittedAt, decidedAt} | owner read; still only `language` writable |
| `children/{id}` | ownerUid, firstName, age, grade, schoolName, schoolId (null until F4), status, schoolIdChecked, reasonCode, caseId | owner get/list (query by ownerUid) |
| `vehicles/{uid}` | driverUid, plate, model, color, seats, licenseExpiry, carLicenseExpiry, status, reasonCode, caseId | owner get |
| `verifications/{caseId}` | uid, scope, status, nationalIdHash, identity {names, idExpiry, livenessChallenge}, children, driver, files, kyc {provider, result, score, reference}, submittedAt, decidedAt, reviewerUid, reasonCode, note, purgeAt, imagesDeletedAt | none |
| `nationalIds/{hash}`, `bannedIds/{hash}`, `config/kyc`, `auditLog/{id}` | | none |

The national ID **number is never stored** (only `HMAC-SHA256` with
`NATIONAL_ID_HMAC_KEY`). Nothing from the back of the ID is kept except
the expiry date.

## Decisions

1. **Packages (new, justified):** `camera` 0.12.2 (official flutter.dev
   plugin; needed for our own preview, frame overlay and the liveness
   prompt, which image_picker cannot do; camera only, no gallery code
   anywhere); `flutter_image_compress` 2.5.1 (native, fast, drops EXIF so
   no location leaks; falls back to the original bytes on web);
   `screen_protector` 1.5.3 (Android FLAG_SECURE, iOS secure text field
   layer plus blurred app switcher; versions 1.4.4 to 1.4.13 had crashes,
   1.5.x is fixed). All three ship Swift Package Manager support.
   Versions checked against the GitHub release tags.
2. **Captures live in memory only.** The camera's temporary file is read,
   compressed and deleted at once; nothing is written to the gallery or
   app storage. Closing the app loses an unfinished draft (privacy first).
3. **Resumable uploads:** each image is its own Storage upload; the
   Storage SDK retries and resumes a dropped upload for up to 2 minutes,
   and a failed submission keeps track of what was already uploaded, so
   the retry sends only the rest. If the server finds an upload missing,
   the app uploads it again once.
4. **Liveness:** the app takes a straight selfie, then asks the parent to
   turn their head left or right (random) and takes a second photo after a
   3-second count. The reviewer checks the direction. Automated liveness
   comes with the Valify SDK (F18).
5. **KYC result is advisory.** Every case goes to a person; `no_match` or
   `error` is shown to the reviewer.
6. **Pending folder + copy on submit** keeps the Storage rules simple (no
   cross-service rules): the parent can only write their own pending
   folder; case files are reachable only by Functions.
7. **Admin reads** go through `openVerificationCase`: 5-minute V4 signed
   links, every view written to `auditLog`. Decisions are logged too.
8. **Car license photo** is captured too (the spec lists the driver's
   license photo; without the car license the reviewer cannot check its
   expiry). Deleted like the others.
9. **Child age** is stored as given (spec "age"); the yearly re-check
   (spec section 3) will refresh it.
10. **School** is typed for now (`schoolName`, `schoolId: null`); F4
    (Prompt 4B) adds the list.
11. **One car per parent** (`vehicles/{uid}`) for now.
12. **Rejected ID released, banned ID kept** (see "How it works").
13. **Reviewer script** (`functions/scripts/review.ts`) uses the same
    decision code as the function, so testing before the admin panel
    behaves exactly the same.

## Screen states

| Screen | Loading | Empty | Error | Offline |
| --- | --- | --- | --- | --- |
| Verify account (status) | skeleton | n/a | via start screen | via start screen |
| Verification steps | n/a (nothing loads) | per step: what is missing, button off | inline message with what to fix | inline warning; photos kept, retry sends only the missing ones |
| Camera | spinner while starting / preparing | n/a | camera failed (retry); camera denied (how to allow it) | not needed |
| Child form | n/a | button off + what is missing | field errors as typed | n/a (caller uploads) |
| Children | skeleton | empty view (where to add) | error view + retry; inline send errors | offline view + retry |
| Car and license | skeleton | "no car yet" + form | error view + retry | offline view + retry |

## Screenshot blocking: limits

- Android: FLAG_SECURE, reliable; recordings and the app switcher show
  black.
- iOS: no public API. The plugin uses the secure text field layer, which
  hides the content in screenshots and recordings on current iOS
  versions; Apple could change this. The app switcher snapshot is blurred.
- Web: not possible.
- Nothing stops a second phone filming the screen.

## How to test on your iPhone (the "Done when" check)

Prerequisites: Prompt 2 setup, SETUP.md section 12 (secret, deploy), dev
build installed.

1. Sign in with a fake number, finish email and terms. You land on
   **Verify your account** (Not verified). Tap **Get verified**.
2. Fill in names, a fake 14-digit number (for example 29001150123456) and an
   expiry date. Try 7 digits: "Enter all 14 digits."
3. Take the ID front and back (the camera opens, never the gallery). Try a
   screenshot: it comes out blank.
4. Selfie: look straight, tap, then turn your head as asked.
5. Add a child (name, age, grade, school, school ID photo). Driving: skip
   or fill it in. Tick consent and **Send for review**.
6. You see **Under review**. In a terminal: `REVIEW_PROJECT=<dev id> npm
   --prefix functions run review:cloud -- queue`, then `... -- approve
   <caseId>`. The app opens fully (Home, Carpools...). 
7. Second account, same ID number: "This ID number is already used by
   another account".
8. Rejection: on another account, `... -- reject <caseId> selfie_mismatch
   "Remove sunglasses"`: the status screen shows the reason, the note and
   **Fix and resubmit**.
9. `... -- kyc no_match` makes the next case show the fake result
   `no_match` to the reviewer (queue column `kyc=`).
10. Profile > Children: add, edit or remove a child (verified account).

The deletion job is proven by `functions/test/verification_flow.test.ts`
("purgeVerificationImages"); in the cloud it runs daily.

## Tests

| Test | Status |
| --- | --- |
| `functions/test/national_id.test.ts`: format, dates, governorates, age 18, keyed hash | **Run here: pass** |
| `functions/test/kyc.test.ts`: fake match/no_match/error from the setting, no image reads, fake refused in prod, Valify stub fails closed to "error" | **Run here: pass** |
| `functions/test/verification_flow.test.ts`: validation, submit (hash only stored, pending set, uploads moved, consents), **duplicate ID refused**, **banned ID refused**, missing uploads listed, case open, approve (**verified + claim**), reject (claim cleared, ID released, resubmit), ban, own case / twice, admin view (signed links, logged), children add/edit/remove, **deletion job removes images within 7 days and not before**, orphan and stale uploads | **Run here: pass (40 tests)** |
| Prompt 2 Functions tests (otp, parent ID, phone, WhatsApp) | Run here: still pass (50) |
| `tests/rules/verification.test.ts`: owner uploads to own pending folder only (known names, JPEG, under 3 MB); nobody reads, lists or deletes images, admins included; children and vehicles owner-read only, no writes; verification fields on users not writable; verifications, nationalIds, bannedIds, config, auditLog closed | Written, not run here |
| `test/verification/verification_logic_test.dart`: national ID, draft and payload, retake forgets upload, **resumed uploads**, failures, records, router gate | Written, not run here |
| `test/verification/verification_screens_test.dart`: status pending / rejected with reason and resubmit, field check, full submission with a fake camera, duplicate ID message, children list and remove, paused while pending | Written, not run here |
| Screenshots: details step, pending, rejected, children, car and license (AR/EN, light/dark), gallery with the new components | Written, not run here |

## Verified here vs not run

Run here: Functions unit tests above (Node 22, compiled with `tsc` against
stand-in type stubs for firebase-admin, firebase-functions and Sentry);
type-check of all Functions code incl. `scripts/review.ts` (only stub
gaps remain); ARB parity (319 keys each); import order and bidi-character
scan of every changed Dart file. Checked against sources: camera 0.12.2,
flutter_image_compress 2.5.1, screen_protector 1.5.3 (tags on GitHub),
FlutterFire storage/functions APIs (`putData`, `setMaxUploadRetryTime`,
`HttpsCallableOptions`), material_ui `DropdownButtonFormField.initialValue`
(`value` is deprecated), firebase-functions `onSchedule` options.

Not run: `flutter analyze`, `flutter test`, `flutter gen-l10n`,
screenshots, `npm test` with real packages, rules tests on the
emulators, builds. Expect small analyzer fixes on the first CI run.

## Open questions for the owner

1. **Valify**: contract, API documentation and their mobile liveness SDK
   (adds a native dependency). Until then: fake provider + reviewer.
2. **Retention**: images are deleted 5 days after the decision. Shorter?
   (A reviewer may want to look again after an appeal.)
3. **Car license photo**: OK to capture it (see decision 8)?
4. **Child age vs birth year**: keep age as the spec says, or store birth
   year (does not go stale)?
5. **Mother's ID link** (spec section 3: husband's name on the back of
   her ID): the reviewer reads it from the back image; nothing is stored.
   Confirm.
6. **Lawyer**: consent text for ID, face and child data (draft in ARB,
   version `2026-11-13`), and written guardian consent rules.

## Not done / known gaps

- Admin panel (Prompt 4); until then the reviewer script.
- Notifications on decision (later prompt); the status screen updates live.
- Re-verification on phone or car change and the yearly check.
- Parent ID lookup with first name (F44) can now use `firstName`.
- Schools list (F4), guardian links between two parents.
- Expiry reminders for licenses and blocking driving days after expiry
  (dates are stored).
- The camera screen has no widget test or screenshot (needs a real
  camera); tested by hand on the iPhone.
- Web: camera and compression compile but are not tuned (Stage 2).
- F2 and F3 app code landed in one commit (the steps share the draft).
- Merge note: Prompt 2's branch is changing ARB files, `profile_screen.dart`
  and `gallery_screen.dart`; expect small conflicts there.

## Review round 1 fixes (docs/reviews/prompt-03-review.md)

Blocking:
1. **Analyzer (12 issues):** `return await` in the capture try block;
   null-aware map entries (`key: ?value`) in `VerificationDraft.files`;
   positional initializing formals in `FirebaseVerificationRepository`;
   `const` test maps; unused test import removed.
2. **ID squatting:** `submitVerification` now only *checks* the ID early
   (read-only). The hash is claimed inside the same Firestore transaction
   that creates the case (`saveSubmission`), after uploads, children and
   KYC are done, so a refused submission claims nothing. If another
   account claims the ID in between, the commit fails with `duplicate-id`
   and the copied images are removed. New `withdrawVerification`
   (callable + "Withdraw" button with confirmation on the pending screen)
   releases the claim, resets the account to unverified and schedules the
   images for deletion. Rejection still releases the claim. Tests: missing
   uploads claim nothing and a second account can then use the ID; claim
   at commit; withdraw releases and lets another account use the ID.
3. **Token refresh race:** `decideVerification` sets or clears the
   `verified` claim *before* writing the status, and the same write sets
   `users/{uid}.claimsUpdatedAt`. If the decision write fails, an approval's
   claim is put back. The app refreshes its ID token when that marker
   changes (`tokenRefreshFor` in session.dart), and on the first record of
   a verified account whose cached token lacks the claim. Tests: event
   order claim, then status, then marker; Dart tests for `tokenRefreshFor`.

Non-blocking, done: school ID slots capped to `c1`..`c10` (storage.rules,
server `REF`, app; add button off at 10); the two checkbox labels are one
line now ("I agree to the ID check", "I will drive"), detail moved to the
helper text; prod sets `KYC_PROVIDER=valify`, and a fake in prod logs a
CONFIGURATION ERROR at every instance start (`onInit`) and reports to
Sentry, with submissions answering `failed-precondition`; SETUP.md 12.6
turns off GCS soft delete; compression failure on the phone is now a
capture error (comment corrected: the *shorter* side is scaled);
review script uses `.firebasestorage.app` for cloud projects.

Run here: 49 verification/KYC/national ID Functions tests pass. Dart and
rules tests: written, not run here.
