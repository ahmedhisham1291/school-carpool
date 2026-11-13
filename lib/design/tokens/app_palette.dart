import 'package:material_ui/material_ui.dart';

/// Status colors that Material's [ColorScheme] does not cover.
@immutable
class StatusColors {
  const StatusColors({
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.skeletonBase,
    required this.skeletonHighlight,
  });

  final Color success;
  final Color onSuccess;
  final Color successContainer;
  final Color onSuccessContainer;
  final Color warning;
  final Color onWarning;
  final Color warningContainer;
  final Color onWarningContainer;
  final Color skeletonBase;
  final Color skeletonHighlight;
}

/// One brightness of one design direction.
@immutable
class AppPalette {
  const AppPalette({required this.scheme, required this.status});

  final ColorScheme scheme;
  final StatusColors status;
}

// ---------------------------------------------------------------------------
// Direction A: "Calm teal", refined (design refresh 01).
// A deep teal accent used sparingly, soft warm-neutral surfaces, white cards
// with hairline borders and near-black ink. Dark theme is a deep teal
// graphite, never pure black. Roles and hex values: docs/DESIGN.md.
// Contrast (WCAG): primary/onPrimary 7.6, surface/onSurfaceVariant 6.3,
// outline on every light surface at least 3.1.
// ---------------------------------------------------------------------------

const AppPalette directionALight = AppPalette(
  scheme: ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF0E5E58),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFDCEDE9),
    onPrimaryContainer: Color(0xFF0A3A35),
    secondary: Color(0xFF4B5A57),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFECEAE4),
    onSecondaryContainer: Color(0xFF1E2826),
    tertiary: Color(0xFF4B5A57),
    onTertiary: Color(0xFFFFFFFF),
    error: Color(0xFFB42318),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFBE8E6),
    onErrorContainer: Color(0xFF5C130C),
    surface: Color(0xFFF7F6F3),
    onSurface: Color(0xFF141A19),
    surfaceDim: Color(0xFFE1DFD9),
    surfaceBright: Color(0xFFF7F6F3),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF1F0EC),
    surfaceContainer: Color(0xFFEDEBE7),
    surfaceContainerHigh: Color(0xFFE7E5E0),
    surfaceContainerHighest: Color(0xFFE1DFD9),
    onSurfaceVariant: Color(0xFF545D5B),
    outline: Color(0xFF7F8683),
    outlineVariant: Color(0xFFE3E1DB),
    shadow: Color(0xFF141A19),
    scrim: Color(0xFF000000),
    inverseSurface: Color(0xFF232928),
    onInverseSurface: Color(0xFFF1F0EC),
    inversePrimary: Color(0xFF8ED3C8),
    surfaceTint: Color(0x00000000),
  ),
  status: StatusColors(
    success: Color(0xFF1D6B3F),
    onSuccess: Color(0xFFFFFFFF),
    successContainer: Color(0xFFE2F0E6),
    onSuccessContainer: Color(0xFF0B3A1F),
    warning: Color(0xFF8A4B00),
    onWarning: Color(0xFFFFFFFF),
    warningContainer: Color(0xFFFAEAD3),
    onWarningContainer: Color(0xFF3D2200),
    skeletonBase: Color(0xFFECEAE4),
    skeletonHighlight: Color(0xFFF5F4F0),
  ),
);

const AppPalette directionADark = AppPalette(
  scheme: ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFF7FCFC3),
    onPrimary: Color(0xFF00332D),
    primaryContainer: Color(0xFF173F3A),
    onPrimaryContainer: Color(0xFFBDEDE5),
    secondary: Color(0xFFB3C1BE),
    onSecondary: Color(0xFF1E2826),
    secondaryContainer: Color(0xFF243030),
    onSecondaryContainer: Color(0xFFD5E1DE),
    tertiary: Color(0xFFB3C1BE),
    onTertiary: Color(0xFF1E2826),
    error: Color(0xFFF2B8B5),
    onError: Color(0xFF601410),
    errorContainer: Color(0xFF5A1A16),
    onErrorContainer: Color(0xFFFADCD9),
    surface: Color(0xFF111716),
    onSurface: Color(0xFFE5EAE8),
    surfaceDim: Color(0xFF111716),
    surfaceBright: Color(0xFF2F3836),
    surfaceContainerLowest: Color(0xFF0C1110),
    surfaceContainerLow: Color(0xFF171E1D),
    surfaceContainer: Color(0xFF1B2322),
    surfaceContainerHigh: Color(0xFF222A29),
    surfaceContainerHighest: Color(0xFF2A3331),
    onSurfaceVariant: Color(0xFFA7B2AF),
    outline: Color(0xFF6E7976),
    outlineVariant: Color(0xFF283130),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: Color(0xFFE5EAE8),
    onInverseSurface: Color(0xFF232928),
    inversePrimary: Color(0xFF0E5E58),
    surfaceTint: Color(0x00000000),
  ),
  status: StatusColors(
    success: Color(0xFF86D3A0),
    onSuccess: Color(0xFF00391A),
    successContainer: Color(0xFF173D27),
    onSuccessContainer: Color(0xFFC9F0D5),
    warning: Color(0xFFF2BE6B),
    onWarning: Color(0xFF452B00),
    warningContainer: Color(0xFF44300F),
    onWarningContainer: Color(0xFFFBE3BC),
    skeletonBase: Color(0xFF1F2827),
    skeletonHighlight: Color(0xFF283130),
  ),
);

