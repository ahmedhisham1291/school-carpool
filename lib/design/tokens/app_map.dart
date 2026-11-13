/// Map tokens (Prompt 5). Colors of the map itself come from the theme
/// (`mapStyleJson` in lib/features/maps/map_style.dart); these are the
/// sizes, zoom levels and opacities of what we draw on it.
abstract final class AppMapTokens {
  /// Zoom for a whole city (no home yet).
  static const double cityZoom = 11;

  /// Zoom for a home pin or a school.
  static const double streetZoom = 16;

  /// Zoom for the nearby parents map (about a 3 km radius on a phone).
  static const double areaZoom = 13;

  /// A parent's blurred marker: two soft discs, no pin, so nobody reads a
  /// house from it. Radii in meters on the ground.
  static const double blurInnerRadiusM = 180;
  static const double blurOuterRadiusM = 320;

  /// Fill opacities of the inner and outer discs (accent color).
  static const double blurInnerOpacity = 0.28;
  static const double blurOuterOpacity = 0.12;

  /// Opacity of the radius ring on the nearby map.
  static const double radiusRingOpacity = 0.06;

  /// Height of the map on screens that show it above a list.
  static const double mapHeight = 280;

  /// Size of the centre pin in the home picker (its tip marks the point).
  static const double centerPinSize = 48;
}
