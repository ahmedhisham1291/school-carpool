import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/theme/app_colors.dart';
import 'package:school_carpool/design/theme/design_direction.dart';
import 'package:school_carpool/design/tokens/app_borders.dart';
import 'package:school_carpool/design/tokens/app_motion.dart';
import 'package:school_carpool/design/tokens/app_palette.dart';
import 'package:school_carpool/design/tokens/app_radii.dart';
import 'package:school_carpool/design/tokens/app_spacing.dart';
import 'package:school_carpool/design/tokens/app_typography.dart';

/// Builds the Material 3 [ThemeData] for a design direction and brightness.
///
/// Every color, size, radius and duration comes from the tokens in
/// `lib/design/tokens`. Screens never hard-code these values.
abstract final class AppTheme {
  static ThemeData light(DesignDirection direction, {bool reduceMotion = false}) =>
      build(direction, Brightness.light, reduceMotion: reduceMotion);

  static ThemeData dark(DesignDirection direction, {bool reduceMotion = false}) =>
      build(direction, Brightness.dark, reduceMotion: reduceMotion);

  /// [reduceMotion]: the phone asked for less motion, so button animations
  /// and page transitions are switched off.
  static ThemeData build(
    DesignDirection direction,
    Brightness brightness, {
    bool reduceMotion = false,
  }) {
    final AppPalette palette = direction.palette(brightness);
    final ColorScheme scheme = palette.scheme;
    final AppColors appColors = AppColors.fromPalette(palette);
    final Color raised = appColors.surfaceRaised;
    final TextTheme text = AppTypeScale.textTheme(
      direction.fontFamily,
    ).apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);

    final BorderSide hairline = BorderSide(color: scheme.outlineVariant);
    final BorderSide controlBorder = BorderSide(color: scheme.outline);

    const Size minButtonSize = Size(AppSpacing.buttonHeight, AppSpacing.buttonHeight);
    const EdgeInsetsGeometry buttonPadding = EdgeInsetsDirectional.symmetric(
      horizontal: AppSpacing.s24,
      vertical: AppSpacing.s8,
    );
    const OutlinedBorder buttonShape = RoundedRectangleBorder(borderRadius: AppRadii.control);
    final Duration buttonMotion = reduceMotion ? Duration.zero : AppMotion.fast;

    // Subtle pressed state: a light veil of the label color, no ripple.
    WidgetStateProperty<Color?> veil(Color color) =>
        WidgetStateProperty.resolveWith<Color?>((Set<WidgetState> states) {
          if (states.contains(WidgetState.pressed)) {
            return color.withValues(alpha: 0.12);
          }
          if (states.contains(WidgetState.focused) || states.contains(WidgetState.hovered)) {
            return color.withValues(alpha: 0.08);
          }
          return null;
        });

    ButtonStyle buttonBase(Color labelColor) => ButtonStyle(
      minimumSize: const WidgetStatePropertyAll<Size>(minButtonSize),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(buttonPadding),
      shape: const WidgetStatePropertyAll<OutlinedBorder>(buttonShape),
      textStyle: WidgetStatePropertyAll<TextStyle?>(text.labelLarge),
      overlayColor: veil(labelColor),
      splashFactory: NoSplash.splashFactory,
      elevation: const WidgetStatePropertyAll<double>(0),
      animationDuration: buttonMotion,
    );

    OutlineInputBorder inputBorder(Color color, [double width = AppBorders.hairline]) =>
        OutlineInputBorder(
          borderRadius: AppRadii.control,
          borderSide: BorderSide(color: color, width: width),
        );

