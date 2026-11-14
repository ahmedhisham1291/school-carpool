import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/app_button.dart';
import 'package:school_carpool/design/components/one_line_text.dart';
import 'package:school_carpool/design/components/state_views.dart';
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
/// one-line title, one short sentence and one action. [AppStateTone.warning]
/// (Prompt 13) is the calmer version for something to fix soon, such as
/// location being off before a driving day.
class AppAlertBanner extends StatelessWidget {
  const AppAlertBanner({
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onAction,
    super.key,
    this.icon = Icons.warning_amber_rounded,
    this.tone = AppStateTone.error,
  });

  final String title;
  final String body;
  final String actionLabel;
  final VoidCallback onAction;
  final IconData icon;
  final AppStateTone tone;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = context.colors;
    final (Color container, Color onContainer, Color edge) = switch (tone) {
      AppStateTone.warning => (context.appColors.warningContainer, context.appColors.onWarningContainer, context.appColors.warning),
      AppStateTone.error || AppStateTone.neutral => (scheme.errorContainer, scheme.onErrorContainer, scheme.error),
    };
    return Semantics(
      container: true,
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.s16, AppSpacing.s8, AppSpacing.s16, AppSpacing.s8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: container,
            borderRadius: AppRadii.card,
            border: Border.all(color: edge.withValues(alpha: AppOpacity.hover)),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.all(AppSpacing.s16),
            child: Row(
              children: <Widget>[
                Icon(icon, color: onContainer, size: AppIconSize.md),
                const SizedBox(width: AppSpacing.s16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      OneLineText(title, style: context.text.titleSmall?.copyWith(color: onContainer)),
                      Text(
                        body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.bodyMedium?.copyWith(color: onContainer),
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
