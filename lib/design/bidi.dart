/// Text that must read left to right inside Arabic sentences (phone
/// numbers, emails, codes). Wraps [text] in a left-to-right isolate
/// (U+2066 ... U+2069). The marks are built from code points so the source
/// never holds invisible direction characters.
String ltrIsolate(String text) =>
    '${String.fromCharCode(0x2066)}$text${String.fromCharCode(0x2069)}';
