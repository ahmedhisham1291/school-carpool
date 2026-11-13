import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/theme/app_colors.dart';
import 'package:school_carpool/design/theme/design_direction.dart';
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
  static ThemeData light(DesignDirection direction) => build(direction, Brightness.light);

  static ThemeData dark(DesignDirection direction) => build(direction, Brightness.dark);

  static ThemeData build(DesignDirection direction, Brightness brightness) {
    final AppPalette palette = direction.palette(brightness);
    final ColorScheme scheme = palette.scheme;
    final TextTheme text = AppTypeScale.textTheme(
      direction.fontFamily,
    ).apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);

    const Size minButtonSize = Size(AppSpacing.minTouchTarget, AppSpacing.minTouchTarget);
    const EdgeInsetsGeometry buttonPadding = EdgeInsetsDirectional.symmetric(
      horizontal: AppSpacing.s24,
      vertical: AppSpacing.s8,
    );
    const OutlinedBorder buttonShape = RoundedRectangleBorder(borderRadius: AppRadii.control);

    OutlineInputBorder inputBorder(Color color, [double width = 1]) => OutlineInputBorder(
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
      extensions: <ThemeExtension<dynamic>>[AppColors.fromPalette(palette)],
      appBarTheme: AppBarThemeData(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: scheme.surfaceTint,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: minButtonSize,
          padding: buttonPadding,
          shape: buttonShape,
          textStyle: text.labelLarge,
          animationDuration: AppMotion.fast,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: minButtonSize,
          padding: buttonPadding,
          shape: buttonShape,
          textStyle: text.labelLarge,
          side: BorderSide(color: scheme.outline),
          animationDuration: AppMotion.fast,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: minButtonSize,
          padding: buttonPadding,
          shape: buttonShape,
          textStyle: text.labelLarge,
          animationDuration: AppMotion.fast,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: minButtonSize),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        contentPadding: const EdgeInsetsDirectional.symmetric(
          horizontal: AppSpacing.s16,
          vertical: AppSpacing.s16,
        ),
        border: inputBorder(scheme.outline),
        enabledBorder: inputBorder(scheme.outline),
        focusedBorder: inputBorder(scheme.primary, 2),
        errorBorder: inputBorder(scheme.error),
        focusedErrorBorder: inputBorder(scheme.error, 2),
        disabledBorder: inputBorder(scheme.outlineVariant),
        labelStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        hintStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        helperStyle: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        errorStyle: text.bodySmall?.copyWith(color: scheme.error),
        helperMaxLines: 3,
        errorMaxLines: 3,
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLowest,
        surfaceTintColor: scheme.surfaceTint,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadii.card,
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        modalBackgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: scheme.surfaceTint,
        showDragHandle: true,
        dragHandleColor: scheme.outline,
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.sheetTop),
        clipBehavior: Clip.antiAlias,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: scheme.surfaceTint,
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.xlAll),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: scheme.surfaceTint,
        indicatorColor: scheme.primaryContainer,
        elevation: 0,
        height: AppSpacing.s64 + AppSpacing.s8,
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>((Set<WidgetState> states) {
          final bool selected = states.contains(WidgetState.selected);
          return text.labelMedium?.copyWith(
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
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.mdAll),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    );
  }
}
