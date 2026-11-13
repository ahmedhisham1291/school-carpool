import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/app_button.dart';
import 'package:school_carpool/design/components/one_line_text.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Opens a bottom sheet with a title, content and an optional main action.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required String title,
  required Widget body,
  Widget? primaryAction,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (BuildContext sheetContext) =>
        AppSheet(title: title, body: body, primaryAction: primaryAction),
  );
}

/// Content of a bottom sheet. Scrolls when text is large and moves above the
/// keyboard.
class AppSheet extends StatelessWidget {
  const AppSheet({required this.title, required this.body, super.key, this.primaryAction});

  final String title;
  final Widget body;
  final Widget? primaryAction;

  @override
  Widget build(BuildContext context) {
    final Widget? action = primaryAction;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsetsDirectional.fromSTEB(
          AppSpacing.s24,
          0,
          AppSpacing.s24,
          AppSpacing.s32,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Semantics(header: true, child: OneLineText(title, style: context.text.titleLarge)),
            const SizedBox(height: AppSpacing.s8),
            DefaultTextStyle.merge(
              style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
              child: body,
            ),
            if (action != null) ...<Widget>[const SizedBox(height: AppSpacing.s24), action],
          ],
        ),
      ),
    );
  }
}

/// Asks before anything that cannot be undone. Returns true on confirm.
///
/// The title is one short question ("Leave the group?"); the body says
/// what will happen.
Future<bool> showConfirmDialog({
  required BuildContext context,
  required String title,
  required String body,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Semantics(header: true, child: OneLineText(title)),
      content: Text(body),
      actionsOverflowButtonSpacing: AppSpacing.s8,
      actions: <Widget>[
        AppButton(
          label: dialogContext.l10n.actionCancel,
          variant: AppButtonVariant.tertiary,
          onPressed: () => Navigator.of(dialogContext).pop(false),
        ),
        AppButton(
          label: confirmLabel,
          variant: destructive ? AppButtonVariant.danger : AppButtonVariant.primary,
          onPressed: () => Navigator.of(dialogContext).pop(true),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
