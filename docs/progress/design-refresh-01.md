# Design refresh 01 — progress note

Branch: `design-refresh-01`. Date: 13 Nov 2026. Owner feedback: "more
elegant", and "every word/sentence on one line" (the Notifications tab
label took two lines).

**Status: code complete, written, not run here** (no Flutter SDK). CI runs
`flutter analyze`, `flutter test` (including the new
`test/design/one_line_test.dart`) and the screenshots.

## What changed

- Tokens: refined direction A palette (docs/DESIGN.md), semibold titles,
  12 px tab labels, `AppBorders` (hairline 1, focus 2), single-layer
  shadows, 52 dp buttons, 24 dp screen gutter, `surfaceRaised`.
- Theme: hairline cards/sheets/dialogs, teal focus ring, subtle pressed
  veil (no ripple), segmented button and chip themes, app bar that tints
  when scrolled under.
- Components: `OneLineText` used in buttons, list titles, headers, sheet
  and dialog titles, field labels, chips, state titles; `showAppSnackBar`
  (one line); new `AppNavigationBar` (pill, icon pairs, label scales down,
  text scale clamped to 1.3 in the bar) and `AppChip`. Shell uses the new
  bar. Gallery shows hex swatches, chips and the bar.
- Wording: EN tab "Alerts", AR "التنبيهات"; "Auto"/"تلقائي"; shorter
  state titles, gallery labels and snackbars.
- Tests: one-line test at 320 dp (AR/EN; tabs at text x1 and x2),
  extended contrast and type tests, 320 dp shell screenshots.
- Docs: docs/DESIGN.md; two DESIGN bullets in CLAUDE.md and AGENTS.md.

## Notes for merging

- `NavigationBar`/`NavigationDestination` are no longer used by the shell;
  tests should find `AppNavigationBarItem`.
- `AppSpacing.screenGutter` is now 24 (was 16); list rows and section
  headers use it.
- `lib/features/settings/settings_section.dart` was not touched; its
  snackbars still use `SnackBar` directly (short wording now). Switch them
  to `showAppSnackBar` when that file is next edited.

## Open questions

1. Is "Alerts" / "التنبيهات" the final tab name?
2. The 200 percent text check uses an ellipsis as the last resort on
   buttons; OK, or should buttons grow to two lines only at very large
   text sizes?

## Review round 1 (docs/reviews/design-refresh-01-review.md)

Fixed:
- Blocking 1: `AppBarTitle` (one line, header semantics, scales down) used
  by the placeholder tabs, the gallery and the one-line test.
- Blocking 2: settings segment labels and field label use `OneLineText`;
  settings snackbars use `showAppSnackBarOn`. (`date_field` and
  `select_field` are not on this branch: change them to
  `label: OneLineText(label)` when merging prompt 03/04.)
- 200 percent text: `OneLineText(scaleDown: true)` in buttons, app bar,
  sheet and dialog titles (shrink, never ellipsis); new x2 test.
- Pill contrast: doc and test no longer claim 3:1; selection is also the
  filled icon and semibold label.
- Dark separation: page `#0F1514`, cards `#19211F`, hairline `#323C3A`.
- Tokens: `AppOpacity`, `AppIconSize`, `AppSpacing.maxSentenceWidth`.
- Elegance: cooler teal-leaning paper `#F4F7F6`; state views drop the icon
  tile (large light icon); tab labels 13 px.

Not done: the bold "today's run" card (Home is a feature screen) and the
long-press large label on tabs.
