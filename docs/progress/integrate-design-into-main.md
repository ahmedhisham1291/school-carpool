# Integration: design-refresh-01 into main (Prompt 1 + Prompt 2)

Branch `integrate-design-into-main`. Written, not run here (no Flutter SDK
in the build workspace): CI runs `flutter analyze` and `flutter test`.

## Merge

- `components.dart`: exports from both sides.
- `placeholder_tab_screen.dart`: main's version (Profile has its own screen
  since Prompt 2) with `AppBarTitle`.
- ARB files: keys from both sides; the design branch's shorter wording for
  the keys it changed (Alerts, Auto, No connection, ...). AR/EN parity
  checked by script.
- `screenshots_test.dart`: `loadAppFonts`, sign-up screens and the 320 dp
  shell shots both kept; gallery canvas 7400 high (sign-up section + chips
  + navigation).

## Prompt 2 brought in line with docs/DESIGN.md

- App bar titles use `AppBarTitle` (verify account, profile).
- Sign-up step titles: one line, `headlineSmall`, scale down at large text
  (`OnboardingLayout`). The welcome hero stays a short sentence that may
  take two lines (the only page hero).
- One-line labels: step progress, status badge, code field label, parent
  ID label, check-row "Read" link, language segments.
- Snackbars use `showAppSnackBarOn` (code resent, link sent, copied, sign
  out failed). Sign-out failure now says "Couldn't sign out" (new key
  `signOutFailed`) instead of a long error sentence.
- Icon sizes from `AppIconSize` (welcome tile, badge, banner chevron).
- Shorter button wording (DESIGN: two or three words): "Send new code",
  "I confirmed it", "Resend link" (AR: أعد إرسال الرابط).
- Verify-account steps: short one-line titles with the detail as subtitle
  (four new `...Detail` keys), so nothing is cut at 320 dp.
- Profile status: shown as the row subtitle with the status icon, not a
  trailing badge (the badge left the title about 65 dp at 320 dp, and
  overflowed at 200 percent text). Title shortened to "Status" / "الحالة".

## Tests

- `one_line_test.dart`: the Profile tab test now signs in a fake verified
  parent (router gate since Prompt 2). New: every sign-up screen and
  Profile through the real router at 320 dp, normal and 200 percent text;
  sign-up buttons, titles, labels, rows and badges in every state; sign-up
  buttons, app bar title and the sign-out dialog title at 200 percent;
  Prompt 2 snackbars.
- Screenshots: each sign-up screen now gets the session the router lets
  onto it (before, a signed-in session redirected every sign-up screen to
  verify-account); 320 dp shots at normal and 200 percent text added.

## Open points

- Thresholds in the new tests (not shrunk below 0.9 at normal text, 0.5 at
  200 percent) are estimates from font metrics; adjust wording, not the
  threshold, if CI shows a real overflow.
- Regenerate all screenshots after this merge (visual changes listed in
  docs/reviews/design-refresh-01-review.md).

## Second merge: main with Prompt 3 (ID verification)

- Conflicts: verify-account (Prompt 3 status branches + short step titles),
  ARB (per-key three-way merge, parity checked), screenshots (both
  parameters; verification screens also at 320 dp, normal and 200%).
- Design pass on Prompt 3: `AppBarTitle` on the steps, capture, child
  form, children and driving screens; one-line step titles
  (`headlineSmall`, scale down); `OneLineText` labels in `AppDateField`,
  `AppSelectField` (label and options) and `AppCaptureTile`; car title and
  the reason / reviewer-note labels one line; `showAppSnackBarOn` for every
  snackbar (new short `verifyWithdrawFailed`); `AppIconSize`/`AppRadii`
  tokens in the capture tile.
- Pending "what happens next" rows: short titles (Review, Result, Your
  photos) with the sentence as subtitle (three new keys).
- Children list: review status leads the subtitle, status icon as the
  leading icon (no trailing badge; the badge left about 40 dp for the name
  at 320 dp).
- Wording: EN `idNumberLabel` "National ID" (review row was ~5 dp from
  cut at 320 dp), EN `captureTodo` "Not taken". The two checkbox labels
  were already short ("I will drive", "I agree to the ID check").
- Tests: verification screens (pending, rejected, children, driving) in
  the real-router 320 dp test at normal and 200% text; a walk through all
  six verification steps with a complete draft at both sizes; date,
  select and capture-tile labels and Prompt 3 buttons in a content test.
- Not changed: the camera shutter icon (40, off the AppIconSize steps; the
  camera screen cannot be rendered in tests); children rows inside the
  steps sit in a padded list, so they get the gutter twice (48 dp).

## Follow-ups (design-followups-01, review of the integration)

- Sign-out and withdraw errors say why again, in one short line: "No
  connection. Try again." (new `errorOfflineShort`) when offline, else
  "Couldn't sign out" / "Couldn't withdraw".
- 200 percent tests: button labels may shrink at most 25 percent (0.75,
  as in the design test). Wording shortened to fit: EN "Send link",
  "Accept all", "Get verified", "Verify account"; AR "سجّل الدخول مجددًا".
- Step subtitles read on their own: "A photo of their school ID card" /
  "صورة بطاقة المدرسة", "Only if you drive, with car details" / "فقط إذا
  كنت ستقود، مع بيانات السيارة".
- Camera shutter icon on the icon-size scale (`AppIconSize.lg`).
- `AppListRow(inset: false)` for rows inside a padded list; the children
  rows in the verification steps use it (no double gutter).
