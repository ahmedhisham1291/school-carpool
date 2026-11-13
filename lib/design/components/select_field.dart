import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/one_line_text.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// One choice from a short fixed list (grade, number of seats).
class AppSelectField<T> extends StatelessWidget {
  const AppSelectField({
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
    super.key,
    this.helperText,
  });

  final String label;

  /// Values and their labels, in display order.
  final List<(T, String)> options;
  final T? value;
  final ValueChanged<T>? onChanged;
  final String? helperText;

  @override
  Widget build(BuildContext context) {
    final ValueChanged<T>? changed = onChanged;
    return DropdownButtonFormField<T>(
      // Rebuilt with the new value, so the field shows what the state holds.
      key: ValueKey<T?>(value),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(label: OneLineText(label), helperText: helperText),
      style: context.text.bodyLarge,
      items: <DropdownMenuItem<T>>[
        for (final (T option, String text) in options) DropdownMenuItem<T>(value: option, child: OneLineText(text)),
      ],
      onChanged: changed == null
          ? null
          : (T? next) {
              if (next != null) {
                changed(next);
              }
            },
    );
  }
}
