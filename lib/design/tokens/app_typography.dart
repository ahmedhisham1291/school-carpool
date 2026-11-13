import 'package:material_ui/material_ui.dart';

/// Type scale. Body text is never below 16 (DESIGN rules).
///
/// Refined hierarchy: semibold (600) for titles, medium (500) for labels and
/// regular (400) for reading text; bold is kept for the rare display size.
/// Arabic script needs more vertical room than Latin, so line heights are
/// generous (about 1.5 for body text) and letter spacing is always zero:
/// tracking breaks the joins between Arabic letters.
abstract final class AppTypeScale {
  static const double minBodySize = 16;

  /// Largest text scale the bottom navigation follows. Body text still
  /// scales to 200 percent; the tab labels stay on one line.
  static const double maxNavTextScale = 1.3;

  static const FontWeight regular = FontWeight.w400;
  static const FontWeight medium = FontWeight.w500;
  static const FontWeight semiBold = FontWeight.w600;
  static const FontWeight bold = FontWeight.w700;

  static TextStyle _style(double size, double lineHeight, FontWeight weight) => TextStyle(
    fontSize: size,
    height: lineHeight / size,
    fontWeight: weight,
    letterSpacing: 0,
    leadingDistribution: TextLeadingDistribution.even,
  );

  /// Builds the Material text theme for a font family. Colors come from the
  /// color scheme in `AppTheme`.
  static TextTheme textTheme(String fontFamily) => TextTheme(
    displayLarge: _style(40, 52, bold),
    displayMedium: _style(36, 48, semiBold),
    displaySmall: _style(32, 44, semiBold),
    headlineLarge: _style(28, 40, semiBold),
    headlineMedium: _style(24, 36, semiBold),
    headlineSmall: _style(22, 32, semiBold),
    // App bar titles.
    titleLarge: _style(20, 30, semiBold),
    // Card titles, empty and error state titles.
    titleMedium: _style(18, 28, semiBold),
    // List row titles.
    titleSmall: _style(16, 24, semiBold),
    bodyLarge: _style(18, 30, regular),
    bodyMedium: _style(16, 26, regular),
    // Captions only; never paragraph text.
    bodySmall: _style(14, 22, regular),
    // Buttons, chips, section headers.
    labelLarge: _style(16, 24, medium),
    labelMedium: _style(14, 20, medium),
    // Bottom navigation labels: quiet and small, always one line.
    labelSmall: _style(13, 18, medium),
  ).apply(fontFamily: fontFamily);
}
