"""Automatic de-duplication of the schools list (owner decision, 16 Nov 2026:
no manual duplicate review; the list must be clean).

Two entries with a pin are the same school when one of these rules holds
(checked in this order; distances are between the two pins):

  same_name_500m     the same core name, at most 500 m apart;
  similar_300m       core names at least 85 % alike (token set, one slip
                     per long word), at most 300 m apart;
  cross_script_300m  an Arabic name and an English name that sound alike
                     (simple transliteration, consonants compared), at
                     least 85 %, at most 300 m apart;
  contained_100m     every word of one core name is in the other, at most
                     100 m apart (the same building: "Manarat Al Farouk" and
                     "Manarat Al Farouk Maadi");
  kg_section_300m    a kindergarten and a school with the same core name, at
                     most 300 m apart: the school's KG section (kept as a school);
  same_name_2km      the same core name, at most 2 km apart (two pages of one
                     school with sloppy pins).

The core name is the importer's matching tokens (Arabic letter forms, the
article, digits and spacing normalised; stage and boys/girls words out)
without the generic words below (school, language, international, KG,
nursery, branch, ...). A branch or area word stays in the core, so two
branches of a chain ("Manarat Al Farouk - New Cairo" and "- Maadi") have
different cores and never merge, whatever the distance; more than 2 km
apart nothing merges.

Never merged (deliberately left as "to check", with the reason):
  - different stages (primary / preparatory / secondary) or boys / girls:
    separate schools that often share a name and a site;
  - only one of the two names says the stage or boys/girls (which of the
    stage schools would it be?);
  - different people's names ("الشهيد أحمد" / "الشهيد محمد");
  - similar but below the rules (67 to 85 % alike within 500 m, or one
    name inside the other more than 300 m apart, or with a place word).

Standard library only.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass

GENERIC_EXTRA = frozenset(
    {
        "language", "languages", "لغات", "international", "دوليه", "kg", "روضه", "حضانه", "nursery",
        "branch", "فرع", "school", "schools", "مدرسه", "مدارس", "academy",
    }
)

SAME_NAME_M = 500.0
SIMILAR_M = 300.0
SIMILAR_MIN = 0.85
CONTAINED_M = 100.0
FAR_SAME_NAME_M = 2000.0
REPORT_MIN = 0.67  # two of three words alike; less is a different school
REPORT_M = 1500.0
REPORT_SIMILAR_M = 500.0

CONTAINED_FAR_M = 300.0
RULES = ("same_name_500m", "similar_300m", "cross_script_300m", "contained_100m", "contained_300m", "kg_section_300m", "same_name_2km")
RULE_TEXT = {
    "same_name_500m": "same name within 500 m",
    "similar_300m": "85 % alike within 300 m",
    "cross_script_300m": "Arabic and English names alike within 300 m",
    "contained_100m": "one name inside the other within 100 m",
    "contained_300m": "one name inside the other (extra words not a place) within 300 m",
    "kg_section_300m": "kindergarten section of the school, within 300 m",
    "same_name_2km": "same name within 2 km",
    "list_no_pin": "owner list entry without a pin, same name in its governorate",
}
KEEP_TEXT = {
    "stage": "different stage or boys/girls (separate schools)",
    "one_sided": "only one name says the stage or boys/girls",
    "people": "different people's names",
    "similar": "similar names, below the merge rules",
    "contained": "one name inside the other, more than 100 m apart",
    "branches": "same chain, different branch or area",
    "chain_conflict": "would join two groups, or matches a member but not the group's main entry",
    "list": "owner list entry without a pin matching several schools",
}

# Arabic -> Latin, one deterministic choice per letter (Egyptian usage:
# ج is g). Vowels are dropped afterwards, so the long vowels only matter as
# letters to drop.
_AR2LAT = {
    "ا": "a", "ب": "b", "ت": "t", "ث": "s", "ج": "g", "ح": "h", "خ": "kh", "د": "d", "ذ": "z", "ر": "r",
    "ز": "z", "س": "s", "ش": "sh", "ص": "s", "ض": "d", "ط": "t", "ظ": "z", "ع": "", "غ": "gh", "ف": "f",
    "ق": "k", "ك": "k", "ل": "l", "م": "m", "ن": "n", "ه": "h", "و": "w", "ي": "y", "ء": "", "ئ": "y", "ؤ": "w",
}
_ARABIC = re.compile("[\u0600-\u06FF]")


def transliterate(token: str) -> str:
    """"رواد" -> "rwad". Works on normalised tokens (ة is ه, ى is ي)."""
    t = token.lstrip("~")
    out = "".join(_AR2LAT.get(ch, ch) for ch in t)
    return out[:-1] if out.endswith("h") and len(out) > 2 else out  # ة at the end is a vowel


def skeleton(token: str) -> str:
    """Consonants only, for comparing an Arabic name with its English
    spelling: "rwad", "rowad" and "rawad" -> "rd"; "nyl" and "nile" -> "nl"."""
    t = transliterate(token) if _ARABIC.search(token) else token.lstrip("~").lower()
    t = t.replace("ph", "f").replace("ch", "sh").replace("q", "k").replace("j", "g").replace("c", "k").replace("x", "ks")
    t = re.sub(r"[aeiouyw]", "", t)
    t = re.sub(r"(.)\1+", r"\1", t)
    return t


def core(tokens: tuple[str, ...]) -> tuple[str, ...]:
    return tuple(t for t in tokens if t.lstrip("~") not in GENERIC_EXTRA)


def _tokens_match(a: str, b: str) -> bool:
    from schools_import import _tokens_match as tm

    return tm(a, b)


def set_similarity(a: tuple[str, ...], b: tuple[str, ...]) -> float:
    """Matching words over the words of the longer name (as the importer's
    token_similarity), on the core names."""
    if not a or not b:
        return 0.0
    short, long_ = (a, b) if len(a) <= len(b) else (b, a)
    used: set[int] = set()
    hits = 0
    for t in short:
        for k, o in enumerate(long_):
            if k not in used and _tokens_match(t, o):
                used.add(k)
                hits += 1
                break
    return hits / len(long_)


def _contained(a: tuple[str, ...], b: tuple[str, ...]) -> bool:
    if not a or not b or len(a) == len(b):
        return False
    short, long_ = (a, b) if len(a) < len(b) else (b, a)
    return set_similarity(short, long_) * len(long_) >= len(short) - 1e-9


def cross_similarity(ar: tuple[str, ...], en: tuple[str, ...]) -> float:
    """Arabic core tokens against English core tokens, by consonant skeletons."""
    a = [skeleton(t) for t in ar if _ARABIC.search(t)]
    e = [skeleton(t) for t in en if not _ARABIC.search(t)]
    a = [x for x in a if len(x) >= 2]
    e = [x for x in e if len(x) >= 2]
    if not a or not e:
        return 0.0
    used: set[int] = set()
    hits = 0
    for x in a:
        for k, y in enumerate(e):
            if k not in used and x == y:
                used.add(k)
                hits += 1
                break
    return hits / max(len(a), len(e))


def cores_of(s) -> list[tuple[str, ...]]:
    return [c for c in (core(s.match_ar), core(s.match_en)) if c]


def _people_differ(a: tuple[str, ...], b: tuple[str, ...]) -> bool:
    pa = {t for t in a if t.startswith("~")}
    pb = {t for t in b if t.startswith("~")}
    return bool(pa) and bool(pb) and pa != pb


@dataclass
class Verdict:
    rule: str | None  # a RULES key when the two are the same school
    keep: str | None  # a KEEP_TEXT key when they look alike but stay apart
    similarity: float


def judge(a, b, distance: float) -> Verdict:
    """Same school or not (see the module docstring). [a] and [b] are
    schools_import.School objects with pins."""
    stages_a, stages_b = a.stages - {"kg"}, b.stages - {"kg"}
    cores_a, cores_b = cores_of(a), cores_of(b)
    best = 0.0
    same = False
    contained = False
    people = False
    for x in cores_a:
        for y in cores_b:
            sim = set_similarity(x, y)
            best = max(best, sim)
            same = same or (x == y)
            contained = contained or _contained(x, y)
            people = people or _people_differ(x, y)
    cross = max([max(cross_similarity(x, y), cross_similarity(y, x)) for x in cores_a for y in cores_b] + [0.0])
    alike = same or best >= SIMILAR_MIN or cross >= SIMILAR_MIN or contained
    if not alike and best < REPORT_MIN:
        return Verdict(None, None, max(best, cross))
    if (stages_a and stages_b and stages_a != stages_b) or (a.genders and b.genders and a.genders != b.genders):
        return Verdict(None, "stage", best)
    if bool(stages_a) != bool(stages_b) or bool(a.genders) != bool(b.genders):
        return Verdict(None, "one_sided", best)
    if people and not same:
        return Verdict(None, "people", best)
    if a.kind != b.kind:
        if same and distance <= SIMILAR_M and {a.kind, b.kind} == {"school", "kindergarten"}:
            return Verdict("kg_section_300m", None, best)
        return Verdict(None, None, best)  # a kindergarten and a school with other names
    if same and distance <= SAME_NAME_M:
        return Verdict("same_name_500m", None, 1.0)
    if best >= SIMILAR_MIN and distance <= SIMILAR_M:
        return Verdict("similar_300m", None, best)
    if cross >= SIMILAR_MIN and distance <= SIMILAR_M:
        return Verdict("cross_script_300m", None, cross)
    if contained and distance <= CONTAINED_M:
        return Verdict("contained_100m", None, best)
    place_extra = any(_extra_is_place(x, y) for x in cores_a for y in cores_b if _contained(x, y))
    if contained and distance <= CONTAINED_FAR_M and not place_extra:
        return Verdict("contained_300m", None, best)
    if same and distance <= FAR_SAME_NAME_M:
        return Verdict("same_name_2km", None, 1.0)
    if distance > REPORT_M:
        return Verdict(None, None, best)
    if contained:
        # A longer name with a place word is a branch of a chain.
        return Verdict(None, "branches" if place_extra else "contained", best)
    if distance > REPORT_SIMILAR_M:
        return Verdict(None, None, best)
    return Verdict(None, "similar", max(best, cross))


_PLACE_WORDS: frozenset[str] | None = None


def place_words() -> frozenset[str]:
    """Normalised words of Egyptian town and area names (egypt_places.TOWNS)
    and branch-like words: a name that differs by one of these is another
    branch, not the same school."""
    global _PLACE_WORDS
    if _PLACE_WORDS is None:
        from egypt_places import TOWNS
        from schools_import import _words

        words = {"new", "city", "جديده", "مدينه", "east", "west", "north", "south", "شرق", "غرب", "شمال", "جنوب", "campus", "حرم"}
        for _gov, en, ar, _lat, _lng in TOWNS:
            for w in _words(en) + _words(ar):
                if len(w) >= 3 and w not in ("the", "and", "of", "el", "al"):
                    words.add(w)
        _PLACE_WORDS = frozenset(words)
    return _PLACE_WORDS


def _extra_is_place(a: tuple[str, ...], b: tuple[str, ...]) -> bool:
    """The words of the longer core that are not in the shorter one include a place word (or a number)."""
    short, long_ = (a, b) if len(a) < len(b) else (b, a)
    extra = [t.lstrip("~") for t in long_ if not any(_tokens_match(t, x) for x in short)]
    return any(t in place_words() or t.isdigit() for t in extra)


def quick_keys(s) -> frozenset[str]:
    """Core words and their consonant skeletons ("" names: empty set, always compared)."""
    out: set[str] = set()
    for c in cores_of(s):
        for t in c:
            out.add(t.lstrip("~"))
            sk = skeleton(t)
            if len(sk) >= 2:
                out.add("#" + sk)
    return frozenset(out)


def cells(lat: float, lng: float, size_deg: float = 0.02) -> tuple[int, int]:
    """About 2.2 km by 1.9 km around Cairo."""
    return int(math.floor(lat / size_deg)), int(math.floor(lng / size_deg))
