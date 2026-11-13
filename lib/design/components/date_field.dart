import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// A date chosen from the calendar (no typing), for expiry dates. Shows
/// the date in the app's language and an error that says how to fix it.
class AppDateField extends StatelessWidget {
  const AppDateField({
    required this.label,
    required this.value,
    required this.firstDate,
    required this.lastDate,
    required this.onChanged,
    super.key,
    this.helperText,
    this.errorText,
    this.placeholder,
  });

  final String label;
  final DateTime? value;
  final DateTime firstDate;
  final DateTime lastDate;
  final ValueChanged<DateTime>? onChanged;
  final String? helperText;
  final String? errorText;

  /// Shown while no date is chosen, for example "Choose a date".
  final String? placeholder;

  Future<void> _pick(BuildContext context) async {
    final ValueChanged<DateTime>? changed = onChanged;
    if (changed == null) {
      return;
    }
    final DateTime? current = value;
    final DateTime initial = current == null || current.isBefore(firstDate) || current.isAfter(lastDate)
        ? firstDate
        : current;
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: firstDate,
      lastDate: lastDate,
      initialEntryMode: DatePickerEntryMode.calendarOnly,
    );
    if (picked != null) {
      changed(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final DateTime? date = value;
    final String text = date == null
        ? (placeholder ?? '')
        : MaterialLocalizations.of(context).formatMediumDate(date);
    return Semantics(
      button: true,
      child: InkWell(
        borderRadius: AppRadii.control,
        onTap: onChanged == null ? null : () => unawaited(_pick(context)),
        child: InputDecorator(
          isEmpty: date == null && placeholder == null,
          decoration: InputDecoration(
            labelText: label,
            helperText: helperText,
            errorText: errorText,
            enabled: onChanged != null,
            prefixIcon: const Icon(Icons.event_outlined),
          ),
          child: Text(
            text,
            style: context.text.bodyLarge?.copyWith(
              color: date == null ? context.colors.onSurfaceVariant : null,
            ),
          ),
        ),
      ),
    );
  }
}
