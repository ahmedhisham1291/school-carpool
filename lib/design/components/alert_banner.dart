import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/app_button.dart';
import 'package:school_carpool/design/components/one_line_text.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// A small dot that marks something unread (a notification row, the
/// Alerts tab). Color is never the only signal: pair it with a label for
/// screen readers ([semanticLabel]).
class AppUnreadDot extends StatelessWidget {
  const AppUnreadDot({super.key, this.semanticLabel});

  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticLabel,
    child: SizedBox.square(
      dimension: AppSpacing.s8,
      child: DecoratedBox(
        decoration: BoxDecoration(color: context.colors.primary, shape: BoxShape.circle),
      ),
    ),
  );
}

/// An urgent message pinned above the tabs until it is opened (critical
/// alerts, spec section 11): error-toned card with a hairline border, a
/// one-line title, one short sentence and one action.
class AppAlertBanner extends StatelessWidget {
  const AppAlertBanner({
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onAction,
    super.key,
    this.icon = Icons.warning_amber_rounded,
  });

  final String title;
  final String body;
  final String actionLabel;
  final VoidCallback onAction;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.s16, AppSpacing.s8, AppSpacing.s16, AppSpacing.s8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.errorContainer,
            borderRadius: AppRadii.card,
            border: Border.all(color: colors.error.withValues(alpha: AppOpacity.hover)),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.all(AppSpacing.s16),
            child: Row(
              children: <Widget>[
                Icon(icon, color: colors.onErrorContainer, size: AppIconSize.md),
                const SizedBox(width: AppSpacing.s16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      OneLineText(title, style: context.text.titleSmall?.copyWith(color: colors.onErrorContainer)),
                      Text(
                        body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.bodyMedium?.copyWith(color: colors.onErrorContainer),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.s8),
                AppButton(label: actionLabel, onPressed: onAction, variant: AppButtonVariant.secondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
