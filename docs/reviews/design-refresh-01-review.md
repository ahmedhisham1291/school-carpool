# Review: design-refresh-01

Branch `design-refresh-01`, head `778367f`, reviewed against `main`
(`git diff main...HEAD`, 35 files, +1425 / -300). Reviewer: validator
agent, read-only.

## Verdict: CHANGES NEEDED (small)

The refresh does what the owner asked where it matters most: the bottom
tab bar can no longer wrap ("Notifications" is now "Alerts" /
"التنبيهات", and `AppNavigationBar` clamps, scales down and never wraps),
the palette and theme are calmer and more consistent, and CI is fully
green with the new one-line tests really running. Two gaps remain in the
one-line rule itself: app bar titles and segmented-button labels are not
enforced by any shared component, and every feature screen will use both.
Fix those two (about 30 lines) and this is a PASS.

## CI

Run 43434899291 for head `778367f`: **success**.

| Job | Result |
| --- | --- |
| Flutter analyze, tests and screenshots | success. `flutter analyze`: "No issues found!". `flutter test`: "+51 ~20: All tests passed!" (the 20 skipped are the screenshot tests, which then ran with `--update-goldens`: "+20: All tests passed!", 20 PNGs uploaded as artifact 14042252827) |
| Cloud Functions tests and rules tests (emulators) | success |
| Web and Android compile (staging) | success |

