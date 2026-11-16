# Review: branch legal-egypt (validator, 16 Nov 2026)

Scope: commits 9850100..0371af0 on top of main f64541c (money off,
consents and requests, public pages, breach register, legal memo), plus
the validator's fixes. Read first: CLAUDE.md, docs/legal/egypt-legal-review.md,
docs/legal/breach-runbook.md, docs/legal/owner-actions.md, docs/DECISIONS.md.

**Verdict: PASS after fixes** (one blocker fixed on the branch; CI result
in the last section).

## Blockers

| # | Finding | Fix |
| --- | --- | --- |
| B1 | **Existing accounts were never asked for the new documents.** The app treated `termsAcceptedAt != null` as done and never compared versions, so staging parents who accepted the 2026-11-13 terms never saw the new required `transferAbroad` consent or the 2026-11-16 terms (the memo itself listed this as not done). Nobody was locked out, but the separate transfer consent was missing for every existing account. | `Account.termsVersion` + `RegistrationStage.termsUpdate`: a stored version older than `LegalDocuments.terms` sends the parent once to the terms screen (no step progress, a line saying what changed, a "Privacy" button). `termsUpdateOpen` keeps `/profile/privacy` and its sub-pages (export, withdraw, delete account) open meanwhile; everything else waits. A null version (dev seed) is not asked. `acceptConsents` already records again when the stored version differs. Tests: `test/auth/auth_logic_test.dart`, `test/auth/signup_screens_test.dart` (written, run in CI). The demo seed (`functions/scripts/review_demo_lib.ts`) already wrote the current `termsVersion`, so the Apple demo accounts are not asked; it now also writes the consent records (current versions, fixed IDs) so their Privacy screen shows the consents as given. |

## Checks

1. **Consents / lock-out (after B1): PASS.** Versions match on both sides
   (`CONSENT_VERSIONS` / `LegalDocuments`, `VERIFICATION_CONSENT_VERSIONS`
   / `verificationConsent`). The terms screen has empty (button off + hint),
   loading (button spinner), error and offline (`FailureMessage`) states;
   it makes no read of its own, so no skeleton is needed. AR/EN strings
   present (ARB parity 2407/2407), RTL by the layout, the new check-row
   labels are short ("أوافق على التخزين خارج مصر" / "I agree to storage
   abroad"). The guardian declaration and the biometric wording are asked
   at the next ID submission or child added, not retroactively (memo
   section 13; lawyer question 1.4).
2. **Money off: PASS.** `PILOT_DEFAULTS` and `FeatureSwitches.pilot` all
   off; wallet and Settle up callables gated; `createCarpool` refuses a
   contribution (`feature-off`), `requestToJoin` neither asks for nor
   records an old one, searches strip it; the detail screen and cards show
   "Free, by turns" instead; old carpool documents with a contribution still
   parse. Volunteer box required on create and join and stored as
   `volunteerTerms` on the membership; demo seed sets it. Public pages
   tested for no InstaPay / Settle up / wallet wording.
3. **Breach register: PASS.** `requireAdminCaller` (admin claim, TOTP second
   factor required everywhere but the emulators, admin record not
   disabled/revoked); every write is one batch with an audit entry (no free
   text in the audit details). Rules: explicit deny for every client,
   admins included, with a rules test. Deadlines: 72 h from "aware at"
   (immediately for national security or children's/biometric data);
   parents 3 working days after the PDPC notice, Sun-Thu in
   `Africa/Cairo`, Fri/Sat skipped, holidays counted (earlier deadline,
   safe side), same clock time. Verified by hand in Node with the Cairo
   time zone and added tests: Thursday and Friday notices, a Thursday
   23:30 notice (UTC still Thursday, Cairo Friday next), and the April DST
   change (Egypt switches on the Thursday/Friday boundary, so only a
   weekend day can be skipped or doubled).
4. **Sign-in history: PASS.** 180 days (`LOGIN_HISTORY_DAYS`) and deleted
   with the account (`account_deletion.ts` step `users/logins`); the
   conflict with Law 175 Art. 2 is flagged (DECISIONS legal flag 4, memo
   question 4.2). The privacy page now says "deleted with the account if
   you delete it sooner" in both languages.
5. **Public pages: PASS.** `tool/test_links_site.py` and all `tool/` tests
   run here: 67 pass. Placeholder addresses (example.com, .test, .invalid,
   localhost) are refused for support and DPO; no example address in the
   page sources. The Arabic is clear, formal and consistent with the
   English (Arabic-prevails clause, liability clause, transfer section,
   72 h / 3 working days).
6. **Legal memo citations: PASS with one correction** (memo section 14):
   Decree 816/2025 dates and authority, 72 h / 3 working days, Law 87/2018
   Arts. 2, 10, 15, 16, Law 175/2018 Arts. 2, 33, 35 confirmed. Law
   155/2024: the amounts are in Art. 47 (not "Arts. 40, 47"), the Board may
   raise them by 50%, and recourse (Art. 56) is by the compulsory-insurance
   pool; corrected in English and Arabic. Added CMS's caveat that the PDPC
   might count the grace period to end-2026.

## Notes (not blocking)

- N1: Old app builds break on deploy: sign-up without `transferAbroad`
  gets `missing-consent`, create/join without `acceptVolunteer` gets
  `must-accept`. Pre-launch only; deploy functions and app together (as
  the consents comment already says).
- N2: Re-asking is keyed on the terms version only. A future change to
  only the privacy policy (or a new required consent) must also raise
  `terms`, or the gate must compare every required version (recorded in
  open item B2).
- N3: The public privacy page and the in-app transfer text say transfers
  follow "the licence (or permit) of the PDPC", which does not exist yet.
  Fine for staging; before prod the owner files the licence (owner
  actions) or the wording becomes "once granted".
- N4: Incident times in the admin panel are shown in the browser's time
  zone; the deadlines themselves are computed in Cairo on the server.
- N5: The progress note said "no rules change"; corrected (breachRegister
  match + test).
- N6: Flutter widget/golden tests and `flutter analyze` are not run here
  (no SDK); they run in the full CI run below. Functions tests run in CI.

## Merge with main (architecture, 93b6b61)

Merged origin/main. `privacy/breach_callables.ts` now uses
`common/callable.ts` `runCallable` with `reasonErrorMapper` for
`BreachError` and `AdminError` (no own try/catch); the carpool callables'
`feature-off` mapping (contributions switch) moved into the shared wrapper.
Consents and privacy-request callables were already converted on main.
The breach register uses the `BREACH_REGISTER` constant; no new
collection-name literals (Functions or Dart). Architecture tests green.

Fixes found by the full CI run (before the merge the branch's Flutter
job had never passed): `flutter analyze` (directive order in two admin
files, the `Override` import in the incidents test, const literals) and
three admin Settings tests plus the feature-off one-line test that still
expected Settle up on by default.

## CI

Full run (`full=true`) on head c7e3638: **green**, run 43888380839
(Cloud Functions + rules tests, Flutter analyze/tests/screenshots, web,
admin panel and Android compile).
