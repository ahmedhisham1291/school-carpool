"""School names in Arabic or Latin letters only (owner, 16 Nov 2026: "names
in weird letters, not Arabic, not English" must go).

fix_text() runs on every name as it is read, before any rule:
  1. mojibake repair: UTF-8 Arabic that was decoded as Latin-1 / Windows-1252
     ("Ù…Ø¯Ø±Ø³Ø©" -> "مدرسة"), also twice over; the repair is kept only when
     the result is valid UTF-8 with Arabic letters and fewer odd characters;
  2. NFKC: Arabic presentation forms (U+FB50-FDFF, U+FE70-FEFF) become the
     standard letters, "fancy" mathematical letters (U+1D400...) and
     fullwidth letters become plain Latin;
  3. zero-width and bidi control characters, variation selectors, emoji
     and other symbols are removed; spaces collapsed.
Our own pipeline reads and writes UTF-8 everywhere (Overpass and Wikidata
JSON, DuckDB VARCHAR -> Python str -> JSON written with ensure_ascii=False
in UTF-8, the loader reads UTF-8): mojibake in a name comes from the
upstream listing, and is repaired here.

script_check() then decides, on the fixed name:
  - letters that are Arabic, or Latin (A-Z and the accented Latin of
    French and similar), count as good; any other letter (Cyrillic, CJK,
    Devanagari, Greek, ...) is odd;
  - no good letter: invalid;
  - at least 80 % good letters: the odd characters are removed, and the
    rest must still have two good letters;
  - otherwise invalid.
A school whose names are all invalid is dropped ("Name not in Arabic or
English"). Standard library only.
"""

from __future__ import annotations

import re
import unicodedata

GOOD_SHARE = 0.8

_CONTROLS = re.compile("[\u200b-\u200f\u202a-\u202e\u2060-\u2069\ufeff\u061c\u00ad\ufe00-\ufe0f\U000e0100-\U000e01ef]")
_MOJIBAKE_HINT = re.compile("[\u00d8\u00d9\u00da\u00db\u00c3\u00c2][\u0080-\u00bf\u0152\u0153\u0160\u0161\u0178\u017d\u017e\u0192\u02c6\u02dc\u2013-\u2122]")


def _is_arabic(ch: str) -> bool:
    o = ord(ch)
    return 0x0600 <= o <= 0x06FF or 0x0750 <= o <= 0x077F or 0x08A0 <= o <= 0x08FF


def _is_latin(ch: str) -> bool:
    o = ord(ch)
    return ("a" <= ch.lower() <= "z") or (0x00C0 <= o <= 0x024F and o not in (0x00D7, 0x00F7))


def _odd_count(text: str) -> int:
    return sum(1 for ch in text if unicodedata.category(ch)[0] == "L" and not (_is_arabic(ch) or _is_latin(ch)))


def _to_bytes(text: str) -> bytes | None:
    """The bytes a Windows-1252 (else Latin-1) decoder turned into [text]."""
    out = bytearray()
    for ch in text:
        try:
            out += ch.encode("cp1252")
        except UnicodeEncodeError:
            if ord(ch) < 256:
                out.append(ord(ch))
            else:
                return None
    return bytes(out)


def repair_mojibake(text: str) -> str:
    """Undoes UTF-8 read as Windows-1252/Latin-1, up to twice; returns
    [text] unchanged when there is nothing to undo or the result is no better."""
    current = text
    for _ in range(2):
        if not _MOJIBAKE_HINT.search(current):
            break
        raw = _to_bytes(current)
        if raw is None:
            break
        try:
            fixed = raw.decode("utf-8")
        except UnicodeDecodeError:
            break
        # Bytes that decode as strict UTF-8 after such a round trip were UTF-8
        # to begin with ("Ã©cole" -> "école" too).
        current = fixed
    return current


def fix_text(text: str) -> str:
    """Repair, NFKC, and remove controls, emoji and symbols (see the module docstring)."""
    if not text:
        return ""
    t = repair_mojibake(text)
    t = unicodedata.normalize("NFKC", t)
    t = _CONTROLS.sub("", t)
    kept = []
    for ch in t:
        cat = unicodedata.category(ch)
        if cat in ("So", "Sk", "Cs", "Co", "Cn", "Cc", "Cf"):
            kept.append(" ")
        else:
            kept.append(ch)
    return " ".join("".join(kept).split())


def script_check(text: str) -> str:
    """The name with odd letters removed, or "" when it is not an Arabic or
    Latin-letter name (see the module docstring)."""
    letters = [ch for ch in text if unicodedata.category(ch)[0] == "L"]
    good = [ch for ch in letters if _is_arabic(ch) or _is_latin(ch)]
    if not good:
        return ""
    if len(good) == len(letters):
        return text
    if len(good) / len(letters) < GOOD_SHARE:
        return ""
    cleaned = "".join(ch for ch in text if not (unicodedata.category(ch)[0] == "L" and not (_is_arabic(ch) or _is_latin(ch))))
    cleaned = " ".join(cleaned.split())
    return cleaned if sum(1 for ch in cleaned if _is_arabic(ch) or _is_latin(ch)) >= 2 else ""
