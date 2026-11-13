# Design guide (direction A, refined)

For every build agent. The tokens in `lib/design/tokens/` and the theme in
`lib/design/theme/app_theme.dart` are the single source of truth; this page
explains how to use them. Screens never hard-code a color, size, radius,
shadow or duration. See every component live in the dev build: Profile >
Developer tools > Component gallery.

Feel: calm, trustworthy, refined. Parents use the app in a hurry, so the
screen is quiet and the one thing to do stands out. Spend color on that one
thing; everything else is ink on soft neutrals.

## Palette

One accent (deep teal) used sparingly: the primary button, the selected tab
pill, focus rings, selected chips, links. Never for headings, section
titles or decoration.

| Role (`ColorScheme` / `AppColors`) | Light | Dark | Use |
| --- | --- | --- | --- |
| `primary` | `#0E5E58` | `#7FCFC3` | Primary button, focus ring, links |
| `onPrimary` | `#FFFFFF` | `#00332D` | Text on the primary button |
| `primaryContainer` | `#DCEDE9` | `#173F3A` | Selected tab pill, selected chip |
| `onPrimaryContainer` | `#0A3A35` | `#BDEDE5` | Icon and text on that wash |
| `surface` | `#F4F7F6` | `#0F1514` | Page background (cool teal-leaning paper / teal graphite, never pure black) |
| `surfaceRaised` (`AppColors`) | `#FFFFFF` | `#19211F` | Cards, sheets, dialogs, inputs, bottom bar (dark: one clear tone step above the page) |
| `onSurface` | `#131A19` | `#E5EAE8` | Main text (near-black ink) |
| `onSurfaceVariant` | `#525D5A` | `#A9B4B1` | Secondary text, icons, section headers |
| `outlineVariant` | `#DCE3E0` | `#323C3A` | Hairline borders and dividers |
| `outline` | `#7C8784` | `#717C79` | Input and secondary-button borders (3:1) |
| `secondaryContainer` | `#E6EDEA` | `#26322F` | Neutral icon tiles in list rows |
| `error` | `#B42318` | `#F2B8B5` | Errors, destructive buttons |
| `success` / `warning` | `#1D6B3F` / `#8A4B00` | `#86D3A0` / `#F2BE6B` | Status text and icons |
| `inverseSurface` | `#232928` | `#E5EAE8` | Snackbars |

Every text pair meets WCAG AA (4.5:1 for text, 3:1 for input and button
borders). The selected-tab pill is a soft wash and is not relied on to show
selection: the selected tab also has a filled icon and a semibold label. `test/design/tokens_test.dart` checks them in both directions and
both themes. Change a color only together with that test.

Direction B (warm indigo) stays behind the dev setting for comparison;
staging and prod always use A.

## Type

One family: IBM Plex Sans Arabic (Arabic and Latin). Letter spacing is
always 0 (tracking breaks Arabic joins). Sentence case; no all-caps labels.

| Style | Size / line height | Weight | Use |
| --- | --- | --- | --- |
| `headlineSmall` | 22 / 32 | 600 | Rare page heroes |
| `titleLarge` | 20 / 30 | 600 | App bar titles |
| `titleMedium` | 18 / 28 | 600 | Card titles, empty/error state titles, dialog titles |
| `titleSmall` | 16 / 24 | 600 | List row titles |
| `bodyLarge` | 18 / 30 | 400 | Input text, important reading text |
| `bodyMedium` | 16 / 26 | 400 | Body text, helper and error text (never smaller) |
| `labelLarge` | 16 / 24 | 500 | Buttons, chips, section headers |
| `labelSmall` | 13 / 18 | 500 | Bottom tab labels only |
| `bodySmall` | 14 / 22 | 400 | Captions only, never sentences |

## Spacing

8-point grid (`AppSpacing`): 4 for icon-to-label, 8 inside a group, 16
between items, 24 at the screen edges (`screenGutter`) and between groups,
32 before a new section. Content max width 640 on wide screens.

## Radii

Three steps, never mixed up: controls 12 (buttons, inputs, icon tiles,
snackbars), cards 16, sheets and dialogs 24. Chips and the tab pill are
full pills.

## Icons and states

Icon sizes come from `AppIconSize`: 20 (chips, chevrons, button icons), 24
(default), 28 (driver buttons), 48 (empty and error states). Pressed,
focused and hovered controls get a veil of their label color at
`AppOpacity.pressed` (0.12) or `hover`/`focus` (0.08), no ripple.

## Borders and elevation

