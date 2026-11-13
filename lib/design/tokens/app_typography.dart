import 'package:material_ui/material_ui.dart';

/// Type scale. Body text is never below 16 (DESIGN rules).
///
/// Arabic script needs more vertical room than Latin, so line heights are
/// generous (1.4 to 1.6) and letter spacing is always zero: tracking breaks
/// the joins between Arabic letters.
abstract final class AppTypeScale {
  static const double minBodySize = 16;

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
    displayMedium: _style(36, 48, bold),
    displaySmall: _style(32, 44, bold),
    headlineLarge: _style(28, 40, bold),
    headlineMedium: _style(24, 36, semiBold),
    headlineSmall: _style(22, 32, semiBold),
    titleLarge: _style(20, 30, semiBold),
    titleMedium: _style(18, 28, semiBold),
    titleSmall: _style(16, 24, semiBold),
    bodyLarge: _style(18, 28, regular),
    bodyMedium: _style(16, 26, regular),
    // Captions and helper text only; never paragraph text.
    bodySmall: _style(14, 22, regular),
    labelLarge: _style(16, 24, medium),
    labelMedium: _style(14, 20, medium),
    labelSmall: _style(13, 18, medium),
  ).apply(fontFamily: fontFamily);
}
