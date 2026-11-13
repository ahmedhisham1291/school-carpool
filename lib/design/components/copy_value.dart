import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// A short code shown large (for example the parent ID) with a copy button.
/// Copying confirms with a snack bar. The value reads left to right in both
/// languages.
class AppCopyValue extends StatelessWidget {
  const AppCopyValue({required this.label, required this.value, super.key, this.helperText});

  final String label;
  final String value;
  final String? helperText;

  Future<void> _copy(BuildContext context) async {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
    final String done = context.l10n.copiedToClipboard;
    await Clipboard.setData(ClipboardData(text: value));
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(done)));
  }

  @override
  Widget build(BuildContext context) {
    final String? helper = helperText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: context.text.labelLarge?.copyWith(color: context.colors.onSurfaceVariant)),
        const SizedBox(height: AppSpacing.s4),
        Row(
          children: <Widget>[
            Expanded(
              child: SelectableText(
                value,
                textDirection: TextDirection.ltr,
                style: context.text.headlineMedium?.copyWith(color: context.colors.primary),
              ),
            ),
            IconButton.filledTonal(
              key: const Key('copyValue.button'),
              tooltip: context.l10n.copyTooltip(label),
              icon: const Icon(Icons.copy_rounded),
              onPressed: () => unawaited(_copy(context)),
            ),
          ],
        ),
        if (helper != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s4),
          Text(helper, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
        ],
      ],
    );
  }
}
