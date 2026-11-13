import 'package:school_carpool/design/components/digits_input_formatter.dart';

/// Egyptian national ID numbers (14 digits), checked as the parent types.
/// Same rules as functions/src/verification/national_id.ts; the server has
/// the last word and stores only a keyed hash of the number.
///
/// Layout: century (2 = 1900s, 3 = 2000s), birth date YYMMDD, governorate,
/// sequence, check digit. The check digit algorithm is not public.
abstract final class EgyptNationalId {
  static const int length = 14;

  /// Parents are adults.
  static const int minParentAge = 18;

  static const Set<String> _governorates = <String>{
    '01', '02', '03', '04', '11', '12', '13', '14', '15', '16', '17', '18', '19', //
    '21', '22', '23', '24', '25', '26', '27', '28', '29', '31', '32', '33', '34', '35', '88',
  };

  /// Why a number is not accepted, or null when it is.
  static NationalIdProblem? check(String input, DateTime today) {
    final String digits = DigitsInputFormatter.normalize(input);
    if (digits.length != length) {
      return NationalIdProblem.length;
    }
    if (digits[0] != '2' && digits[0] != '3') {
      return NationalIdProblem.invalid;
    }
    final int year = (digits[0] == '2' ? 1900 : 2000) + int.parse(digits.substring(1, 3));
    final int month = int.parse(digits.substring(3, 5));
    final int day = int.parse(digits.substring(5, 7));
    final DateTime birth = DateTime.utc(year, month, day);
    if (month < 1 || month > 12 || day < 1 || birth.month != month || birth.day != day) {
      return NationalIdProblem.invalid;
    }
    if (!_governorates.contains(digits.substring(7, 9))) {
      return NationalIdProblem.invalid;
    }
    final DateTime adultFrom = DateTime.utc(today.year - minParentAge, today.month, today.day);
    if (birth.isAfter(adultFrom)) {
      return NationalIdProblem.underAge;
    }
    return null;
  }

  static bool isValid(String input, DateTime today) => check(input, today) == null;

  /// The 14 ASCII digits, for sending to the server.
  static String normalize(String input) => DigitsInputFormatter.normalize(input);
}

enum NationalIdProblem { length, invalid, underAge }
