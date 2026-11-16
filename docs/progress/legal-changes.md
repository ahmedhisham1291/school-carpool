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

## Progress

- R1: done.
