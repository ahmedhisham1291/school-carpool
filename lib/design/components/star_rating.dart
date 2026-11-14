import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// One to five stars (Prompt 11, F17 ratings). Each star is a 48 by 48
/// target with its own screen-reader label ("4 stars"); the chosen ones
/// are filled in the accent color. With a null [onChanged] it only shows
/// the value. Stars run in reading order, so they start on the right in
/// Arabic.
class AppStarRating extends StatelessWidget {
  const AppStarRating({required this.value, required this.onChanged, super.key});

  /// 0 (none chosen) to 5.
  final int value;
  final ValueChanged<int>? onChanged;

  static const int max = 5;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ValueChanged<int>? change = onChanged;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 1; i <= max; i++)
          Semantics(
            button: change != null,
            selected: i == value,
            label: l10n.starsLabel(i),
            excludeSemantics: true,
            child: SizedBox.square(
              dimension: AppSpacing.minTouchTarget,
              child: InkResponse(
                key: Key('stars.$i'),
                onTap: change == null ? null : () => change(i),
                radius: AppSpacing.s24,
                child: Icon(
                  i <= value ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: AppIconSize.lg,
                  color: i <= value ? context.colors.primary : context.colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
