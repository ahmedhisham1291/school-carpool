/// Removes personal data from text and structured data before it leaves the
/// phone for an outside service (Sentry today).
///
/// PRIVACY rule: never send phone numbers, national ID numbers, images,
/// coordinates or message text. The scrubber errs on the side of removing
/// too much: any long run of digits is treated as a phone or ID number.
abstract final class PiiScrubber {
  static const String redacted = '[redacted]';

  /// Keys whose values are always dropped, compared after lower-casing and
  /// removing `_`, `-` and spaces.
  static const Set<String> sensitiveKeys = <String>{
    // phone numbers
    'phone', 'phonenumber', 'mobile', 'msisdn', 'tel', 'whatsapp',
    // national ID and documents
    'nationalid', 'nid', 'idnumber', 'nationalidnumber', 'ssn', 'passport', 'licensenumber',
    'plate', 'platenumber',
    // coordinates and addresses
    'lat', 'lng', 'lon', 'latitude', 'longitude', 'coords', 'coordinates', 'location',
    'geo', 'geopoint', 'position', 'address', 'homeaddress', 'pickuppoint',
    // message text
    'text', 'message', 'messagetext', 'body', 'content', 'note', 'comment',
    // contact and names
    'email', 'firstname', 'lastname', 'fullname', 'displayname',
    // credentials
    'password', 'otp', 'code', 'token', 'idtoken', 'accesstoken', 'authorization', 'cookie',
    // images
    'image', 'photo', 'selfie', 'imagedata', 'bytes',
  };

  // Digits: ASCII, Arabic-Indic (٠-٩) and Extended Arabic-Indic (۰-۹).
  static const String _d = r'[0-9٠-٩۰-۹]';

  static final RegExp _email = RegExp(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}');

  /// "30.0444, 31.2357" or "30.0444 31.2357".
  static final RegExp _coordinatePair = RegExp(
    '-?$_d{1,3}[.٫]$_d{2,}\\s*[,،]?\\s*-?$_d{1,3}[.٫]$_d{2,}',
  );

  /// A single decimal with 4 or more decimals (one half of a coordinate).
  static final RegExp _preciseDecimal = RegExp('-?$_d{1,3}[.٫]$_d{4,}');

  /// 7 or more digits, optionally with +, 00 and separators: phone numbers
  /// (+20 10 1234 5678, 01012345678) and 14-digit national IDs.
  static final RegExp _longNumber = RegExp('(?:\\+|00)?$_d(?:[\\s\\-.]?$_d){6,}');

  /// Removes emails, coordinates and long numbers from [input].
  static String scrubString(String input) {
    if (input.isEmpty) {
      return input;
    }
    return input
        .replaceAll(_email, redacted)
        .replaceAll(_coordinatePair, redacted)
        .replaceAll(_preciseDecimal, redacted)
        .replaceAll(_longNumber, redacted);
  }

  static bool isSensitiveKey(String key) =>
      sensitiveKeys.contains(key.toLowerCase().replaceAll(RegExp(r'[_\-\s]'), ''));

  /// Scrubs any JSON-like value: strings are cleaned, maps lose sensitive
  /// keys, lists are cleaned item by item. Binary data is dropped.
  static Object? scrubValue(Object? value, {int depth = 0}) {
    if (depth > 8) {
      return redacted;
    }
    if (value == null || value is num || value is bool) {
      return value;
    }
    if (value is String) {
      return scrubString(value);
    }
    if (value is Map<dynamic, dynamic>) {
      return scrubMap(value, depth: depth + 1);
    }
    if (value is Iterable<dynamic>) {
      if (value is List<int> && value.length > 64) {
        return redacted; // raw bytes, for example an image
      }
      return value.map((Object? item) => scrubValue(item, depth: depth + 1)).toList();
    }
    return scrubString(value.toString());
  }

  static Map<String, dynamic> scrubMap(Map<dynamic, dynamic> map, {int depth = 0}) {
    final Map<String, dynamic> out = <String, dynamic>{};
    for (final MapEntry<dynamic, dynamic> entry in map.entries) {
      final String key = entry.key.toString();
      out[key] = isSensitiveKey(key) ? redacted : scrubValue(entry.value, depth: depth);
    }
    return out;
  }

  static Map<String, String> scrubStringMap(Map<String, String> map) => <String, String>{
    for (final MapEntry<String, String> e in map.entries)
      e.key: isSensitiveKey(e.key) ? redacted : scrubString(e.value),
  };
}
