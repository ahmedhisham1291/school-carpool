import 'package:flutter/services.dart';

/// Keeps only digits and turns Arabic-Indic (٠-٩) and Persian (۰-۹) digits
/// into 0-9, so a parent typing on an Arabic keyboard gets the same result.
class DigitsInputFormatter extends TextInputFormatter {
  const DigitsInputFormatter({this.maxDigits});

  /// Stops input after this many digits, when set.
  final int? maxDigits;

  /// Converts Eastern digits to 0-9 and drops every other character.
  static String normalize(String input) {
    final StringBuffer out = StringBuffer();
    for (final int rune in input.runes) {
      if (rune >= 0x30 && rune <= 0x39) {
        out.writeCharCode(rune);
      } else if (rune >= 0x0660 && rune <= 0x0669) {
        out.writeCharCode(0x30 + rune - 0x0660);
      } else if (rune >= 0x06F0 && rune <= 0x06F9) {
        out.writeCharCode(0x30 + rune - 0x06F0);
      }
    }
    return out.toString();
  }

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    String digits = normalize(newValue.text);
    final int? max = maxDigits;
    if (max != null && digits.length > max) {
      digits = digits.substring(0, max);
    }
    if (digits == newValue.text) {
      return newValue;
    }
    return TextEditingValue(
      text: digits,
      selection: TextSelection.collapsed(offset: digits.length),
    );
  }
}
