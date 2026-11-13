import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/theme/app_colors.dart';
import 'package:school_carpool/design/theme/app_theme.dart';
import 'package:school_carpool/design/theme/design_direction.dart';

/// Short accessors for theme tokens inside widgets.
extension ThemeContext on BuildContext {
  ThemeData get theme => Theme.of(this);
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;

  /// Status, skeleton and shadow tokens. Falls back to direction A if a
  /// widget is pumped without our theme (for example in isolated tests).
  AppColors get appColors =>
      Theme.of(this).extension<AppColors>() ??
      AppTheme.build(DesignDirection.a, Theme.of(this).brightness).extension<AppColors>()!;
}