    return ThemeData(
      colorScheme: scheme,
      brightness: brightness,
      fontFamily: direction.fontFamily,
      textTheme: text,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      dividerColor: scheme.outlineVariant,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      splashFactory: NoSplash.splashFactory,
      pageTransitionsTheme: reduceMotion
          ? PageTransitionsTheme(
              builders: <TargetPlatform, PageTransitionsBuilder>{
                for (final TargetPlatform platform in TargetPlatform.values)
                  platform: const NoMotionPageTransitionsBuilder(),
              },
            )
          : null,
      extensions: <ThemeExtension<dynamic>>[appColors],
      appBarTheme: AppBarThemeData(
        // Same tone as the page; one step raised once content scrolls under.
        backgroundColor: WidgetStateColor.resolveWith(
          (Set<WidgetState> states) =>
              states.contains(WidgetState.scrolledUnder) ? scheme.surfaceContainerLow : scheme.surface,
        ),
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: scheme.surfaceTint,
        centerTitle: false,
        titleSpacing: AppSpacing.s24,
        titleTextStyle: text.titleLarge,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: buttonBase(scheme.onPrimary).merge(
          FilledButton.styleFrom(
            backgroundColor: scheme.primary,
            foregroundColor: scheme.onPrimary,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: buttonBase(scheme.primary).merge(
          OutlinedButton.styleFrom(
            foregroundColor: scheme.primary,
            backgroundColor: raised,
            side: controlBorder,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: buttonBase(scheme.primary).merge(
          TextButton.styleFrom(foregroundColor: scheme.primary),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(AppSpacing.minTouchTarget, AppSpacing.minTouchTarget),
          foregroundColor: scheme.onSurfaceVariant,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(
            Size(AppSpacing.minTouchTarget, AppSpacing.minTouchTarget),
          ),
          textStyle: WidgetStatePropertyAll<TextStyle?>(text.labelLarge),
          side: WidgetStatePropertyAll<BorderSide>(controlBorder),
          splashFactory: NoSplash.splashFactory,
          overlayColor: veil(scheme.primary),
          backgroundColor: WidgetStateProperty.resolveWith<Color?>(
            (Set<WidgetState> states) =>
                states.contains(WidgetState.selected) ? scheme.primaryContainer : raised,
          ),
          foregroundColor: WidgetStateProperty.resolveWith<Color?>(
            (Set<WidgetState> states) => states.contains(WidgetState.selected)
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: raised,
        selectedColor: scheme.primaryContainer,
        disabledColor: scheme.surfaceContainerHigh,
        side: controlBorder,
        shape: const StadiumBorder(),
        labelStyle: text.labelLarge?.copyWith(color: scheme.onSurface),
        padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.s8),
        showCheckmark: false,
        elevation: 0,
        pressElevation: 0,
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: raised,
        contentPadding: const EdgeInsetsDirectional.symmetric(
          horizontal: AppSpacing.s16,
          vertical: AppSpacing.s16,
        ),
        border: inputBorder(scheme.outline),
        enabledBorder: inputBorder(scheme.outline),
        // Clear focus ring: the accent at two pixels.
        focusedBorder: inputBorder(scheme.primary, AppBorders.focus),
        errorBorder: inputBorder(scheme.error),
        focusedErrorBorder: inputBorder(scheme.error, AppBorders.focus),
        disabledBorder: inputBorder(scheme.outlineVariant),
        labelStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        floatingLabelStyle: WidgetStateTextStyle.resolveWith((Set<WidgetState> states) {
          final Color color = states.contains(WidgetState.error)
              ? scheme.error
              : states.contains(WidgetState.focused)
              ? scheme.primary
              : scheme.onSurfaceVariant;
          return (text.bodyMedium ?? const TextStyle()).copyWith(color: color);
        }),
        hintStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        // Helper and error text tell the parent what to do: body size (16).
        helperStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        errorStyle: text.bodyMedium?.copyWith(color: scheme.error),
        hintMaxLines: 1,
        helperMaxLines: 2,
        errorMaxLines: 2,
      ),
      cardTheme: CardThemeData(
        color: raised,
        surfaceTintColor: scheme.surfaceTint,
        shadowColor: scheme.shadow,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: AppRadii.card, side: hairline),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: raised,
        modalBackgroundColor: raised,
        surfaceTintColor: scheme.surfaceTint,
        elevation: 0,
        modalElevation: 0,
        showDragHandle: true,
        dragHandleColor: scheme.outline,
        shape: RoundedRectangleBorder(borderRadius: AppRadii.sheetTop, side: hairline),
        clipBehavior: Clip.antiAlias,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: raised,
        surfaceTintColor: scheme.surfaceTint,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: AppRadii.dialog, side: hairline),
        titleTextStyle: text.titleMedium,
        contentTextStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
      // Kept for any stock NavigationBar; the app shell uses
      // AppNavigationBar, which follows the same tokens.
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: raised,
        surfaceTintColor: scheme.surfaceTint,
        indicatorColor: scheme.primaryContainer,
        indicatorShape: const StadiumBorder(),
        elevation: 0,
        height: AppSpacing.navBarHeight + AppSpacing.s8,
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>((Set<WidgetState> states) {
          final bool selected = states.contains(WidgetState.selected);
          return text.labelSmall?.copyWith(
            color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
            fontWeight: selected ? AppTypeScale.semiBold : AppTypeScale.medium,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith<IconThemeData?>((Set<WidgetState> states) {
          final bool selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          );
        }),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(color: scheme.onInverseSurface),
        actionTextColor: scheme.inversePrimary,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.control),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: AppBorders.hairline,
        space: AppBorders.hairline,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHigh,
      ),
      listTileTheme: ListTileThemeData(
        titleTextStyle: text.titleSmall,
        subtitleTextStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        iconColor: scheme.onSurfaceVariant,
      ),
    );
  }
}

/// Page transition with no movement, used when the phone asks for reduced
/// motion. The new page appears at once.
class NoMotionPageTransitionsBuilder extends PageTransitionsBuilder {
  const NoMotionPageTransitionsBuilder();

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}
