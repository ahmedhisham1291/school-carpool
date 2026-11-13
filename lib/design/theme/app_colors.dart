import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/tokens/app_palette.dart';
import 'package:school_carpool/design/tokens/app_shadows.dart';

/// Theme extension for the tokens Material's [ThemeData] has no slot for:
/// status colors, skeleton colors and shadows.
///
/// Read it with `context.appColors` (see `theme_context.dart`).
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
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
    required this.brightness,
  });

  factory AppColors.fromPalette(AppPalette palette) {
    final StatusColors s = palette.status;
    return AppColors(
      success: s.success,
      onSuccess: s.onSuccess,
      successContainer: s.successContainer,
      onSuccessContainer: s.onSuccessContainer,
      warning: s.warning,
      onWarning: s.onWarning,
      warningContainer: s.warningContainer,
      onWarningContainer: s.onWarningContainer,
      skeletonBase: s.skeletonBase,
      skeletonHighlight: s.skeletonHighlight,
      brightness: palette.scheme.brightness,
    );
  }

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
  final Brightness brightness;

  List<BoxShadow> shadow(AppElevation elevation) => AppShadows.of(brightness, elevation);

  @override
  AppColors copyWith({
    Color? success,
    Color? onSuccess,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? warning,
    Color? onWarning,
    Color? warningContainer,
    Color? onWarningContainer,
    Color? skeletonBase,
    Color? skeletonHighlight,
    Brightness? brightness,
  }) {
    return AppColors(
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      successContainer: successContainer ?? this.successContainer,
      onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      warningContainer: warningContainer ?? this.warningContainer,
      onWarningContainer: onWarningContainer ?? this.onWarningContainer,
      skeletonBase: skeletonBase ?? this.skeletonBase,
      skeletonHighlight: skeletonHighlight ?? this.skeletonHighlight,
      brightness: brightness ?? this.brightness,
    );
  }

  @override
  AppColors lerp(covariant ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) {
      return this;
    }
    Color mix(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return AppColors(
      success: mix(success, other.success),
      onSuccess: mix(onSuccess, other.onSuccess),
      successContainer: mix(successContainer, other.successContainer),
      onSuccessContainer: mix(onSuccessContainer, other.onSuccessContainer),
      warning: mix(warning, other.warning),
      onWarning: mix(onWarning, other.onWarning),
      warningContainer: mix(warningContainer, other.warningContainer),
      onWarningContainer: mix(onWarningContainer, other.onWarningContainer),
      skeletonBase: mix(skeletonBase, other.skeletonBase),
      skeletonHighlight: mix(skeletonHighlight, other.skeletonHighlight),
      brightness: t < 0.5 ? brightness : other.brightness,
    );
  }
}
