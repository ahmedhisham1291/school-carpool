import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/one_line_text.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// A form field whose value is chosen on another screen (the school
/// picker): looks like an input, shows the choice or a placeholder, and
/// opens the chooser on tap. The label and value are one line each.
class AppPickerField extends StatelessWidget {
  const AppPickerField({
    required this.label,
    required this.placeholder,
    required this.onTap,
    super.key,
    this.value,
    this.helperText,
    this.prefixIcon,
  });

  final String label;

  /// Shown, quieter, while nothing is chosen.
  final String placeholder;
  final String? value;
  final String? helperText;
  final IconData? prefixIcon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final String? chosen = value;
    final IconData? icon = prefixIcon;
    final bool empty = chosen == null || chosen.isEmpty;
    return Semantics(
      button: true,
      label: label,
      value: empty ? placeholder : chosen,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadii.control,
        child: InputDecorator(
          decoration: InputDecoration(
            label: OneLineText(label),
            helperText: helperText,
            enabled: onTap != null,
            prefixIcon: icon == null ? null : Icon(icon),
            suffixIcon: const Icon(Icons.expand_more_rounded),
          ),
          child: OneLineText(
            empty ? placeholder : chosen,
            style: empty
                ? context.text.bodyLarge?.copyWith(color: context.colors.onSurfaceVariant)
                : context.text.bodyLarge,
          ),
        ),
      ),
    );
  }
}
