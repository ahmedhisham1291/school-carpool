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
