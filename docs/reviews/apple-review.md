# Review: branch apple-review (validator, 16 Nov 2026)

Base main 47e102d, reviewed head db3d520 (8 commits), plus the validator
commits on top of it.

**Verdict: PASS after fixes.** Four blockers found, all fixed here (B1 to
B4). The reviewer sign-in itself was sound; the demo ACCOUNTS behind it
were not confined. No iOS build has run yet: the native scripts were read
line by line, not executed (N1).

What was run: Functions unit tests (870 pass, with this workspace's stub
typings; `tsc` reports the same 165 typing errors before and after, none
new), `python3 -m unittest discover -s tool` (48 pass), `bash -n`, YAML
parse. Written, not run here: the new rules tests in
`tests/rules/users.test.ts` (emulator; run by CI). CI run: see the end.

## Blockers (fixed)

**B1. Demo accounts were a way around the ID check.** The seed makes two
parents "verified" (custom claim and status) with no ID check, and their
sign-in code is known outside the team (App Store Connect, Apple's
reviewers). Nothing on the server told them apart from real parents, so
whoever held the code could: add any real school as a "driving school"
(`setDrivingSchools`) and then list real parents near it
(`searchNearbyParents`: first names and rounded homes), search that
school's carpools, send chat requests to its parents, ask to join real
activity carpools (no school check there), link as a guardian, move the
account to another phone number, and it stayed "verified" for ever, also
after the window and after `review-demo -- remove`.
Fix (`functions/src/privacy/device_gate.ts`, `auth/review_access.ts`):
- A permanent server-only mark `users/{uid}.reviewDemo` (never removed).
- Inside the window a demo parent is refused (`demo-account`) by:
  `setDrivingSchools`, `requestToJoinCarpool`, `openCarpoolInvite`,
  `saveCarpoolWanted`, `submitVerification`, `addOtherSchool`,
  `requestGuardianLink`, `answerGuardianRequest`, `requestPhoneChange`,
  `confirmPhoneChange`, every wallet callable, and `createCarpool` /
  `searchCarpools` for anything but kind "school" (school carpools are
  tied by the flows to the caller's own approved children's school, which
  is the hidden demo school).
- What stays open is scoped by the existing flows to the demo school and
  carpool: nearby map and carpool search need a shared school, chat
  requests a shared school or carpool, Settle up two approved members of
  one carpool, trips and schedule the caller's own carpool.
- Outside the window (access off or expired, or account not listed)
  every gated callable refuses a demo account (`demo-closed`), except
  `deleteMyAccount`.
- `review-demo -- remove` now also sets the accounts back to
  "unverified", clears the claim, revokes tokens and signs them out.
- The other direction: a real parent can no longer pick the demo school
  as a driving school (`invalid-school`), so real and demo parents share
  no school.
Tests: `functions/test/review_demo.test.ts` (state function and wiring of
each callable), `tests/rules/users.test.ts`.

**B2. The selfie and face-reference skip was not bound to the two
accounts or to the window.** It depended only on a date field on the
user record: any account carrying that field was exempt, and
`review-access -- off` did not end it (it ran on to its own date, up to
30 days). Fix: `reviewDemoState` requires the mark or date on the
account AND the review access switched on and unexpired AND the account
ID in `config/reviewAccess.demoUids` (at most two, written by the seed;
`config/` is closed to the app). Both stores
(`privacy/firestore_store.ts`, `trips/store.ts`) use it; real parents
cost no extra read. `off`, expiry or `remove` end the skip at once.
Running `review-access -- on` again starts with no listed account: the
seed must be run again (the script and the kit say so).

**B3. Public privacy page left out two recipients.** The page did not
name the email delivery provider (the parent's email address goes to it
for the new-phone alert) and said nothing about the AI model on Vertex AI
that checks public school names. Added to `hosting/links/privacy.html`
(Arabic and English) and to docs/app-store-privacy.md section 3: the
email provider, and Vertex AI with "nothing about you or your children is
sent to it" (true: `tools/import_schools/ai_review.py` reads only the
import's school list; names typed under "Other" go to admins). The
delete-account page now lists Settle up records among what is kept one
year (as the policy and the retention table already say).

**B4. A build machine without the `xcodeproj` gem produced a broken app
without failing.** `tool/bootstrap.sh` only printed a warning, so the
first Codemagic build could upload an app with no entitlements file set
(no push, no App Attest: every App Check call fails) and no privacy
manifest. Now on a build machine (CI or CM_BUILD_ID set) it installs the
gem and stops the build if it is still missing. On the owner's Mac the
warning with the manual steps stays.

