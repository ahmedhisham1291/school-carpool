import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/one_line_text.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// A checkbox with a label that wraps, optional helper text and an optional
/// link (for example "Read" to open a document). The whole row toggles the
/// box and is at least 48 high.
///
/// The label is a short statement ("I accept the privacy policy") and may
/// take two lines on a narrow phone; the link stays on one line.
class AppCheckRow extends StatelessWidget {
  const AppCheckRow({
    required this.label,
    required this.value,
    required this.onChanged,
    super.key,
    this.helperText,
    this.actionLabel,
    this.onAction,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? helperText;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final String? helper = helperText;
    final String? action = actionLabel;
    final ValueChanged<bool>? changed = onChanged;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: MergeSemantics(
            child: InkWell(
              borderRadius: AppRadii.control,
              onTap: changed == null ? null : () => changed(!value),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: AppSpacing.minTouchTarget),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Checkbox(
                      value: value,
                      onChanged: changed == null ? null : (bool? next) => changed(next ?? false),
                    ),
                    const SizedBox(width: AppSpacing.s8),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsetsDirectional.symmetric(vertical: AppSpacing.s8 + AppSpacing.s4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(label, style: context.text.bodyMedium),
                            if (helper != null)
                              Text(
                                helper,
                                style: context.text.bodyMedium?.copyWith(
                                  color: context.colors.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (action != null && onAction != null)
          TextButton(onPressed: onAction, child: OneLineText(action)),
      ],
    );
  }
}
