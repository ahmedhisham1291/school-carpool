import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

enum AppBadgeTone { neutral, success, warning, error }

/// A small pill that names a status, for example "Verified" or "Under
/// review". Color is never the only signal: the text always says it.
class AppStatusBadge extends StatelessWidget {
  const AppStatusBadge({required this.label, super.key, this.tone = AppBadgeTone.neutral, this.icon});

  final String label;
  final AppBadgeTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    final AppColors app = context.appColors;
    final (Color background, Color foreground) = switch (tone) {
      AppBadgeTone.neutral => (colors.secondaryContainer, colors.onSecondaryContainer),
      AppBadgeTone.success => (app.successContainer, app.onSuccessContainer),
      AppBadgeTone.warning => (app.warningContainer, app.onWarningContainer),
      AppBadgeTone.error => (colors.errorContainer, colors.onErrorContainer),
    };
    final IconData? leading = icon;
    return DecoratedBox(
      decoration: BoxDecoration(color: background, borderRadius: AppRadii.pillAll),
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.s16 - AppSpacing.s4, vertical: AppSpacing.s4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (leading != null) ...<Widget>[
              ExcludeSemantics(child: Icon(leading, size: AppSpacing.s16, color: foreground)),
              const SizedBox(width: AppSpacing.s4),
            ],
            Flexible(
              child: Text(label, style: context.text.labelLarge?.copyWith(color: foreground)),
            ),
          ],
        ),
      ),
    );
  }
}
