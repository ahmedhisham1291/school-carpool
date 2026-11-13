import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/one_line_text.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// A pill that filters or picks one option ("Morning", "Afternoon").
///
/// Selected chips get the soft teal wash; the label is always one line.
/// Pass a null [onSelected] to show the chip disabled.
class AppChip extends StatelessWidget {
  const AppChip({
    required this.label,
    super.key,
    this.selected = false,
    this.onSelected,
    this.icon,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    final Color foreground = selected ? colors.onPrimaryContainer : colors.onSurface;
    final IconData? leading = icon;
    return FilterChip(
      label: OneLineText(label),
      selected: selected,
      onSelected: onSelected,
      showCheckmark: false,
      avatar: leading == null ? null : Icon(leading, size: AppIconSize.sm, color: foreground),
      labelStyle: context.text.labelLarge?.copyWith(color: foreground),
      side: BorderSide(color: selected ? colors.primary : colors.outline),
      shape: const StadiumBorder(),
    );
  }
}
