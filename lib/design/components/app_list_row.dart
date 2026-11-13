import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/one_line_text.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// One row of a list: optional leading icon, title, subtitle and trailing
/// widget. Tappable rows show a chevron that points the reading direction
/// (it mirrors automatically in Arabic).
///
/// The title is always one line; the subtitle may use two.
class AppListRow extends StatelessWidget {
  const AppListRow({
    required this.title,
    super.key,
    this.subtitle,
    this.leadingIcon,
    this.trailing,
    this.onTap,
    this.showChevron = true,
  });

  final String title;
  final String? subtitle;
  final IconData? leadingIcon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    final String? sub = subtitle;
    final Widget? trail = trailing;
    final IconData? lead = leadingIcon;

    final Widget row = ConstrainedBox(
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
                  decoration: BoxDecoration(
                    color: colors.secondaryContainer,
                    borderRadius: AppRadii.control,
                  ),
                  child: Icon(lead, color: colors.onSecondaryContainer, size: AppSpacing.s24),
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
            if (trail != null) ...<Widget>[const SizedBox(width: AppSpacing.s8), trail],
            if (onTap != null && showChevron) ...<Widget>[
              const SizedBox(width: AppSpacing.s8),
              Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
            ],
          ],
        ),
      ),
    );

    if (onTap == null) {
      return row;
    }
    return Material(
      type: MaterialType.transparency,
      child: InkWell(onTap: onTap, child: row),
    );
  }
}
