/// Text normalization for matching school names typed in Arabic or English.
///
/// Same rules as functions/src/text/normalize.ts and
/// tools/import_schools/schools_import.py (the three are tested with the
/// same cases): Arabic-Indic digits become 0-9; Latin letters are
/// lower-cased; Arabic diacritics and the tatweel are removed; alef forms
/// (hamza above or below, madda, wasla) become a bare alef; alef maqsura
/// becomes yaa; taa marbuta becomes haa; anything that is not a letter or
/// digit becomes a space; spaces are collapsed. (Dart has no NFKC; the
/// server and the index normalize stored names fully, and typed text
/// rarely holds presentation forms.)
String normalizeText(String input) {
  final StringBuffer out = StringBuffer();
  for (final int rune in input.toLowerCase().runes) {
    if (rune >= 0x0660 && rune <= 0x0669) {
      out.writeCharCode(rune - 0x0660 + 0x30);
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      out.writeCharCode(rune - 0x06F0 + 0x30);
    } else if ((rune >= 0x064B && rune <= 0x0652) || rune == 0x0670 || rune == 0x0640) {
      // Diacritics, dagger alef, tatweel: dropped.
    } else if (rune == 0x0622 || rune == 0x0623 || rune == 0x0625 || rune == 0x0671) {
      out.writeCharCode(0x0627);
    } else if (rune == 0x0649) {
      out.writeCharCode(0x064A);
    } else if (rune == 0x0629) {
      out.writeCharCode(0x0647);
    } else if (_isLetterOrDigit(rune)) {
      out.writeCharCode(rune);
    } else {
      out.write(' ');
    }
  }
  return out.toString().trim().split(RegExp(r'\s+')).where((String w) => w.isNotEmpty).join(' ');
}

final RegExp _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

bool _isLetterOrDigit(int rune) => _letterOrDigit.hasMatch(String.fromCharCode(rune));

/// True when [a] and [b] differ by at most one letter (added, removed or
/// changed).
bool withinOneEdit(String a, String b) {
  if (a == b) {
    return true;
  }
  if ((a.length - b.length).abs() > 1) {
    return false;
  }
  final String short = a.length <= b.length ? a : b;
  final String long = a.length <= b.length ? b : a;
  int i = 0;
  int j = 0;
  bool edited = false;
  while (i < short.length && j < long.length) {
    if (short[i] == long[j]) {
      i++;
      j++;
      continue;
    }
    if (edited) {
      return false;
    }
    edited = true;
    if (short.length == long.length) {
      i++;
    }
    j++;
  }
  return true;
}
