# App Review audit and fixes (branch apple-review, 16 Nov 2026)

Coordinator said "go". Output: docs/apple-review/audit.md (findings),
docs/apple-review/submission-kit.md (owner). Rules read from Apple's pages
on 16 Nov 2026 (sources at the end of the audit).

## Plan (done)

1. Native: privacy manifests, app icon, iPhone only, no developer settings
   outside dev, prod name guard (`tool/patch_native.py`, `tool/ios/`,
   `packages/run_recovery/ios`).
2. Public legal and support pages on the links site (`hosting/links/`,
   `tool/links_site.py`, `firebase.json` cleanUrls, `tool/cloud_setup.sh`).
3. App: About > Legal and support, no draft note in prod, emergency
   wording, code of conduct (ARB, `lib/features/about/`).
4. CI: Xcode pinned to 26.4, `ios-prod` workflow, `tool/check_ios_app.py`.
5. Server: second demo phone, audited demo sign-ins, demo parents'
   self-ending exemption, `review-demo` seed script, lazy WhatsApp sender.
6. Docs.

## New screen states

About gained one section (three document rows, one contact row). Nothing
loads, so no loading, empty, error or offline state; a document opens in
a sheet with the text (always) and "Open the web page" when the build has
a site; a link that cannot open is copied with a snackbar.

## Data model

- `config/reviewAccess.extra`: up to one more `{phoneKey, codeHash}`.
- `users/{uid}.reviewDemoUntilMs` (number, server only; the app can write
  only `language`): demo parents' exemption, ignored when past or more
  than 30 days ahead. No rules change.
- Fixed demo ids: `review-demo-school`, `review-demo-area`,
  `review-demo-carpool`, `review-demo-child-1/2`.
- Consent version `conduct` is 2026-11-16.

## Tests

- Run here: `python3 -m unittest discover -s tool -p 'test_*.py'` (48 pass);
  Functions `node --test` (856 pass; the workspace has stub typings, so
  `tsc` prints the same typing errors as on main); `bash -n`; `ruby -c`.
- Written, not run here: `test/about/about_legal_test.dart`, the changed
  one-line check in `test/schools/schools_screens_test.dart`; no goldens
  or screenshots produced (About changed: the About golden, if any, needs
  an update in CI).
- Not run anywhere yet: an iOS build with the native changes;
  `scripts/review_demo.ts` against a real project (its plan is unit
  tested; the Firestore writes follow `scripts/seed.ts`).

## Open questions for the owner

1. Notifications as a hard requirement to start a run (guideline 4.5.4):
   keep, or make it a warning? (open item B11)
2. Is the Apple Developer account an Organization? (guideline 5.1.1(ix))
3. Support address and legal name for the public pages.
4. Keep the default icon or supply one? (B12)
5. Data kept one year after account deletion: keep as is and answer if
   Apple asks, or shorten?

## Not done

- UIScene migration (D35), Overture/ADM2 credits (D24, D33), a branded
  launch screen, screenshots (owner, on the prod build), the run video.
- No screenshots of the changed About screen (no Flutter here).

## How to test on the iPhone (after the next staging build)

1. Profile > About: "Legal and support" shows Privacy policy, Terms of
   use, Code of conduct; each opens its text. With `LEGAL_SITE_URL` set in
   Codemagic, "Open the web page" opens the browser; with `SUPPORT_EMAIL`,
   "Contact support" opens Mail.
2. Sign up with a new number: on the terms step tap Read: staging shows
   the "Draft text" note, the prod build does not.
3. Start a run > Emergency: the confirmation says it does not call 122 or
   123.
4. Home screen: the app icon is the teal car, not the Flutter logo; the
   app does not rotate to landscape.
5. Settings > School Carpool Stg: no "Local Network" entry.
6. Demo accounts on staging: docs/apple-review/submission-kit.md section B
   with the staging project id; sign in on a second phone with the demo
   driver number: no selfie check, the demo run starts.

## Validator review (16 Nov 2026)

docs/reviews/apple-review.md. Fixed there: demo accounts confined by the
server and closed outside the window (B1), the selfie skip bound to the
two listed accounts and the open access (B2), email provider and Vertex
AI named on the privacy page (B3), a build machine without the xcodeproj
gem now fails (B4). Data model: `users/{uid}.reviewDemo` (permanent
mark, server only), `config/reviewAccess.demoUids` (at most two).
