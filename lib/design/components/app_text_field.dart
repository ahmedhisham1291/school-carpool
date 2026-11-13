import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// Text input with a visible label, helper text and an error that says how
/// to fix the problem. Validates as the parent types (after the first edit).
class AppTextField extends StatelessWidget {
  const AppTextField({
    required this.label,
    super.key,
    this.controller,
    this.initialValue,
    this.helperText,
    this.hintText,
    this.errorText,
    this.prefixIcon,
    this.validator,
    this.onChanged,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.enabled = true,
    this.obscureText = false,
    this.maxLength,
  });

  final String label;
  final TextEditingController? controller;
  final String? initialValue;
  final String? helperText;
  final String? hintText;

  /// Error set from outside (for example a server answer). Field validation
  /// errors come from [validator].
  final String? errorText;
  final IconData? prefixIcon;
  final FormFieldValidator<String>? validator;
  final ValueChanged<String>? onChanged;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final bool enabled;
  final bool obscureText;
  final int? maxLength;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      initialValue: controller == null ? initialValue : null,
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        hintText: hintText,
        errorText: errorText,
        prefixIcon: prefixIcon == null ? null : Icon(prefixIcon),
      ),
      style: context.text.bodyLarge,
      validator: validator,
      onChanged: onChanged,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      autofillHints: autofillHints,
      enabled: enabled,
      obscureText: obscureText,
      maxLength: maxLength,
    );
  }
}
