# Review: integrate-design-into-main

Branch `integrate-design-into-main`, head `89eeb73`. Reviewed
`git diff origin/main...HEAD`, focusing on the adaptation commits
`03c9c16`, `dc608ee` (Prompt 2) and `3e07988`, `89eeb73` (Prompt 3), and
the merges `9c81857` and `ac308be`. Checked against CLAUDE.md DESIGN,
docs/DESIGN.md and the merge notes in
docs/reviews/design-refresh-01-review.md.

## Verdict: PASS

## CI

Run 43447083949 on `89eeb73`: **success**, all three jobs.
- Flutter analyze, tests and screenshots: success. `flutter analyze`: "No
  issues found!"; `flutter test`: "+168 ~116: All tests passed!" (the
  skips are the screenshot tests, which then ran with `--update-goldens`:
  "+116: All tests passed!"). No `one_line_test.dart` test was skipped.
- Cloud Functions tests and rules tests (emulators): success.
- Web and Android compile (staging): success.

## What was checked

- **Security and privacy untouched.** `git diff origin/main HEAD` is empty
  for `functions/`, `firestore.rules`, `storage.rules`, `tests/` (rules),
  `lib/router/`, `lib/features/auth/`, `pubspec.yaml` and the verification
  repository, draft, national ID and screen-security files. No new
  dependency. `SecureScreen` still wraps the child form.
- **Behavior.** The adaptation commits change presentation only:
  `AppBarTitle` for app bar titles, `OneLineText` in labels, badges, step
  progress, field labels and select options, `showAppSnackBarOn` for
  snackbars, `AppIconSize`/`AppRadii.control` tokens, step titles in
  `headlineSmall` with `scaleDown`. Navigation, providers, callables,
  validation and the router gate are unchanged. Two feedback texts changed
  (see Non-blocking 1). Profile and the children list now show the status
  as subtitle text with the status icon instead of a trailing badge; the
  status is still given in words, so color is not the only signal.
- **Merge notes followed.** `AppDateField`/`AppSelectField` use
  `label: OneLineText(label)`; capture tile, date and select labels are in
  the one-line test; router test expects `AppNavigationBarItem` and
  "Alerts"; screenshots use `loadAppFonts`; Prompt 3 app bars use
  `AppBarTitle`.
- **ARB parity.** Same key set in `app_ar.arb` and `app_en.arb`; the only
  placeholder differences are the Arabic plural forms
  (`childAgeYears`, `errorWrongCode`, `driverSeatsCount`, ...), which are
  correct and pre-existing. New keys (`verifyStep*Detail`,
  `verifyPendingNext*Title`, `signOutFailed`, `verifyWithdrawFailed`) exist
  in both languages with descriptions.
- **Wording.** Short and clear in both languages: "Send new code",
  "Resend link" / "أعد إرسال الرابط", "National ID" / "البطاقة الشخصية",
  "Status" / "الحالة", "Review / Result / Your photos" with the full
  sentence kept as subtitle. No information was dropped: each shortened
  verify-account step moved its detail to the subtitle.
- **Tests.** The only edited assertions are equivalent:
  `'Your national ID, front and back'` became `'National ID'` plus
  `'Front and back'`; `find.text('Approved')` became
  `find.textContaining('Approved · ')` because the status moved into the
  subtitle. The one-line tests add real-router 320 dp runs of every
  sign-up and verification screen and Profile at normal and 200 percent
  text, a walk through all six verification steps, and content tests of
  the new labels. The helpers fail on wrap, on ellipsis and on shrinking.

## Blocking

None.

## Non-blocking

1. **Two error snackbars lost their reason.** Sign-out failure used to
   show `failure.message(l10n)` and now always says "Couldn't sign out";
   withdraw failure used to show the `VerificationFailure` message
   (offline, suspended, ...) and now always says "Couldn't withdraw" /
   "تعذّر سحب الطلب". This is short, but it no longer tells the parent how
   to fix it (CLAUDE.md: "say how to fix an error"). Suggest a short
   offline variant ("No connection. Try again.") when
   `failure.isOffline`, keeping the generic text otherwise.
2. **200 percent shrink threshold is looser in the new tests.** The
   approved design-refresh test allows buttons to shrink at most 25
   percent at x2 (`0.75`, still present). The new per-screen and sign-up
   x2 tests allow `0.5`, which means a button label at 200 percent text
   may be drawn at normal size, cancelling the parent's text-size
   setting. The progress note calls it an estimate. Once CI screenshots
   at x2 are reviewed, tighten it to 0.75 where the screens allow, and
   shorten wording where they do not.
3. **Detail subtitles that begin with "And".** "And their school ID card"
   / "وصورة كارنيه المدرسة" and "And car details, if you will drive" /
   "وبيانات السيارة إذا كنت ستقود" read as continuations of the title. A
   screen reader reads the title and subtitle together, so it works, but
   "School ID card" and "Car details, if you drive" read better alone.
4. **EN `emailConfirmed` "I confirmed it"** is clear on the check-inbox
   screen, but the Arabic still says "أكدت بريدي" ("I confirmed my email").
   Fine, just not a literal match. Optional.
5. Regenerate and look at the screenshots artifact of this run (320 dp,
   x1 and x2, AR and EN) before the next prompt. `screenGutter` 24 plus the
   padded children list inside the steps gives 48 dp side margins, which
   the progress note already mentions.
