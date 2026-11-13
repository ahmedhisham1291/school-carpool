import 'package:material_ui/material_ui.dart';

/// Motion is short and subtle, and follows the phone's reduce-motion setting.
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 300);

  /// Skeleton shimmer loop. Not reduced to zero; it simply stops shimmering.
  static const Duration shimmer = Duration(milliseconds: 1400);

  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;

  /// Returns [duration], or zero when the user asked the OS to reduce motion.
  static Duration resolve(BuildContext context, Duration duration) =>
      reduceMotion(context) ? Duration.zero : duration;

  /// True for Android "Remove animations" (`disableAnimations`) and for iOS
  /// "Reduce Motion", which Flutter reports separately as `reduceMotion`.
  static bool reduceMotion(BuildContext context) =>
      (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ||
      (MediaQuery.maybeReduceMotionOf(context) ?? false);

  /// Same check without a [BuildContext], for the app root that builds the
  /// theme above [MediaQuery].
  static bool platformReducesMotion() {
    final features = WidgetsBinding.instance.platformDispatcher.accessibilityFeatures;
    return features.disableAnimations || features.reduceMotion;
  }
}
