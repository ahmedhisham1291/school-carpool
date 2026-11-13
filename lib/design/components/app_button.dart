import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/one_line_text.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

enum AppButtonVariant {
  /// The one main action of a screen. Use at most one per screen.
  primary,

  /// Other actions next to the primary one.
  secondary,

  /// Low-emphasis actions (links, "view details").
  tertiary,

  /// Actions that cannot be undone. Always ask for confirmation first.
  danger,
}

enum AppButtonSize {
  /// 52 dp high.
  regular,

  /// 64 dp minimum height and larger text, for driver screens.
  large,
}

/// The only button used in screens.
///
/// The label is always one line (DESIGN rules): write two or three words,
/// such as "Create carpool". At very large text sizes the label shrinks to
/// fit rather than hiding words behind an ellipsis. Full width ([expand]) is the normal layout for
/// the one primary action on phones. While [loading] the button is disabled
/// and announces "loading".
class AppButton extends StatelessWidget {
  const AppButton({
    required this.label,
    required this.onPressed,
    super.key,
    this.variant = AppButtonVariant.primary,
    this.size = AppButtonSize.regular,
    this.icon,
    this.loading = false,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final AppButtonSize size;
  final IconData? icon;
  final bool loading;

  /// Fill the available width (typical for the primary action on phones).
  final bool expand;

  static const double _spinnerSize = AppIconSize.sm;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    final bool large = size == AppButtonSize.large;
    final double minHeight = large ? AppSpacing.driverTouchTarget : AppSpacing.buttonHeight;
    final VoidCallback? handler = loading ? null : onPressed;

    ButtonStyle style = ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(Size(minHeight, minHeight)),
      textStyle: large ? WidgetStatePropertyAll<TextStyle?>(context.text.titleMedium) : null,
    );
    if (variant == AppButtonVariant.danger) {
      style = style.merge(
        FilledButton.styleFrom(backgroundColor: colors.error, foregroundColor: colors.onError),
      );
    }

    final Widget content = _ButtonContent(
      label: label,
      icon: icon,
      loading: loading,
      iconSize: large ? AppIconSize.lg : AppIconSize.sm,
    );

    final Widget button = switch (variant) {
      AppButtonVariant.primary || AppButtonVariant.danger => FilledButton(
        onPressed: handler,
        style: style,
        child: content,
      ),
      AppButtonVariant.secondary => OutlinedButton(onPressed: handler, style: style, child: content),
      AppButtonVariant.tertiary => TextButton(onPressed: handler, style: style, child: content),
    };

    final Widget sized = expand ? SizedBox(width: double.infinity, child: button) : button;
    if (!loading) {
      return sized;
    }
    return Semantics(
      button: true,
      enabled: false,
      label: context.l10n.buttonLoadingLabel(label),
      excludeSemantics: true,
      child: sized,
    );
  }
}

class _ButtonContent extends StatelessWidget {
  const _ButtonContent({
    required this.label,
    required this.icon,
    required this.loading,
    required this.iconSize,
  });

  final String label;
  final IconData? icon;
  final bool loading;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final Widget text = Flexible(
      child: OneLineText(label, textAlign: TextAlign.center, scaleDown: true),
    );
    final Widget leading;
    if (loading) {
      leading = const SizedBox.square(
        dimension: AppButton._spinnerSize,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (icon != null) {
      leading = Icon(icon, size: iconSize);
    } else {
      return OneLineText(label, textAlign: TextAlign.center, scaleDown: true);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[leading, const SizedBox(width: AppSpacing.s8), text],
    );
  }
}