// ---------------------------------------------------------------------------
// Direction B: "Warm indigo". One indigo accent on warm sand neutrals.
// Contrast (WCAG): primary/onPrimary 7.0, surface/onSurfaceVariant 8.3.
// ---------------------------------------------------------------------------

const AppPalette directionBLight = AppPalette(
  scheme: ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF3A4BC8),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFDFE1FF),
    onPrimaryContainer: Color(0xFF00105C),
    secondary: Color(0xFF5C5D72),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFE1E0F9),
    onSecondaryContainer: Color(0xFF191A2C),
    tertiary: Color(0xFF5C5D72),
    onTertiary: Color(0xFFFFFFFF),
    error: Color(0xFFB3261E),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFF9DEDC),
    onErrorContainer: Color(0xFF410E0B),
    surface: Color(0xFFFBF8F3),
    onSurface: Color(0xFF1D1B18),
    surfaceDim: Color(0xFFDDD9D2),
    surfaceBright: Color(0xFFFBF8F3),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF5F1EA),
    surfaceContainer: Color(0xFFEFEBE4),
    surfaceContainerHigh: Color(0xFFE9E5DE),
    surfaceContainerHighest: Color(0xFFE3DFD8),
    onSurfaceVariant: Color(0xFF4F4A42),
    outline: Color(0xFF807A70),
    outlineVariant: Color(0xFFD8D2C7),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: Color(0xFF32302C),
    onInverseSurface: Color(0xFFF5F0E9),
    inversePrimary: Color(0xFFBBC3FF),
    surfaceTint: Color(0x00000000),
  ),
  status: StatusColors(
    success: Color(0xFF1E7A3C),
    onSuccess: Color(0xFFFFFFFF),
    successContainer: Color(0xFFD4F1DC),
    onSuccessContainer: Color(0xFF00210C),
    warning: Color(0xFF8A5300),
    onWarning: Color(0xFFFFFFFF),
    warningContainer: Color(0xFFFFE2BC),
    onWarningContainer: Color(0xFF2C1800),
    skeletonBase: Color(0xFFE9E5DE),
    skeletonHighlight: Color(0xFFF5F1EA),
  ),
);

const AppPalette directionBDark = AppPalette(
  scheme: ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFFBBC3FF),
    onPrimary: Color(0xFF142291),
    primaryContainer: Color(0xFF2D3DB0),
    onPrimaryContainer: Color(0xFFDFE1FF),
    secondary: Color(0xFFC5C4DD),
    onSecondary: Color(0xFF2E2F42),
    secondaryContainer: Color(0xFF444559),
    onSecondaryContainer: Color(0xFFE1E0F9),
    tertiary: Color(0xFFC5C4DD),
    onTertiary: Color(0xFF2E2F42),
    error: Color(0xFFF2B8B5),
    onError: Color(0xFF601410),
    errorContainer: Color(0xFF8C1D18),
    onErrorContainer: Color(0xFFF9DEDC),
    surface: Color(0xFF151310),
    onSurface: Color(0xFFE8E2DA),
    surfaceDim: Color(0xFF151310),
    surfaceBright: Color(0xFF3C3935),
    surfaceContainerLowest: Color(0xFF100E0B),
    surfaceContainerLow: Color(0xFF1D1B18),
    surfaceContainer: Color(0xFF221F1C),
    surfaceContainerHigh: Color(0xFF2C2A26),
    surfaceContainerHighest: Color(0xFF373430),
    onSurfaceVariant: Color(0xFFCFC6BA),
    outline: Color(0xFF989085),
    outlineVariant: Color(0xFF4C463E),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: Color(0xFFE8E2DA),
    onInverseSurface: Color(0xFF32302C),
    inversePrimary: Color(0xFF3A4BC8),
    surfaceTint: Color(0x00000000),
  ),
  status: StatusColors(
    success: Color(0xFF7FD99A),
    onSuccess: Color(0xFF00391A),
    successContainer: Color(0xFF00522A),
    onSuccessContainer: Color(0xFFD4F1DC),
    warning: Color(0xFFF5BD62),
    onWarning: Color(0xFF452B00),
    warningContainer: Color(0xFF633F00),
    onWarningContainer: Color(0xFFFFE2BC),
    skeletonBase: Color(0xFF2C2A26),
    skeletonHighlight: Color(0xFF373430),
  ),
);
