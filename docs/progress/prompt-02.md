# Prompt 2: Sign-up with a WhatsApp code (F1, F44) — progress note

Branch: `prompt-02-whatsapp-signup` (from `main` after Prompt 1). Date: 13 Nov 2026.
The coordinator gave "go" on the owner's behalf (CLAUDE.md environment note).

**Status: code complete, not compiled.** No Flutter SDK or package registry
here. See "Verified here vs not run" at the end.

## Plan that was followed

1. Cloud Functions: parent ID (F44), WhatsApp sender interface (fake and
   Meta), code request and check with limits and lockout, email
   confirmation, consent records.
2. Firestore rules for the new collections, with emulator tests.
3. Design components for sign-up, added to the gallery first.
4. App: session, router gate, five sign-up screens, verification screen,
   profile with the parent ID.
5. Tests, screenshots, SETUP.md, COSTS.md, this note.

## What was built

### Flow (spec section 3 steps 1 and 2, section 10 screens 1 to 4 and 9)

Welcome (language) > phone > code > email link > terms > "Verify your
account". Returning parents use the same phone and code steps: the server
finds their account. Until an account is verified the router allows only
the verification screen and the Profile tab ("Profile only", spec section
3). Suspended accounts see only a suspension screen with sign out.

### Cloud Functions (`functions/src`)

