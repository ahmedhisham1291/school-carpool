import 'package:school_carpool/design/bidi.dart';
import 'package:school_carpool/design/components/digits_input_formatter.dart';

/// Egyptian mobile numbers, checked as the parent types. The server runs
/// the same rules (functions/src/auth/phone.ts) and has the last word.
///
/// Accepted: 01012345678, 1012345678, +201012345678, 00201012345678, with
/// spaces, dashes or Arabic digits. Mobile prefixes: 010, 011, 012, 015.
abstract final class EgyptPhone {
  static final RegExp _mobile = RegExp(r'^1[0125]\d{8}$');

  /// The number as +201XXXXXXXXX, or null when it is not an Egyptian mobile.
  static String? toE164(String input) {
    if (input.length > 32) {
      return null;
    }
    String digits = DigitsInputFormatter.normalize(input);
    if (digits.startsWith('0020')) {
      digits = digits.substring(4);
    } else if (digits.startsWith('20') && digits.length == 12) {
      digits = digits.substring(2);
    } else if (digits.startsWith('0')) {
      digits = digits.substring(1);
    }
    return _mobile.hasMatch(digits) ? '+20$digits' : null;
  }

  static bool isValid(String input) => toE164(input) != null;

  /// Display form, for example +20 10 1234 5678. Wrapped in left-to-right
  /// isolate marks so it reads correctly inside Arabic sentences.
  static String display(String e164) {
    final String local = e164.startsWith('+20') ? e164.substring(3) : e164;
    if (local.length != 10) {
      return ltrIsolate(e164);
    }
    return ltrIsolate('+20 ${local.substring(0, 2)} ${local.substring(2, 6)} ${local.substring(6)}');
  }
}
