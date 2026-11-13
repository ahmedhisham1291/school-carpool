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
// Direction A: "Calm teal". One teal accent on cool, almost-white neutrals.
// Contrast (WCAG): primary/onPrimary 6.1, surface/onSurfaceVariant 7.1.
// ---------------------------------------------------------------------------

const AppPalette directionALight = AppPalette(
  scheme: ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF0B6E66),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFCDEDE8),
    onPrimaryContainer: Color(0xFF00201D),
    secondary: Color(0xFF4A635F),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFDCE8E5),
    onSecondaryContainer: Color(0xFF0F1F1C),
    tertiary: Color(0xFF4A635F),
    onTertiary: Color(0xFFFFFFFF),
    error: Color(0xFFB3261E),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFF9DEDC),
    onErrorContainer: Color(0xFF410E0B),
    surface: Color(0xFFF7F9F8),
    onSurface: Color(0xFF161D1C),
    surfaceDim: Color(0xFFD7DBDA),
    surfaceBright: Color(0xFFF7F9F8),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF1F4F3),
    surfaceContainer: Color(0xFFEBEFEE),
    surfaceContainerHigh: Color(0xFFE5EAE8),
    surfaceContainerHighest: Color(0xFFDFE4E2),
    onSurfaceVariant: Color(0xFF4D5755),
    outline: Color(0xFF78827F),
    outlineVariant: Color(0xFFD6DDDA),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: Color(0xFF2B3231),
    onInverseSurface: Color(0xFFEEF2F0),
    inversePrimary: Color(0xFF7FD5CA),
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
    skeletonBase: Color(0xFFE5EAE8),
    skeletonHighlight: Color(0xFFF1F4F3),
  ),
);

const AppPalette directionADark = AppPalette(
  scheme: ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFF7FD5CA),
    onPrimary: Color(0xFF00382F),
    primaryContainer: Color(0xFF005048),
    onPrimaryContainer: Color(0xFFA3F1E6),
    secondary: Color(0xFFB1CCC7),
    onSecondary: Color(0xFF1C3531),
    secondaryContainer: Color(0xFF334B47),
    onSecondaryContainer: Color(0xFFCDE8E2),
    tertiary: Color(0xFFB1CCC7),
    onTertiary: Color(0xFF1C3531),
    error: Color(0xFFF2B8B5),
    onError: Color(0xFF601410),
    errorContainer: Color(0xFF8C1D18),
    onErrorContainer: Color(0xFFF9DEDC),
    surface: Color(0xFF0F1514),
    onSurface: Color(0xFFDEE4E2),
    surfaceDim: Color(0xFF0F1514),
    surfaceBright: Color(0xFF353B3A),
    surfaceContainerLowest: Color(0xFF0A0F0E),
    surfaceContainerLow: Color(0xFF171D1C),
    surfaceContainer: Color(0xFF1B2120),
    surfaceContainerHigh: Color(0xFF252B2A),
    surfaceContainerHighest: Color(0xFF303635),
    onSurfaceVariant: Color(0xFFBEC9C6),
    outline: Color(0xFF889390),
    outlineVariant: Color(0xFF3F4947),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: Color(0xFFDEE4E2),
    onInverseSurface: Color(0xFF2B3231),
    inversePrimary: Color(0xFF0B6E66),
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
    skeletonBase: Color(0xFF252B2A),
    skeletonHighlight: Color(0xFF303635),
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