| File | What |
| --- | --- |
| `auth/parent_id.ts` | 8 characters from `23456789ABCDEFGHJKLMNPQRSTUVWXYZ` (no 0, O, 1, I). 32 symbols, so a random byte masked to 5 bits has no bias. Random, never derived from the phone or ID. |
| `auth/accounts.ts` | Finds or creates the Auth user by phone, then in **one transaction** creates `users/{uid}` (status `unverified`, role `parent`) and `parentIds/{id}` with `create` (fails if the ID exists, so no two accounts share one; the doc is never deleted, so an ID is never reused). |
| `auth/otp_flow.ts` | Logic of `requestCode` / `verifyCode` over a store interface (unit-testable). 6-digit code from `crypto.randomInt`; only an HMAC of it is stored, bound to the number, with a 5-minute expiry; single use; a new code replaces the old. |
| `auth/otp_store.ts` | Firestore storage in `otpCodes` and `otpLimits`; document IDs are HMACs of the number, device ID or IP, never the values. `expireAt` for a TTL policy. |
| `auth/consents.ts` | Validates versions, writes one append-only record per accepted document in `users/{uid}/consents`, sets `termsAcceptedAt`, `termsVersion`, `whatsappOptIn`. |
| `auth/callables.ts` | `requestCode`, `verifyCode` (returns a Firebase custom token), `confirmEmail`, `acceptConsents`. App Check from `ENFORCE_APP_CHECK`. Errors carry `details.reason`. |
| `whatsapp/sender.ts` | `WhatsAppSender` interface. `FakeWhatsAppSender` prints the code with the number masked (`+20********01`). `MetaWhatsAppSender` sends the authentication template (code in body and copy-code button, Graph API v25.0). The fake is refused when `APP_ENV=prod`. |
| `config.ts` | Secrets `OTP_HMAC_KEY`, `WHATSAPP_ACCESS_TOKEN` (Secret Manager); params `WHATSAPP_PROVIDER`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_API_VERSION`, `WHATSAPP_CODE_TEMPLATE`, `WHATSAPP_TEMPLATE_LANG_AR/EN`, `MIN_INSTANCES_SIGNIN` (default 0). |

**Limits** (`DEFAULT_OTP_LIMITS`): 60 s between codes for one number; per
rolling hour at most 5 codes per number, 10 per device, 60 per IP; 5 tries
per code; 10 wrong codes in an hour lock the number (no codes, no checks)
for an hour. The IP cap is high on purpose: Egyptian mobile carriers put
many users behind one IP.

### Data model

| Collection | Written by | App access (firestore.rules) |
| --- | --- | --- |
| `users/{uid}`: parentId, status, role, phone, email, emailVerified, language, whatsappOptIn, termsAcceptedAt, termsVersion, createdAt, updatedAt | Functions | Owner: read; update **only** `language` (`ar`/`en`) |
| `users/{uid}/consents/{id}`: type (terms, privacy, conduct, whatsapp), version, acceptedAt, withdrawnAt, source | Functions | Owner: read |
| `parentIds/{id}`: uid, createdAt | Functions | none |
| `otpCodes/{phoneKey}`, `otpLimits/{key}` | Functions | none |

### App (`lib/`)

| Area | Files |
| --- | --- |
| Logic | `features/auth/`: `phone_number.dart` (Egyptian mobile check, Arabic digits), `account.dart`, `auth_failure.dart` (server reasons to messages), `session.dart` (auth + own record stream), `auth_repository.dart` (interface + Firebase implementation), `install_id.dart`, `legal_documents.dart`, `signup_flow.dart` |
| Router | `router/session_redirect.dart` (pure redirect rules), `router/app_router.dart` (gate via `refreshListenable`) |
| Screens | `features/onboarding/`: welcome, phone, code, email, terms, starting (loading/error/offline), verify account, shared layout; `features/profile/profile_screen.dart` |
| Components (gallery, "Sign-up components") | `AppStepProgress`, `AppCodeField`, `AppCheckRow`, `AppInlineMessage`, `AppCopyValue`, `AppStatusBadge`, `DigitsInputFormatter`; `AppTextField` gained formatters, text direction, prefix, autofocus, submit |
| Strings | 96 new keys, Arabic and English (167 each, same keys, checked by script) |

### Screen states

| Screen | Loading | Empty | Error | Offline |
| --- | --- | --- | --- | --- |
| Welcome | none (nothing loads) | n/a | n/a | handled on the next step |
| Phone | button spinner | blank field, button off | message under the field ("Enter 11 digits starting with 010...") and server errors | warning message "No internet..." |
| Code | button spinner | no number: "Change number" view | wrong (tries left), expired, used up, locked (minutes) | warning message |
| Email | button spinner | blank field | invalid, used by another account | warning message |
| Terms | button spinner | nothing ticked: button off + why | outdated terms, generic | warning message |
| Starting | skeleton ("Setting up your account" for a new account) | n/a | error view with retry | offline view with retry |
| Verify account | skeleton | n/a | via starting screen | via starting screen |
| Profile | skeleton | signed out view | error view with retry | offline view with retry |

## Decisions

1. **Email confirmation with `verifyBeforeUpdateEmail`** (Firebase Auth,
   free). The address is set on the Auth user only after the parent opens
   the link; `confirmEmail` then copies it to the user record. The app
   never writes `email` or `emailVerified`. Needs the Email/Password
   provider on, with sign-up from outside switched off (SETUP.md 11.3).
2. **No new dependency.** Offline is detected from the error (Functions
   `unavailable`, Auth `network-request-failed`, Firestore `unavailable`),
   so `connectivity_plus` was not needed. Clipboard and random IDs use the
   SDK.
3. **Device limit uses a random install ID** (saved with the other
   settings), not a hardware ID. Easy to reset by reinstalling, so the
   number and IP limits plus App Check carry most of the weight.
4. **Client IP = last `X-Forwarded-For` entry** (Cloud Run appends the
   address it sees; a caller can only prepend). Community-confirmed, not
   in Google's docs: check once after the first deploy.
5. **WhatsApp alerts consent is optional and unticked.** Codes always go
   by WhatsApp (the parent asked for one). See open question 2.
6. **Consent versions** are dates (`2026-11-13`) in
   `functions/src/auth/consents.ts` and `lib/features/auth/legal_documents.dart`.
   A newer server version makes old app builds show "update the app".
7. **"Code of conduct" is a consent type** (`conduct`), next to the types in
   spec section 9.
8. **Unknown status counts as unverified** in the app (least access short
   of suspended).
9. **Emulator HMAC key:** with no `OTP_HMAC_KEY` the Functions emulator
   uses a fixed key written in the code (only when `FUNCTIONS_EMULATOR` is
   true; in the cloud a missing key fails closed).
10. **Sign-in functions read `MIN_INSTANCES_SIGNIN`** (default 0, COST MODE),
    separate from the global `MIN_INSTANCES`, so sign-in alone can be warmed
    later.
11. **Phone number stored on the user record** (spec section 9 lists it).
    Only the owner can read it; parent ID lookups (F44) will go through a
    rate-limited function that returns first name and badge only.

## Open questions for the owner

1. **Legal texts.** The terms, privacy policy and code of conduct are short
   drafts in the ARB files, marked "draft" in the app. The lawyer must
   supply the final Arabic and English texts (and say whether WhatsApp
   alerts need a separate consent, Law 151).
2. **WhatsApp alerts by default?** COST MODE says critical alerts go by
   WhatsApp by default; consent law favours opt-in. I made it an optional,
   unticked box. Keep, or tick it by default?
3. **Email language.** Firebase sends the confirmation email in the
   template's language (set in the console). Want it to follow the app
   language? (One line: set the Auth language code before sending.)
4. **Meta business verification** needs the operator entity (spec section
   7, "Operator"). Until then prod cannot send real codes.
5. **Returning after days on the email step**: Firebase may ask for a
   recent sign-in before sending the link; the app then shows a generic
   error and the parent must sign in again. Acceptable for now?

## How to test on your iPhone (the "Done when" check)

Prerequisites: Prompt 1 setup, plus SETUP.md section 11 steps 1 to 4 for
the **dev** project, and the functions deployed (`firebase deploy --only
firestore:rules,functions --project dev`). Or use a Mac with the emulators
(SETUP.md 9B) and read the code in the emulator terminal.

1. Install the dev build (Codemagic "iOS dev to TestFlight (manual)" or
   `flutter run` from a Mac). Open it: the **welcome** screen, in Arabic.
2. Optional: switch to English and back. Tap **ابدأ / Get started**.
3. Type your number, for example `010...` (Arabic digits work too). Tap
   **Send code**. Wrong formats show how to fix them.
4. Find the code: Google Cloud console > Logging > Logs Explorer, search
   `fake WhatsApp` (or the emulator terminal). The number in the log is
   masked.
5. **Wrong code test:** type `000000`. You see "That code is wrong. 4
   tries left."
6. **Expired code test (optional):** wait 5 minutes, type the real code:
   "This code has expired". Wait for the countdown, tap **Send a new
   code**, read the new code.
7. Type the right code. The app moves to **email**.
8. Type your email, tap **Send confirmation link**, open the email on the
   phone and tap the link. Back in the app tap **I have confirmed my
   email** (or just return to the app; it checks by itself).
9. **Terms:** tap **Read** on each, tick the three boxes (WhatsApp is
   optional), tap **Accept and continue**.
10. You land on **Verify your account** with the status "Not verified".
    Home, Carpools, Chats and Notifications send you back here.
11. Tap **Open my profile**: your **parent ID** (8 characters, no 0, O, 1
    or I) with a copy button. Tap it: "Copied". Paste it in Notes.
12. Sign out (bottom of Profile, it asks first) and sign in again with the
    same number: you get the same parent ID and land on "Verify your
    account" directly.
13. In the Firebase console > Firestore: `users/<uid>` has status
    `unverified`, the parent ID, and `consents` with one record per
    accepted document.

Lockout check (optional): 10 wrong codes within an hour lock the number
for an hour ("Sign-in for this number is paused...").

## Tests

| Test | Status |
| --- | --- |
| `functions/test/parent_id.test.ts`: alphabet, format, **10,000 parent IDs with no repeat**, retry on a taken ID, gives up after max tries | **Run here: pass** |
| `functions/test/phone.test.ts`: Egyptian numbers, Arabic digits, masking | **Run here: pass** |
| `functions/test/otp_flow.test.ts`: hash only stored (no code, number, device or IP in clear), right code once, **wrong and expired codes refused**, replacement, tries per code, **lockout**, cooldown, caps per number, device and IP, send failure, suspended | **Run here: pass** |
| `functions/test/whatsapp.test.ts`: fake logs masked number, Meta request body, error without the number, fake refused in prod | **Run here: pass** |
| `functions/test/consents.test.ts`: consent validation, new user record | Written, not run here (imports firebase-admin) |
| `tests/rules/users.test.ts`: owner reads own record only; **cannot change status, parentId, role**, email, emailVerified, phone, terms or WhatsApp fields; may change language to ar/en only; cannot create or delete; consents read-only; parentIds, otpCodes, otpLimits closed to everyone incl. admin claim | Written, not run here |
| `tests/rules/deny_all.test.ts`: updated (`users/alice` moved to users.test.ts) | Written, not run here |
| `test/auth/auth_logic_test.dart`: phone parsing, account, error mapping, install ID, **router gate** | Written, not run here |
| `test/auth/signup_screens_test.dart`: phone validation and offline, wrong and expired code, resend countdown, terms required boxes, **parent ID shown and copied**, sign-out confirmation, verify screen | Written, not run here |
| Prompt 1 tests updated (router, locale switch, screenshots) for the session | Written, not run here |
| Screenshots: welcome, phone, code, email, terms, verify account, unverified profile in AR/EN, light/dark (28 images, CI artifact) | Written, not run here |

## Verified here vs not run

Run here: the 50 Functions unit tests above (Node 22 with type stripping,
on copies of the sources); `tsc` 6.0 strict type-check of all Functions
code against stand-in type stubs for firebase-admin, firebase-functions
and Sentry (no errors in Prompt 2 code); ARB parity (167 keys each);
import ordering of every Dart file. Checked against sources: Meta
authentication template payload (Graph API v25.0 docs), firebase-functions
7.4 (`onCall` options, `defineSecret` value in the emulator), firebase-tools
emulator secret loading (`.secret.local`), FlutterFire 7
(`verifyBeforeUpdateEmail`, `signInWithCustomToken`,
`FirebaseFunctionsException`), Riverpod 3.5 (`AsyncData`, `Override` in
`misc.dart`), Flutter 3.50 re-exports (to avoid `unnecessary_import`).

Not run: `flutter analyze`, `flutter test`, `flutter gen-l10n`, the
screenshot run, `npm test` with real packages, the rules tests on the
emulators, every build. Expect possible small analyzer fixes on the first
CI run.

## Not done / known gaps

- **Parent ID lookup** ("looking up an ID shows only the first name and
  the Verified badge", F44) needs first names, which come with Prompt 3's
  details; planned as a rate-limited function.
- **New-phone login risk** (spec section 7: sign out the old phone, email
  alert, fresh selfie) and **active devices list**: later prompts.
- **Audit log** of lockouts: not written yet (no `auditLog` collection).
- **App Check replay protection** (limited-use tokens on `requestCode`):
  possible later; App Check itself is enforced.
- **WhatsApp alert preferences screen** (switch alerts on/off later) and
  withdrawing consents: privacy screen, later prompt.
- **Name fields** (first and last name) are not asked yet; Prompt 3 adds
  them with the ID check.
- The intermediate commit `F1: sign-up screens...` references the profile
  screen added in the next commit; the branch head compiles as a whole.
