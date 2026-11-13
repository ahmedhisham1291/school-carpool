import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Progress of a form split into short steps: "Step 2 of 4" and a bar.
/// Screen readers hear the text once; the bar is decoration.
class AppStepProgress extends StatelessWidget {
  const AppStepProgress({required this.current, required this.total, super.key})
    : assert(current >= 1 && current <= total, 'current must be within 1..total');

  /// 1-based step number.
  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    final String label = context.l10n.stepProgress(current, total);
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: context.text.labelLarge?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.s8),
          ClipRRect(
            borderRadius: AppRadii.pillAll,
            child: LinearProgressIndicator(
              value: current / total,
              minHeight: AppSpacing.s8,
              backgroundColor: context.colors.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}
