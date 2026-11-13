import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/app_button.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Shared layout for full-screen empty, error and offline states: an icon,
/// a title, a line that says what to do, and at most one action.
///
/// Scrolls when text is scaled up, so nothing is cut off at 200 percent.
class AppStateView extends StatelessWidget {
  const AppStateView({
    required this.icon,
    required this.title,
    required this.body,
    super.key,
    this.actionLabel,
    this.onAction,
    this.tone = AppStateTone.neutral,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;
  final AppStateTone tone;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    final (Color background, Color foreground) = switch (tone) {
      AppStateTone.neutral => (colors.secondaryContainer, colors.onSecondaryContainer),
      AppStateTone.error => (colors.errorContainer, colors.onErrorContainer),
      AppStateTone.warning => (
        context.appColors.warningContainer,
        context.appColors.onWarningContainer,
      ),
    };
    final String? label = actionLabel;

    return Center(
      child: SingleChildScrollView(
        padding: AppSpacing.screenPadding,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppSpacing.maxContentWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox.square(
                dimension: AppSpacing.s64,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: background, shape: BoxShape.circle),
                  child: Icon(icon, color: foreground, size: AppSpacing.s32),
                ),
              ),
              const SizedBox(height: AppSpacing.s24),
              Semantics(
                header: true,
                child: Text(title, style: context.text.titleLarge, textAlign: TextAlign.center),
              ),
              const SizedBox(height: AppSpacing.s8),
              Text(
                body,
                style: context.text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              if (label != null && onAction != null) ...<Widget>[
                const SizedBox(height: AppSpacing.s24),
                AppButton(label: label, onPressed: onAction),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

enum AppStateTone { neutral, error, warning }

/// Nothing to show yet.
class EmptyStateView extends StatelessWidget {
  const EmptyStateView({
    super.key,
    this.icon = Icons.inbox_outlined,
    this.title,
    this.body,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String? title;
  final String? body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => AppStateView(
    icon: icon,
    title: title ?? context.l10n.stateEmptyTitle,
    body: body ?? context.l10n.stateEmptyBody,
    actionLabel: actionLabel,
    onAction: onAction,
  );
}

/// Loading failed. Says what happened and offers a retry.
class ErrorStateView extends StatelessWidget {
  const ErrorStateView({super.key, this.title, this.body, this.onRetry});

  final String? title;
  final String? body;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => AppStateView(
    icon: Icons.error_outline_rounded,
    title: title ?? context.l10n.stateErrorTitle,
    body: body ?? context.l10n.stateErrorBody,
    actionLabel: context.l10n.actionRetry,
    onAction: onRetry,
    tone: AppStateTone.error,
  );
}

/// No connection. Content that is cached stays visible elsewhere; this view
/// is for screens that have nothing cached yet.
class OfflineStateView extends StatelessWidget {
  const OfflineStateView({super.key, this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => AppStateView(
    icon: Icons.wifi_off_rounded,
    title: context.l10n.stateOfflineTitle,
    body: context.l10n.stateOfflineBody,
    actionLabel: context.l10n.actionRetry,
    onAction: onRetry,
    tone: AppStateTone.warning,
  );
}