All 10 one-line tests ran and passed (not skipped): `[ar]`/`[en]` bottom
tabs at text x1.0 and x2.0, buttons/chips/rows/titles, snackbars, Profile
tab. The reviewer could not open the screenshot artifact (blob storage
host blocked by this workspace's proxy), so the visual judgement below is
from code, tokens and contrast math, not from the PNGs. The owner should
look at `shell_home_a_*_320_text2x.png` and `gallery_a_*_dark.png`.

## Blocking

1. **App bar titles are not one-line by construction.** There is no
   shared top-bar component. `lib/features/placeholder/placeholder_tab_screen.dart:36`
   still uses `AppBar(title: Semantics(header: true, child: Text(title)))`;
   only the gallery uses `OneLineText`. Every future screen will copy the
   placeholder. Add a small `AppTopBar` (or `AppBarTitle`) in
   `lib/design/components/` that wraps the title in `OneLineText` with the
   header semantics, use it in the placeholder and gallery, and add it to
   the gallery and the one-line test.
2. **Segmented-button labels and the settings field label are plain
   `Text`.** `lib/features/settings/settings_section.dart:37-53,82,112-116`
   (`ButtonSegment(label: Text(...))`, `Text(label, style: labelLarge)`).
   They pass at 320 dp only because the wording was shortened ("Auto",
   "A: Teal"); nothing stops the next string from wrapping. Either add an
   `AppSegmentedButton` that builds segments with `OneLineText`, or at
   least use `OneLineText` in these segments and the field label. The
   one-line test already covers this screen at x1; that stays.

## Non-blocking

1. **200 percent text vs ellipsis (open question 2).** Clamping is only
   in the nav bar (`MediaQuery.withClampedTextScaling`, the only clamp in
   `lib/`), so body text still scales to 200 percent: good. But at 200
   percent `OneLineText` will cut button, dialog-title and list-title
   text with an ellipsis, which hides content (WCAG 1.4.4). No test
   renders buttons or titles at x2. Recommendation for the owner's
   answer: allow two lines in `AppButton` and `showConfirmDialog` titles
   only when `textScaler.scale(1) > 1.3`, and add an x2 run of the
   "buttons, chips, rows and titles" test that asserts no ellipsis.
2. **Settings snackbars** still call `SnackBar(content: Text(...))`
   directly (`settings_section.dart:150-159`); acknowledged in the
   progress note. Switch to `showAppSnackBar` with blocking item 2.
3. **DESIGN.md claims "3:1 for borders and the selected pill"** but the
   pill itself is 1.21:1 against the bar (light) and 1.46:1 (dark). That
   is acceptable because selection is also shown by the filled icon and
   the semibold label, but the doc and the test name
   (`primary/primaryContainer`) should say so instead of claiming 3:1.
4. **Dark theme separation is very faint.** Raised `#171E1D` on surface
   `#111716` is 1.07:1 and the hairline `#283130` is 1.27:1 on raised.
   Calm, but cards may disappear on OLED at low brightness. Consider
   `outlineVariant` around `#323C3A` in dark.
5. **Small token leaks.** `0.12` / `0.08` overlay alphas in
   `app_theme.dart:52-55`; icon sizes built from spacing (`s16 + s4` in
   `AppChip` and the list-row chevron); `_bodyMaxWidth = s64 * 5` in
   `state_views.dart`. Add `AppOpacity` (pressed, hover) and `AppIconSize`
   (sm 20, md 24) tokens. `buttonHeight = 52` sits off the 8-point grid;
   fine as a documented exception.
6. **Nav label at 12 px** (was 13). Within the rule (labels, not body),
   and it clamps to 15.6 at large text, but iOS users at accessibility
   sizes lose the label size they asked for. The screen-reader label is
   already set; consider a long-press tooltip that shows the label large
   (like the iOS large content viewer), and 13 px if "Carpools" and the
   Arabic labels still fit at 0.95 shrink.
7. **Checked and fine:** RTL (`EdgeInsetsDirectional`, nav `Row` mirrors,
   `chevron_right_rounded` matches text direction); reduce motion (nav
   pill uses `AppMotion.resolve`, theme drops button animation and page
   transitions, skeleton pulse stops); contrast of every text pair in the
   test is AA in both themes and both directions (spot-checked: light
   onSurfaceVariant on raised 6.79, primary on raised 7.61, outline on
   raised 3.72; dark 7.77 / 9.37 / 3.76); no `Color(0x..)` or literal
   sizes outside `lib/design/tokens/` except the gallery hex labels; the
   one-line test is meaningful (real fonts, wrap check by line boxes,
   `didExceedMaxLines`, shrink ratio at most 5 percent at x1 and 25
   percent at x2, and asserts the clamp is inside the bar).

## Elegance (frontend-design guidance), suggestions

1. **The page color sits close to the generic "warm cream" default**
   (`#F7F6F3`). With a teal accent and a sans face it does not read as
   the cliché, but a slightly cooler, teal-leaning paper (around
   `#F4F7F6`) would tie the neutrals to the brand instead of to a trend.
2. **Spend the boldness in one place.** Everything is now quiet; pick
   the one memorable element (suggestion: the "today's run" card on Home,
   with the driver's name set in `headlineSmall` and the time large) and
   give it `AppElevation.medium` and the accent. Keep the rest hairline.
3. **Use type, not boxes, for hierarchy.** The state views now use a
   rounded tile behind every icon, list rows use a tile too. Try dropping
   the tile in state views and letting a larger, lighter icon plus the
   18/28 title carry it; fewer containers reads more refined.
4. **Section headers:** quiet `onSurfaceVariant` at 16/500 is right; add
   the 24 dp gutter hairline above only when a section follows a list, so
   structure carries information rather than decoration.
5. **Copy:** good direction ("Couldn't load. Try again."). Keep the
   action name stable across a flow, as DESIGN.md says; "Server error
   sent" for a test tool is fine, but user-facing copy should name what
   the parent did ("Request sent", "Swap requested").

## Merge notes for the coordinator

- `prompt-02-whatsapp-signup` is already in `main`; no extra work.
- `prompt-03-identity-verification` / `prompt-04-admin-panel` (03 is in
  04). `git merge-tree` against 04 shows **4 conflicts**:
  `lib/design/components/components.dart` (both add exports: keep both
  sets, sorted), `lib/l10n/app_ar.arb` and `app_en.arb` (both append keys
  at the end: keep both; take this branch's values for changed keys),
  `test/screenshots/screenshots_test.dart` (04 still has its own
  `_loadFonts`; switch to `loadAppFonts` from `test/helpers/fonts.dart`
  and keep 04's new screens).
- `test/router/router_test.dart` auto-merges, but 04's version still
  expects `NavigationDestination` and the label 'Notifications'. After
  the merge it must find `AppNavigationBarItem` and 'Alerts'. Any test
  that finds `NavigationBar`/`NavigationDestination` or taps the text
  'Notifications' must change.
- `AppSpacing.screenGutter` is now 24 (was 16). 03/04 use it in
  `onboarding_layout.dart` and `profile_screen.dart`; layouts get 16 dp
  narrower at 320 dp. Re-run the one-line test and look at those
  screenshots.
- New components in 03/04 (`date_field.dart:67`, `select_field.dart:31`)
  use `labelText: label`; change to `label: OneLineText(label)` to match
  `AppTextField`, and add `capture_tile`, `date_field`, `select_field`
  labels to `test/design/one_line_test.dart`.
- Changed strings: `tabNotifications` (Alerts / التنبيهات), `themeSystem`
  (Auto / تلقائي), `stateOfflineTitle`, `stateErrorBody`, `galleryTitle`
  and others. Tests or goldens that match the old text will fail.
- Visual changes every branch inherits: `SkeletonListRow` leading is a
  rounded tile (`SkeletonBox.tile`), list-row icon tiles are rounded
  squares, `AppSectionHeader` is `labelLarge` in `onSurfaceVariant` (not
  teal), state titles are `titleMedium` and one line, buttons are 52 high,
  `labelSmall` is 12. Regenerate all screenshots after each merge.
- New public API: `OneLineText`, `AppChip`, `AppNavigationBar`,
  `AppNavDestination`, `AppNavigationBarItem`, `showAppSnackBar`,
  `HomeShell.destinations(l10n)`, `AppBorders`, `AppRadii.dialog/chip`,
  `AppSpacing.buttonHeight/navBarHeight/navIndicator/iconTile`,
  `AppColors.surfaceRaised`, `AppTypeScale.maxNavTextScale`.
- CLAUDE.md and AGENTS.md gain two DESIGN bullets; feature branches that
  edited those files will need a trivial merge.
