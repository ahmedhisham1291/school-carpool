# Legal changes R1-R15 (branch legal-changes), 16 Nov 2026

Task: implement every recommended change R1-R15 of `docs/legal/answers.md`
(owner, 16 Nov 2026, through the coordinator: "yes of course, implement
everything"). The coordinator said "go" on the owner's behalf. One commit
per R item. Not legal advice: the texts stay drafts until the lawyer
approves them (answers.md 5.2).

## Plan

| R | What | Files (main) | Data model |
| --- | --- | --- | --- |
| R1 | Proof of consent kept 3 years after closure | `privacy/retention.ts` (`CONSENT_AFTER_CLOSURE_DAYS`), `privacy/account_deletion.ts` (`CONSENT_TARGETS`, consent phase), `privacy/firestore_store.ts`, jobs, app retention label, delete screen, public pages, record of processing | `closedAccounts/{uid}`: `consentsPurgeAt`, `consentsPurgedAt` |
| R2 | Sign-in log 180 days from each event, survives account deletion; server-only; disclosure only through an audited super-admin callable with a judicial-order reference and a fresh sign-in | new `privacy/signin_log.ts` (pure) + store, `auth/callables.ts` (verifyCode), `privacy/callables.ts` (device sign-out), `config.ts` (secret `SIGNIN_LOG_KEY`), rules, deletion lists, pages, DECISIONS | new collection `signInLog/{id}` (TTL `expiresAt`) |
| R3 | Written sensitive-data consent: separate unticked boxes, typed full name (normalised Arabic) that must match the account name, fresh Face ID/passcode (or a sign-in < 10 min), versioned record with text hash, time, device, app version; a copy the parent opens and downloads from Privacy | `auth/consents.ts`, new `auth/signature.ts` (pure), `verification/submission.ts`, `privacy/requests.ts` (+ `getConsentCopy`), app terms screen, verification consent step, Privacy > Consents copy screen | `users/{uid}/consents/*`: `method`, `textHash`, `nameHash`, `nameMatched`, `deviceKey`, `platform`, `appVersion`; `users/{uid}.signedNames` (the typed names, deleted with the user record; the kept consent record holds only a keyed hash) |
| R4 | Children 15-18: guardian declares the child was told and agrees; age from date of birth or grade | `verification/submission.ts` (`teenAgreement`, `isTeen`), app child step + consent step | children: `birthDate` (optional), `teenAgreedAt`; consent type `teenAgreement` |
| R5 | Prod closed to new real parents until the three PDPC licences are granted | new `launch/` domain (model, admin flow, callables), `auth/otp_flow.ts` (refusal `launch-closed`), admin Settings switch (super admin, re-auth, audit), app "coming soon" | `config/launch.pdpcLicensed` (missing = false; staging/dev always open) |
| R6 | Emergency contact: parent attests the contact agreed; a confirmation link the parent sends; the first alert names the parent, says why and how to stop; "stop" ends alerts | `trips/flow.ts`, `trips/store.ts`, new HTTP function `emergencyContactReply` + hosting rewrite `/ec/**`, app emergency contact screen, WhatsApp template doc | `emergencyContacts/{uid}`: `attestedAt`, `status` (pending/confirmed/stopped), `tokenHash`, `introSent` |
| R7 | Breach register kept 5 years after an incident closes | `privacy/breaches.ts` (`retainUntilMs`), retention constant, runbook, record of processing | `breachRegister/{id}.retainUntil` |
| R8 | Terms/privacy wording: same school or activity; operator legal address; incident and insurance section (122/123, report in app, insurance pool within 15 days, lawful disclosure); log and consent retention lines; document versions | ARB terms/privacy texts, `hosting/links/*.html`, `tool/links_site.py --operator-address`, versions (app + server) | none |
| R9 | Activity carpools (F39): switch `activityCarpools`, off by default (pilot); one venue only, joining approved by every parent, no public offers | `features/model.ts`, `carpools/flow.ts`, app feature switches + create/search screens, admin Settings | `config/features.activityCarpools` |
| R10 | Processor contract checklist; EU regions for Sentry and Algolia | new `docs/legal/processor-checklist.md`, owner actions, record of processing | none |
| R11 | DPIA for live location of children; route archive 1 year -> 90 days | new `docs/legal/dpia-live-location.md`, `ROUTE_ARCHIVE_DAYS`, pages, labels | none (constant) |
| R12 | ID images deleted N days after the decision (keep hash, expiry, result) | `privacy/retention.ts` (`ID_IMAGE_DAYS_AFTER_DECISION`), verification image purge, pages | none (constant) |
| R13 | Annual penetration test (Decree 1699/2020 Art. 2) | owner actions, threat model, COSTS | none |
| R14 | Trademark search and filing after incorporation; pilot school's written no-objection | owner actions | none |
| R15 | Runbook: Public Prosecution / MoI IT-crimes unit; staging with real tester numbers is personal data; 24-hour internal target for children's/biometric breaches (runbook + incidents screen) | `docs/legal/breach-runbook.md`, `privacy/breaches.ts` (`targetAtMs`), admin incidents screen | `breachRegister/{id}.targetAt` |

New screens (layout and states):

- **Consent copy** (Privacy > Consents > a consent > "View copy"): app bar
  with the consent's one-line title; a card with the full text of the
  version accepted, then "Signed by" (the typed name), date and time,
  method (Face ID / passcode, or a recent sign-in), app version, the text
  fingerprint (first 12 characters of the hash); one primary action
  "Download copy" (shares a plain-text file). Loading: skeleton lines;
  empty: "No copy for this consent" (older consents given before R3);
  error: message + Retry; offline: offline view + Retry.
- **Coming soon** (sign-up in prod while `pdpcLicensed` is false): shown on
  the code screen after a right code; title "Opening soon", one sentence,
  primary "OK" back to the phone step. No data is loaded (no loading or
  empty state); the error and offline states are the code screen's.
- **Signature step** (terms screen and verification consent step): the
  boxes stay; a name field ("Type your full name") checked as typed (2+
  words; at verification it must match the ID name), then the primary
  button asks for Face ID / passcode. Errors say how to fix them.

Open questions (none block; recorded for the owner and the lawyer):

1. R6: the file says alerts still go before the contact confirms (safety);
   the coordinator's summary said "opt-in before alerts are sent". Built as
   the file says: alerts go, the first one introduces the parent and says
   how to stop; a contact who taps "stop" gets nothing more.
2. R11/R12 were "consider" items that conflicted with earlier lawyer
   confirmations; built as the shorter, safer periods (owner: implement
   everything). The lawyer should confirm.
3. CLAUDE.md is owner-edited: the lines to change are in the final report.

## Progress (all done, one commit each)

| R | Commit | Notes and owner actions |
| --- | --- | --- |
| R1 | `8a0ac62` | Consents 3 years after closure. |
| R2 | `6620425` | Owner: secret `SIGNIN_LOG_KEY` and the `signInLog` TTL policy in staging and prod (`tool/cloud_setup.sh`, `tool/setup_retention.sh`). |
| R3 | `15c20c0` | Regenerate `functions/src/auth/consent_texts.ts` from the ARB files whenever a signed consent text changes (the test fails otherwise) and raise the version. |
| R4 | `68a44f7` | The app takes 15+ from the age and grade it already asks; the server also accepts an optional date of birth and never stores it. |
| R5 | `03cf773` | Owner: switch "PDPC licences granted" on in prod (Admin > Settings > Launch) only when the three licences are granted. |
| R6 | `4ae2111` | Owner: submit the WhatsApp template `cp_emergency_contact_intro` to Meta (until approved the server falls back to `cp_emergency_contact`); set `LEGAL_SITE_URL` in the app build for "Send the link"; deploy hosting (rewrite `/ec/**`). Built as answers.md 1.8 says: alerts still go before the contact confirms. |
| R7 | `66fd5e4` | No deletion job until the first entry is 5 years old. |
| R8 | `4f0e30a` | Owner: `--operator-address` once the company exists; the lawyer approves the texts. Versions terms/privacy `2026-11-17`: every account accepts again. |
| R9 | `e161407` | Keep `activityCarpools` off in staging and prod until the lawyer's opinion covers F39. |
| R10 | `ae1ced2` | Owner: the checklist per processor; Sentry/Algolia EU regions. |
| R11 | `da57c7d` | Owner: re-apply `tool/storage_lifecycle.json`; tell the lawyer (90 days replaces a lawyer-confirmed 1 year). |
| R12 | `ee7a2c3` | Deploy `firestore.indexes.json` (new composite index) before the daily job finds cases decided before R12; tell the lawyer. |
| R13 | `899e4b2` | Owner: book the tester. |
| R14 | `1e310be` | Owner actions 6 and 7a. |
| R15 | `ee77ebd` | The lawyer confirms the authority to file with (and the hotline number). |

## Tests

| Test | Result |
| --- | --- |
| Functions unit tests (`tsc` + `node --test`, incl. architecture tests; new `signin_log`, `signature`, `launch` test files and additions in privacy, consents, otp_flow, verification_flow, trips, carpools, features, breaches) | **Run here: 960 pass, 0 fail** (927 before). `tsc` prints only the workspace's known type-stub errors (+4 lines of the same stub kinds in the new stores). |
| Python tool tests (`tool/test_*.py`, `tools/import_schools`) | **Run here: pass** (links site: R1, R2, R3, R4, R6, R8, R11, R12 assertions). |
| Rules tests (`tests/rules/admin.test.ts`: `signInLog`, `config/launch`; `trips.test.ts`: emergency contact status/token) | Written, not run here (CI). |
| Flutter widget and unit tests (signature names, terms signing and cancel, verification signing and teen box, consent copy screen, Opening soon, admin launch switch, emergency contact agreement/status, activity search, feature switches, privacy labels) | Written, not run here (no Flutter SDK; CI). |
| Goldens / screenshots of the new screens (consent copy, Opening soon, signing sheet) | Not made here (no Flutter SDK). CI's screenshot job makes them; check Arabic and English, light and dark. |

## How to test on the iPhone (staging)

1. Sign up with a new number: on Terms, tick the four boxes, type your
   full name, tap "Agree and continue": Face ID asks; cancel once (nothing
   is sent), then confirm.
2. Privacy > Your choices > Storage abroad > "View copy": the text, your
   name, date, "Face ID or passcode", "Download copy" opens the file.
3. Get verified: on the review step tick ID, face and guardian boxes, type
   a wrong name (the field says which name to type), then your ID name;
   "Send for review" asks Face ID. Add a child aged 15: a fourth box.
4. Profile > Emergency contact: Save stays off until "This person agreed";
   then "Send the link" opens WhatsApp; open the link on another phone and
   tap "I agree": the status line says confirmed.
5. Prod only (or set `APP_ENV=prod` in a test project): a new number gets
   "Opening soon" after the code; an existing account signs in.
6. Admin panel > Settings: "Launch" and "Activity carpools" switches
   (super admin, fresh sign-in); Incidents: a children's-data incident
   shows "Now, at the latest <time>".

## Not done / open

- CLAUDE.md is owner-edited: the lines to change are in the final report.
- Flutter, rules tests and goldens were not run here.
- The birth date is not asked in the app (age and grade already decide
  15+); the server accepts one if a later form adds it.
- A route under an open safety report is not held past 90 days (only the
  account-deletion safety hold exists).
- Texts stay drafts until the lawyer approves them (answers.md 5.2).
