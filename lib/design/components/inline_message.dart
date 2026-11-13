import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/state_views.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// A short message inside a form: what went wrong and what to do, or a
/// helpful note. Used for server errors and the offline state of form
/// screens (full-screen states use [AppStateView]). Announced to screen
/// readers when it appears.
class AppInlineMessage extends StatelessWidget {
  const AppInlineMessage({
    required this.message,
    super.key,
    this.tone = AppStateTone.neutral,
    this.icon,
  });

  final String message;
  final AppStateTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    final (Color background, Color foreground, IconData defaultIcon) = switch (tone) {
      AppStateTone.neutral => (
        colors.secondaryContainer,
        colors.onSecondaryContainer,
        Icons.info_outline_rounded,
      ),
      AppStateTone.error => (
        colors.errorContainer,
        colors.onErrorContainer,
        Icons.error_outline_rounded,
      ),
      AppStateTone.warning => (
        context.appColors.warningContainer,
        context.appColors.onWarningContainer,
        Icons.wifi_off_rounded,
      ),
    };
    return Semantics(
      liveRegion: true,
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(color: background, borderRadius: AppRadii.control),
        child: Padding(
          padding: AppSpacing.cardPadding,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ExcludeSemantics(child: Icon(icon ?? defaultIcon, color: foreground)),
              const SizedBox(width: AppSpacing.s16),
              Expanded(
                child: Text(message, style: context.text.bodyMedium?.copyWith(color: foreground)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
