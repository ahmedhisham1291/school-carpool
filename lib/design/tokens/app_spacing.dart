import 'package:material_ui/material_ui.dart';

/// 8-point spacing grid. Screens use these values, never literal numbers.
///
/// `s4` is the only half step, for tight gaps such as icon-to-label.
/// Rhythm: 8 inside a group, 16 between items, 24 between groups and at the
/// screen edges, 32 or more before a new section.
abstract final class AppSpacing {
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s16 = 16;
  static const double s24 = 24;
  static const double s32 = 32;
  static const double s40 = 40;
  static const double s48 = 48;
  static const double s64 = 64;

  /// Minimum touch target on every platform (DESIGN rules: 48 by 48).
  static const double minTouchTarget = 48;

  /// Height of regular buttons: a little taller than the minimum target, so
  /// the full-width primary action feels calm and easy to hit.
  static const double buttonHeight = 52;

  /// Large touch target for driver screens ("readable at a glance").
  static const double driverTouchTarget = 64;

  /// Bottom navigation: minimum bar height (without the safe area), and the
  /// pill that marks the selected tab.
  static const double navBarHeight = 64;
  static const Size navIndicator = Size(56, 32);

  /// Square tile behind a list row's leading icon.
  static const double iconTile = 40;

  /// Horizontal padding of every screen body.
  static const double screenGutter = s24;

  /// Maximum width of reading content on wide screens (web, tablets).
  static const double maxContentWidth = 640;

  static const EdgeInsetsDirectional screenPadding =
      EdgeInsetsDirectional.symmetric(horizontal: screenGutter, vertical: s16);

  static const EdgeInsetsDirectional cardPadding = EdgeInsetsDirectional.all(s16);

  /// Every value on the grid, used by tests to enforce the 8-point rule.
  static const List<double> all = <double>[s4, s8, s16, s24, s32, s40, s48, s64];
}
