import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/tokens/app_palette.dart';

/// The two color and type directions offered to the owner in Prompt 1.
///
/// A dev setting switches between them; the default is [a]. Once the owner
/// picks one, the other is deleted (see docs/progress/prompt-01.md).
enum DesignDirection {
  /// Calm teal accent, cool neutrals, IBM Plex Sans Arabic.
  a(
    fontFamily: 'IBMPlexSansArabic',
    light: directionALight,
    dark: directionADark,
  ),

  /// Warm indigo accent, sand neutrals, Tajawal.
  b(
    fontFamily: 'Tajawal',
    light: directionBLight,
    dark: directionBDark,
  );

  const DesignDirection({
    required this.fontFamily,
    required this.light,
    required this.dark,
  });

  final String fontFamily;
  final AppPalette light;
  final AppPalette dark;

  AppPalette palette(Brightness brightness) =>
      brightness == Brightness.light ? light : dark;

  static DesignDirection fromName(String? name) =>
      DesignDirection.values.firstWhere((DesignDirection d) => d.name == name, orElse: () => a);
}
