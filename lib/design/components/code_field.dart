import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/digits_input_formatter.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// Entry for a one-time code: one large, centred, left-to-right field that
/// accepts Latin and Arabic digits, offers the code from the keyboard
/// (iOS "From Messages" autofill) and calls [onCompleted] when all digits
/// are in.
class AppCodeField extends StatelessWidget {
  const AppCodeField({
    required this.label,
    required this.controller,
    super.key,
    this.length = 6,
    this.helperText,
    this.errorText,
    this.onCompleted,
    this.enabled = true,
    this.autofocus = false,
  });

  final String label;
  final TextEditingController controller;
  final int length;
  final String? helperText;
  final String? errorText;
  final ValueChanged<String>? onCompleted;
  final bool enabled;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      autofocus: autofocus,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.done,
      autofillHints: const <String>[AutofillHints.oneTimeCode],
      // Digits read left to right in Arabic too.
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      style: context.text.headlineMedium,
      inputFormatters: <TextInputFormatter>[DigitsInputFormatter(maxDigits: length)],
      decoration: InputDecoration(labelText: label, helperText: helperText, errorText: errorText),
      onChanged: (String value) {
        if (value.length == length) {
          onCompleted?.call(value);
        }
      },
    );
  }
}