## Checked, no change needed

1. **Reviewer sign-in (otp_flow.ts).** Exact allow-listed phone keys only
   (HMAC of the E.164 number; at most two); the code is stored and
   compared as a keyed hash bound to that phone key, with
   `timingSafeEqual`; needs `enabled`, an expiry in the future and at
   most 30 days ahead, and well-formed hashes, else it is off; a failed
   settings read falls back to a normal WhatsApp code; every limit and
   lock applies (5 tries per code, 5 codes an hour, lock after 10
   failures, 30 wrong codes a day per number: at most about 900 guesses
   in 30 days against 1,000,000 codes, and only for someone who knows the
   demo number); each sign-in is in the audit log with no number or code;
   off by default (no document in any environment, no seed or setup
   script writes it); scripts read number and code from the environment
   and print neither; weak codes refused. Phone change uses its own key,
   so the review code never works there.
2. **Privacy manifests.** No tracking, no tracking domains. Reason codes
   CA92.1, C617.1, 35F9.1 and E174.1 are the standard codes of their four
   categories. Apple's article was opened; it now keeps the code tables
   on the pages of the two manifest keys, which this workspace could not
   open, so the codes rest on the known list and a second source for
   CA92.1 and E174.1. Collected data types match docs/app-store-privacy.md
   section 2 (a test compares them). The plugin manifest ships through
   `resource_bundles`.
3. **Xcode 26.4.** Codemagic's image page lists Xcode 26.4.1 (17E202) on
   macOS 26.4.1, selected by `xcode: 26.4` (and currently by `latest`);
   CocoaPods 1.16.2, Ruby 4.0.2. Apple's requirements page: uploads must
   be built with Xcode 26 or later since 28 Apr 2026. Flutter's UIScene
   page confirms an app without the UIScene life cycle fails to launch
   when built with Xcode 27, and that Flutter 3.41+ migrates only an
   unmodified AppDelegate; ours is replaced by `patch_native.py` (classic
   delegate, scene manifest removed), so the pin is right and the D35
   migration stays open. `codemagic.yaml` parses; keys are valid.
4. **Workflows.** `ios-prod` is manual, stops on the placeholder Apple ID,
   placeholder Firebase options, missing legal URL, support address or
   Maps key, and an unreachable privacy page; never submits. `ios-staging`
   is unchanged except the pin and the report-only app check.
   `patch_native.py`, `configure_xcode.rb` and the icon and manifest
   steps read correctly (paths relative to the Runner group, idempotent,
   single-size icon set, iPhone-only regex covered by tests).
5. **Public pages.** Retention matches `functions/src/privacy/retention.ts`
   (photos, run summaries, routes, consents, chat: 1 year after closure;
   live points 24 hours). Third parties: Google/Firebase, Maps, WhatsApp
   (Meta), Stream, Algolia, Sentry, Valify. Example addresses are refused
   by the builder. The Arabic reads naturally and says the same as the
   English.
6. **Audit honesty.** 14 PASS rows checked against the code (developer
   route, wallet row, fake providers in prod incl. the wallet, background
   modes, location indicator, Sentry settings, delete-account entry, App
   Attest provider, prod options placeholder, Stream block lists, the
   notifications gate, no "beta" strings, placeholder screen unused,
   export compliance): all true. One row was wrong in substance: "ends
   with the review window" (see B2); corrected in the audit.

## Notes (not blocking)

- **N1. No iOS build has run.** Unverifiable here: whether Flutter
  3.50's iOS template still uses classic Xcode groups (if the Runner
  folder became a synchronized folder group, `configure_xcode.rb` would
  add `PrivacyInfo.xcprivacy` twice and the build would stop with
  "Multiple commands produce"), and whether `ruby` on the Codemagic image
  can load `xcodeproj` (B4 now makes that a clear failure). The first
  staging build is the test; read its log from the "Bootstrap" step.
- **N2. The app shows its generic error** when a demo parent taps
  something confined (add a child, driving schools, join by invite). The
  review notes now tell the reviewer the demo account is limited. A
  friendlier message needs a Dart change, not made here.
- **N3. If the reviewer deletes the demo account** the number signs in
  as a new unverified parent until `seed` runs again (in the kit).
- **N4. Notifications required to start a run** (guideline 4.5.4) is
  still the audit's main open RISK and an owner decision.
- **N5. A real parent's child at the demo school** would need an admin
  to approve it; admins should reject anything naming the demo school.
- **N6. Demo sign-in guessing** is bounded as in point 1; keep the demo
  numbers private (they are not in the repository) and prefer a window
  shorter than 30 days.
