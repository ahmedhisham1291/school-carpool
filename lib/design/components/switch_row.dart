import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/one_line_text.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// A setting that is on or off: one-line title, optional subtitle (up to
/// two lines) and a switch at the end. The whole row toggles, is at least
/// 64 high, and reads as one control to screen readers.
class AppSwitchRow extends StatelessWidget {
  const AppSwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.leadingIcon,
  });

  final String title;
  final String? subtitle;
  final IconData? leadingIcon;
  final bool value;

  /// Null disables the row (for example while saving).
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    final String? sub = subtitle;
    final IconData? lead = leadingIcon;
    final ValueChanged<bool>? changed = onChanged;
    return MergeSemantics(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: changed == null ? null : () => changed(!value),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AppSpacing.s64),
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: AppSpacing.screenGutter,
                vertical: AppSpacing.s8,
              ),
              child: Row(
                children: <Widget>[
                  if (lead != null) ...<Widget>[
                    SizedBox.square(
                      dimension: AppSpacing.iconTile,
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: colors.secondaryContainer, borderRadius: AppRadii.control),
                        child: Icon(lead, color: colors.onSecondaryContainer, size: AppIconSize.md),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s16),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        OneLineText(title, style: context.text.titleSmall),
                        if (sub != null)
                          Text(
                            sub,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s8),
                  Switch(value: value, onChanged: changed),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