- Surfaces are separated by a 1 px hairline in `outlineVariant`
  (`AppBorders.hairline`), not by shadow. Cards, sheets, dialogs and the
  bottom bar all have one.
- Shadows are a single soft layer and only for things that float
  (`AppElevation.medium` for a card that must stand out, `high` for
  menus). Dark mode uses tone, not shadow.
- The app bar is flat on the page color and turns one step lighter when
  content scrolls under it.

## Components: do and don't

- **Buttons** (`AppButton`): 52 high, radius 12. One primary per screen,
  full width on phones (`expand: true`), at the bottom of the content.
  Secondary is outlined, tertiary is text only. Pressed state is a light
  veil, no ripple. Don't put two filled buttons side by side.
- **Inputs** (`AppTextField`): white (raised) fill, `outline` border, 2 px
  teal focus ring, label above as one line, helper and error text one short
  sentence that says how to fix it.
- **Cards** (`AppCard`): raised surface, hairline border, radius 16, 16
  padding. Don't nest cards or add shadows to every card.
- **List rows** (`AppListRow`): 24 side padding, neutral rounded icon tile,
  one-line title, subtitle up to two lines, chevron that mirrors in Arabic.
- **Chips** (`AppChip`): pill, `outline` border; selected gets the teal
  wash and a teal border. No checkmark.
- **Bottom navigation** (`AppNavigationBar`): raised bar with a hairline on
  top, soft teal pill behind the selected icon, outlined icon when not
  selected and filled when selected (plus a semibold label), 13 px labels.
  Text scale is clamped to 1.3 in the bar only; a label that is still too
  wide scales down, never wraps.
- **App bar titles** (`AppBarTitle`): always `AppBar(title:
  AppBarTitle(text))`, never a plain `Text`. One line, header semantics,
  scales down at large text instead of cutting words.
- **Segmented buttons and other Material widgets that take a label
  widget**: pass `OneLineText(label)`, never `Text`.
- **Section headers** (`AppSectionHeader`): quiet `onSurfaceVariant`
  label, 32 above, 8 below. Not teal, not all caps.
- **Empty, error, offline** (`EmptyStateView`, `ErrorStateView`,
  `OfflineStateView`): one large light icon (no tile), one-line title, one
  short sentence, at most one action. Type carries the hierarchy.
- **Loading** (`Skeleton` + `SkeletonCard`, `SkeletonListRow`): shapes match
  the real content; the pulse stops with reduce-motion.
- **Feedback** (`showAppSnackBar`, or `showAppSnackBarOn(messenger, ...)`
  after an `await`): a few words, one line ("Saved").
- New component: add it to the gallery first, then use it.

## One-line wording

Every label, button, tab, chip and title fits on one line in Arabic and
English on a 320 dp wide phone. Shared components enforce it with
`OneLineText` (maxLines 1, no wrap). Two fallbacks, both safety nets: by
default an ellipsis (list titles, chips, labels); with `scaleDown: true` the
text shrinks to fit so no word is hidden (buttons, app bar, sheet and dialog
titles, which do this already). If either shows at normal text size, the
wording is too long. Write it shorter.

Rules:
- Tabs: one word. Buttons: verb + noun, two or three words. Chips: one or
  two words. Titles: say the thing, not a sentence. Snackbars: a few words.
- Same word for the same action through a flow ("Leave group" on the
  button, "Leave the group?" on the confirmation).
- Arabic first, then English; both must fit.

| Place | Too long | Use |
| --- | --- | --- |
| Tab | Notifications | Alerts / التنبيهات |
| Settings option | Same as phone / حسب الهاتف | Auto / تلقائي |
| State title | No internet connection / لا يوجد اتصال بالإنترنت | No connection / لا يوجد اتصال |
| Button | Open confirmation | Open dialog / فتح التأكيد |
| Snackbar | The function raised its test error. Check Sentry. | Server error sent / تم إرسال خطأ الخادم |
| App bar | Component gallery (with three actions) | Gallery / المعرض |

`test/design/one_line_test.dart` renders tabs (normal and 200 percent
text), buttons, chips, headers, rows, field labels, state views, snackbars,
the Profile tab, and buttons, app bar and dialog titles at 200 percent, at
320 dp in both languages, and fails on any wrap, ellipsis or heavy
shrinking. Add new user-facing labels of these kinds to it.

## Accessibility and motion

Body text scales to 200 percent everywhere except the tab bar (clamped at
1.3). Touch targets at least 48. Every icon-only button has a tooltip or
semantics label. Motion is 120 to 300 ms with ease-out, and all of it is
off when the phone asks to reduce motion.
