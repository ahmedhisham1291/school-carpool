"""Schools list import for Egypt (F4, Prompt 4B). Python 3.11+, standard library only.

Reads the files the owner puts in data/schools:
  - the Humanitarian Data Exchange (HDX) "Egypt Education Facilities
    (OpenStreetMap Export)" in GeoJSON (points and polygons, plain or
    zipped) or CSV;
  - ministry, governorate or school-group lists as CSV (headers in
    English or Arabic, see LIST_HEADERS);
  - the OpenStreetMap download of fetch_osm_schools.py in data/schools/osm/
    (same shape as the HDX export, read before the files above);
  - optionally governorate boundaries (GeoJSON, admin level 1, or the
    OpenStreetMap governorates from fetch_osm_schools.py) in
    data/schools/boundaries/ for an exact governorate per school.

Keeps kindergartens and schools only, cleans names, assigns governorate and
city, merges duplicates (same or similar name within about 300 m) and
writes schools.json (input of functions/scripts/load_schools.ts) and
report.md. Output is deterministic: the same input gives the same IDs, so
loading twice never creates duplicates.
"""

from __future__ import annotations

import csv
import io
import json
import math
import re
import unicodedata
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Iterator

from egypt_places import EGYPT_BOUNDS, GOVERNORATE_ALIASES, GOVERNORATES, ISO_3166_2, TOWNS

MERGE_DISTANCE_M = 300.0
NEARBY_REPORT_DISTANCE_M = 1500.0
# Names must match word for word (one slip allowed per rules above) to merge.
MERGE_SIMILARITY = 1.0
REPORT_SIMILARITY = 0.5

# ---------------------------------------------------------------------------
# Text
# ---------------------------------------------------------------------------

_DIACRITICS = re.compile("[ً-ْٰـ]")  # harakat, shadda, sukun, dagger alef, tatweel
_ALEF_FORMS = re.compile("[آأإٱ]")  # alef with madda, hamza above/below, wasla
_ARABIC_LETTER = re.compile("[ء-ي]")


def _ascii_digits(text: str) -> str:
    out = []
    for ch in text:
        code = ord(ch)
        if 0x0660 <= code <= 0x0669:
            out.append(chr(code - 0x0660 + 48))
        elif 0x06F0 <= code <= 0x06F9:
            out.append(chr(code - 0x06F0 + 48))
        else:
            out.append(ch)
    return "".join(out)


def normalize_text(text: str) -> str:
    """Same rules as functions/src/text/normalize.ts and lib/features/schools/text_normalize.dart.

    Arabic-Indic digits become 0-9; NFKC; lower case; diacritics and
    tatweel removed; alef forms become a bare alef; alef maqsura becomes
    yaa; taa marbuta becomes haa; anything not a letter or digit becomes a
    space; spaces collapsed.
    """
    text = unicodedata.normalize("NFKC", _ascii_digits(text)).lower()
    text = _DIACRITICS.sub("", text)
    text = _ALEF_FORMS.sub("ا", text)
    text = text.replace("ى", "ي").replace("ة", "ه")
    cleaned = []
    for ch in text:
        cat = unicodedata.category(ch)
        cleaned.append(ch if cat[0] in ("L", "N") else " ")
    return " ".join("".join(cleaned).split())


def has_arabic(text: str) -> bool:
    return bool(_ARABIC_LETTER.search(text))


# Words that say "this is a school" but not WHICH school. Dropped for
# matching only (never from the stored names). Already normalized.
_GENERIC = {
    "مدرسه", "مدارس", "المدرسه", "school", "schools", "the", "al", "el", "of", "for",
    "and", "و", "رسميه", "level", "مرحله", "اطفال", "children",
}

# Stage and gender words DISTINGUISH schools: in Egypt a primary, a
# preparatory and a secondary school, or a boys' and a girls' school, often
# share a name and a site but are separate schools with their own hours.
# Two names whose stages or genders differ are never merged; when only one
# name has one, the pair goes to the report instead (review of Prompt 4B).
_STAGES = {
    "حضانه": "kg", "روضه": "kg", "رياض": "kg", "kg": "kg", "kindergarten": "kg",
    "nursery": "kg", "preschool": "kg",
    "ابتدائي": "primary", "ابتدائيه": "primary", "primary": "primary", "elementary": "primary",
    "اعدادي": "prep", "اعداديه": "prep", "preparatory": "prep", "prep": "prep", "middle": "prep",
    "ثانوي": "secondary", "ثانويه": "secondary", "secondary": "secondary", "high": "secondary",
}
_GENDERS = {
    "بنين": "boys", "للبنين": "boys", "boys": "boys", "boy": "boys",
    "بنات": "girls", "للبنات": "girls", "girls": "girls", "girl": "girls",
}

# Words after which a person's name follows ("مدرسة الشهيد أحمد ...").
_NAME_MARKERS = {"شهيد", "martyr", "shahid", "shaheed", "دكتور", "dr", "استاذ", "شيخ", "sheikh"}
# Common given names (normalized). A one-letter difference in a person's
# name is a different person (أحمد / محمد, محمد / محمود), never a slip.
_PERSON_NAMES = {
    "احمد", "محمد", "محمود", "حامد", "حمدي", "علي", "عمر", "عمرو", "حسن", "حسين", "حسني",
    "مصطفي", "ابراهيم", "اسماعيل", "يوسف", "خالد", "سعد", "سعيد", "صلاح", "جمال", "كمال",
    "عبدالله", "عبدالرحمن", "عبدالرحيم", "عبدالعزيز", "عبدالناصر", "عبدالحميد", "عبدالمنعم",
    "عبدالفتاح", "عبدالسلام", "عثمان", "عادل", "عاطف", "طارق", "طه", "ياسر", "ياسين",
    "فاطمه", "عائشه", "خديجه", "مريم", "زينب", "نفيسه", "هدي", "سلمي", "نور",
    "mohamed", "mohammed", "muhammad", "mohammad", "mahmoud", "mahmud", "ahmed", "ahmad",
    "ibrahim", "ismail", "mostafa", "mustafa", "youssef", "yousef", "khaled", "hassan",
    "hussein", "hosny", "abdallah", "abdullah", "abdelrahman", "abdelaziz", "abdelnasser",
    "fatma", "fatima", "aisha", "khadija", "maryam", "zeinab", "saad", "said", "salah",
}

_SYNONYMS = {
    "intl": "international", "int": "international", "internationale": "international",
    "lang": "language", "languages": "language", "لغات": "لغات", "للغات": "لغات",
    "الدوليه": "دوليه", "دولي": "دوليه", "الدولي": "دوليه",
    "amer": "american", "brit": "british", "sch": "school",
}


def _words(name: str) -> list[str]:
    words = []
    for token in normalize_text(name).split():
        token = _SYNONYMS.get(token, token)
        if token.startswith("ال") and len(token) > 4:
            token = token[2:]
        words.append(_SYNONYMS.get(token, token))
    return words


def match_tokens(name: str) -> tuple[str, ...]:
    """Tokens used to compare two names: normalized, generic, stage and
    gender words removed (stage and gender are compared separately, see
    name_tags), a leading Arabic article dropped from longer words. Words
    of a person's name are marked with a leading "~" (no spelling slip
    allowed in them)."""
    tokens = []
    after_marker = False
    for token in _words(name):
        if token in _STAGES or token in _GENDERS:
            continue
        if token in _GENERIC or token.startswith("مدرس"):
            continue
        is_name = after_marker or token in _PERSON_NAMES
        after_marker = token in _NAME_MARKERS or (after_marker and token in _PERSON_NAMES)
        tokens.append(f"~{token}" if is_name and token not in _NAME_MARKERS else token)
    return tuple(tokens)


def name_tags(*names: str) -> tuple[frozenset[str], frozenset[str]]:
    """(stages, genders) said in any of [names]: kg, primary, prep, secondary; boys, girls."""
    stages: set[str] = set()
    genders: set[str] = set()
    for name in names:
        for token in _words(name):
            if token in _STAGES:
                stages.add(_STAGES[token])
            if token in _GENDERS:
                genders.add(_GENDERS[token])
    return frozenset(stages), frozenset(genders)


def _edit_distance_at_most_one(a: str, b: str) -> bool:
    if a == b:
        return True
    if abs(len(a) - len(b)) > 1:
        return False
    if len(a) > len(b):
        a, b = b, a
    i = j = 0
    edited = False
    while i < len(a) and j < len(b):
        if a[i] == b[j]:
            i += 1
            j += 1
            continue
        if edited:
            return False
        edited = True
        if len(a) == len(b):
            i += 1
        j += 1
    return True


SLIP_MIN_LETTERS = 6


def _tokens_match(a: str, b: str) -> bool:
    """Same word, or one letter different in a word of 6+ letters that is
    not part of a person's name ("Collage"/"College", "فكتوريا"/"فيكتوريا")."""
    if a == b:
        return True
    if a.startswith("~") or b.startswith("~"):
        return False
    return min(len(a), len(b)) >= SLIP_MIN_LETTERS and _edit_distance_at_most_one(a, b)


def token_similarity(a: tuple[str, ...], b: tuple[str, ...]) -> float:
    """How alike two names are, 0 to 1: matching words over the words of the
    longer name. 1.0 only when every word of both names matches."""
    if not a or not b:
        return 0.0
    if len(a) > len(b):
        a, b = b, a
    used: set[int] = set()
    hits = 0
    for token in a:
        for k, other in enumerate(b):
            if k not in used and _tokens_match(token, other):
                used.add(k)
                hits += 1
                break
    return hits / len(b)


def is_contained(a: tuple[str, ...], b: tuple[str, ...]) -> bool:
    """Every word of the shorter name is in the longer one (and they differ)."""
    if not a or not b or len(a) == len(b):
        return False
    short, long_ = (a, b) if len(a) < len(b) else (b, a)
    return token_similarity(short, long_) * len(long_) >= len(short) - 1e-9


# ---------------------------------------------------------------------------
# Places
# ---------------------------------------------------------------------------


def distance_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lng2 - lng1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def in_egypt(lat: float, lng: float) -> bool:
    b = EGYPT_BOUNDS
    return b["min_lat"] <= lat <= b["max_lat"] and b["min_lng"] <= lng <= b["max_lng"]


_GOV_LOOKUP = {normalize_text(alias): code for code, aliases in GOVERNORATE_ALIASES.items() for alias in (*aliases, code)}


def governorate_code(text: str | None) -> str | None:
    """Governorate code from a name in Arabic or English ("محافظة الجيزة", "Giza Governorate")."""
    if not text:
        return None
    key = normalize_text(text)
    for word in ("محافظه", "governorate", "gov"):
        key = " ".join(t for t in key.split() if t != word)
    key = key.replace("_", " ")
    if key in _GOV_LOOKUP:
        return _GOV_LOOKUP[key]
    stripped = " ".join(t[2:] if t.startswith("ال") and len(t) > 3 else t for t in key.split())
    for alias, code in _GOV_LOOKUP.items():
        alias_stripped = " ".join(t[2:] if t.startswith("ال") and len(t) > 3 else t for t in alias.split())
        if stripped == alias_stripped:
            return code
    return None


def nearest_town(lat: float, lng: float) -> tuple[str, str, str]:
    """(governorate, city in English, city in Arabic) of the nearest reference town."""
    best = min(TOWNS, key=lambda t: distance_m(lat, lng, t[3], t[4]))
    return best[0], best[1], best[2]


_BAND_DEG = 0.02  # about 2 km of latitude per band


class _IndexedRing:
    """A ring with its edges sorted into latitude bands, so a point is
    tested only against the few edges that cross its latitude (a detailed
    governorate border has tens of thousands of points)."""

    __slots__ = ("min_lat", "max_lat", "min_lng", "max_lng", "bands")

    def __init__(self, ring: list) -> None:
        pts = [(float(p[0]), float(p[1])) for p in ring]
        self.min_lng = min(p[0] for p in pts)
        self.max_lng = max(p[0] for p in pts)
        self.min_lat = min(p[1] for p in pts)
        self.max_lat = max(p[1] for p in pts)
        self.bands: dict[int, list[tuple[float, float, float, float]]] = {}
        n = len(pts)
        for i in range(n):
            x1, y1 = pts[i]
            x2, y2 = pts[(i + 1) % n]
            if y1 == y2:
                continue  # a horizontal edge never changes the ray count
            for band in range(math.floor(min(y1, y2) / _BAND_DEG), math.floor(max(y1, y2) / _BAND_DEG) + 1):
                self.bands.setdefault(band, []).append((x1, y1, x2, y2))

    def contains(self, lat: float, lng: float) -> bool:
        if not (self.min_lat <= lat <= self.max_lat and self.min_lng <= lng <= self.max_lng):
            return False
        inside = False
        for x1, y1, x2, y2 in self.bands.get(math.floor(lat / _BAND_DEG), ()):
            if (y1 > lat) != (y2 > lat) and lng < x1 + (lat - y1) * (x2 - x1) / (y2 - y1):
                inside = not inside
        return inside


@dataclass
class Boundaries:
    """Governorate polygons: HDX "Egypt - Subnational Administrative
    Boundaries" (admin 1) or the OpenStreetMap governorates written by
    fetch_osm_schools.py (admin_level 4, tagged ISO3166-2)."""

    shapes: list[tuple[str, list]] = field(default_factory=list)
    _index: list[tuple[str, list[tuple[_IndexedRing, list[_IndexedRing]]]]] | None = field(default=None, repr=False, compare=False)

    def governorate_at(self, lat: float, lng: float) -> str | None:
        if self._index is None or len(self._index) != len(self.shapes):
            self._index = [
                (code, [(_IndexedRing(p[0]), [_IndexedRing(h) for h in p[1:]]) for p in polygons if p and len(p[0]) >= 3])
                for code, polygons in self.shapes
            ]
        for code, polygons in self._index:
            for outer, holes in polygons:
                if outer.contains(lat, lng) and not any(h.contains(lat, lng) for h in holes):
                    return code
        return None

    @staticmethod
    def load(paths: Iterable[Path], problems: list[str]) -> "Boundaries":
        result = Boundaries()
        for path in paths:
            for feature in _read_geojson_features(path.read_bytes()):
                props = feature.get("properties") or {}
                geometry = feature.get("geometry") or {}
                code = ISO_3166_2.get(str(props.get("ISO3166-2") or props.get("ADM1_PCODE") or "").upper())
                for key in ("ADM1_EN", "ADM1_AR", "admin1Name_en", "admin1Name_ar", "name:en", "name", "NAME_1", "shapeName"):
                    if code:
                        break
                    code = governorate_code(str(props.get(key) or ""))
                if not code:
                    problems.append(f"{path.name}: a boundary with unknown governorate name was skipped")
                    continue
                if geometry.get("type") == "Polygon":
                    result.shapes.append((code, [geometry["coordinates"]]))
                elif geometry.get("type") == "MultiPolygon":
                    result.shapes.append((code, geometry["coordinates"]))
        return result


# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

KEEP_AMENITIES = {"school": "school", "kindergarten": "kindergarten"}
# Everything else tagged as education in the export, with the drop reason.
DROP_AMENITIES = {
    "university": "not_school_university",
    "college": "not_school_college",
    "language_school": "not_school_courses",
    "music_school": "not_school_courses",
    "driving_school": "not_school_courses",
    "dancing_school": "not_school_courses",
    "training": "not_school_courses",
    "prep_school": "not_school_courses",
    "childcare": "not_school_childcare",
    "trade_school": "not_school_courses",
    "cooking_school": "not_school_courses",
    "art_school": "not_school_courses",
    "flight_school": "not_school_courses",
}

# education=* (approved Feb 2025; same values and meanings as amenity=*,
# OSM wiki "Proposal:Education tag"): kept and dropped the same way.
KEEP_EDUCATION = KEEP_AMENITIES
DROP_EDUCATION = {
    **DROP_AMENITIES,
    "ski_school": "not_school_courses",
    "surf_school": "not_school_courses",
    "sailing_school": "not_school_courses",
}

# A feature named like a school but mapped as something else: a street
# ("شارع المدرسة"), a bus stop, a shop, a place, a historic madrasa
# ("مدرسة السلطان حسن" is a monument), a sports pitch, ... Checked only
# when no school tag says otherwise.
OTHER_FEATURE_KEYS = (
    "highway", "railway", "public_transport", "place", "shop", "office", "craft", "tourism",
    "healthcare", "waterway", "natural", "historic", "man_made", "aeroway", "power", "route",
    "leisure", "military", "religion",
)

# Normalized (normalize_text) name rules. A school name starts with the
# word for school or kindergarten (optionally after "ال" or "مجمع"), or says
# school / kindergarten / KG in English. A name that also says university,
# faculty, centre, academy, driving, training, music, dance, courses or
# nursing is not a school for this app (language SCHOOLS stay: in Egypt a
# "language school" is an ordinary school teaching in a foreign language).
_SCHOOL_NAME_AR = re.compile(r"^(مجمع )?(ال)?(مدرسه|مدارس) \S|^(روضه|حضانه) \S")
_KG_NAME_AR = re.compile(r"^(روضه|حضانه) ")
_SCHOOL_NAME_EN = re.compile(r"\b(school|schools|kindergarten|kindergartens|preschool)\b|(?<![0-9] )\bkg\b")
_KG_NAME_EN = re.compile(r"\b(kindergarten|kindergartens|preschool)\b|(?<![0-9] )\bkg\b")
_NOT_SCHOOL_NAME = (
    (re.compile(r"\b(university|faculty)\b|جامعه|^كليه|\bكليه\b"), "not_school_university"),
    (
        re.compile(
            r"\b(driving|training|music|dance|ballet|courses|course|nursing)\b"
            r"|قياده|تدريب|موسيقي|رقص|باليه|كورسات|تمريض"
        ),
        "not_school_courses",
    ),
)
# Weaker words: they drop a name only when it does not itself read like a
# school's. "مركز" is also the word for a district (markaz) in Egyptian
# school names ("مدرسة ... بمركز دسوق"), and some real schools are called
# "... Academy School" or "... Center School".
_NOT_SCHOOL_NAME_WEAK = re.compile(r"\b(academy|center|centre)\b|اكاديميه|مركز|سنتر")
# A named school building is not dropped for these alone (religious
# schools carry religion=*; main kept every named building=school).
_BUILDING_OK_KEYS = {"religion"}
_BUILDING_PART = re.compile(r"^(مبني|عماره|جناح|فصول|بلوك|building|block|wing|hall)\b")
_MINISTRY = re.compile(r"وزاره|مديريه|اداره|ministry|directorate|governorate|محافظه")


def name_says_school(name: str) -> str | None:
    """"kindergarten" or "school" when [name] looks like a school's name, else None."""
    n = normalize_text(name)
    if not n:
        return None
    if _KG_NAME_AR.search(n) or _KG_NAME_EN.search(n):
        return "kindergarten"
    if _SCHOOL_NAME_AR.search(n) or _SCHOOL_NAME_EN.search(n):
        return "school"
    return None


def name_says_not_school(*names: str) -> str | None:
    for name in names:
        n = normalize_text(name)
        for pattern, reason in _NOT_SCHOOL_NAME:
            if n and pattern.search(n):
                return reason
        if n and _NOT_SCHOOL_NAME_WEAK.search(n) and not name_says_school(name):
            return "not_school_courses"
    return None


def _isced_levels(value: str) -> set[int]:
    return {int(d) for d in re.findall(r"\d", value)}


def classify_tags(props: dict, names: tuple[str, ...]) -> tuple[str | None, str]:
    """(kind, why): kind is "school", "kindergarten" or None (dropped, why is
    the DROP_REASONS key). The single place that decides what counts. Rules
    in order:
    1. amenity=school|kindergarten: kept (as before; the name is checked later).
    2. amenity=university, college, driving_school, childcare, ...: dropped.
    3. education=school|kindergarten kept; other education values dropped.
    4. any other amenity, or a street/shop/place/historic/... tag: dropped
       as "named like a school but mapped as something else".
    5. building=school|kindergarten, school=*, isced:level=* or a school-like
       name: kept, unless the name says university/centre/... or (for a
       building) is the name of a building part ("مبنى ب").
    """
    amenity = _first(props, "amenity", "AMENITY").lower()
    if amenity in KEEP_AMENITIES:
        return KEEP_AMENITIES[amenity], "amenity"
    if amenity in DROP_AMENITIES:
        return None, DROP_AMENITIES[amenity]
    education = _first(props, "education").lower()
    if education in KEEP_EDUCATION:
        return KEEP_EDUCATION[education], "education"
    if education in DROP_EDUCATION:
        return None, DROP_EDUCATION[education]
    school_building = _first(props, "building").lower() in ("school", "kindergarten")
    if amenity or any(
        _first(props, k) for k in OTHER_FEATURE_KEYS if not (school_building and k in _BUILDING_OK_KEYS)
    ):
        return None, "not_school_feature"
    landuse = _first(props, "landuse").lower()
    if landuse and landuse != "education":
        return None, "not_school_feature"

    building = _first(props, "building").lower()
    school_tag = _first(props, "school").lower()
    isced = _isced_levels(_first(props, "isced:level"))
    by_name = next((k for k in (name_says_school(n) for n in names) if k), None)
    kind: str | None = None
    why = ""
    if building in ("school", "kindergarten"):
        kind, why = building, "building"
    elif isced:
        if min(isced) >= 5:
            return None, "not_school_university"
        kind, why = ("kindergarten" if isced == {0} else "school"), "isced"
    elif school_tag:
        kind, why = ("kindergarten" if school_tag in ("kindergarten", "preschool", "nursery") else "school"), "school_tag"
    elif by_name:
        kind, why = by_name, "name"
    if kind is None:
        return None, "not_school_other"
    if by_name == "kindergarten" and why != "isced":
        kind = "kindergarten"
    not_school = name_says_not_school(*names)
    if not_school:
        return None, not_school
    if why == "building" and not by_name and any(_BUILDING_PART.search(normalize_text(n)) for n in names if n):
        return None, "building_part"
    return kind, why


def recover_name(props: dict) -> tuple[str, str]:
    """(name, tag it came from) for a feature without name/name:ar/name:en:
    official_name, alt_name (first of a ";" list), short_name, then the
    operator when it reads like a school's name (not "the Ministry of
    Education"). ("", "") when none."""
    for key in (
        "official_name", "official_name:ar", "official_name:en", "alt_name", "alt_name:ar", "alt_name:en",
        "short_name", "short_name:ar", "short_name:en", "old_name",
    ):
        value = _first(props, key).split(";")[0].strip()
        if value:
            return value, key
    operator = _first(props, "operator").split(";")[0].strip()
    if operator and name_says_school(operator) and not _MINISTRY.search(normalize_text(operator)):
        return operator, "operator"
    return "", ""


@dataclass
class RawEntry:
    source: str
    source_id: str
    kind: str | None  # school, kindergarten or None (unknown, from a list)
    amenity: str
    name: str
    name_ar: str
    name_en: str
    governorate_text: str
    city_text: str
    lat: float | None
    lng: float | None
    file: str
    drop_reason: str = ""  # why kind is None (DROP_REASONS key)
    name_from: str = ""  # tag the name was recovered from (official_name, ...)
    wikidata: str = ""  # OSM "wikidata" tag (Q-number), or the item's own QID


@dataclass
class School:
    id: str
    source: str
    source_id: str
    source_keys: list[str]
    name_ar: str
    name_en: str
    kind: str
    governorate: str
    governorate_method: str  # given, boundary, nearest
    city: str
    city_ar: str
    lat: float | None
    lng: float | None
    match_ar: tuple[str, ...] = ()
    match_en: tuple[str, ...] = ()
    stages: frozenset[str] = frozenset()
    genders: frozenset[str] = frozenset()

    def to_json(self) -> dict:
        return {
            "id": self.id,
            "source": self.source,
            "sourceId": self.source_id,
            "sourceKeys": self.source_keys,
            "nameAr": self.name_ar,
            "nameEn": self.name_en,
            "kind": self.kind,
            "governorate": self.governorate,
            "governorateMethod": self.governorate_method,
            "city": self.city,
            "cityAr": self.city_ar,
            "location": None if self.lat is None or self.lng is None else {"lat": self.lat, "lng": self.lng},
        }


def _first(props: dict, *keys: str) -> str:
    for key in keys:
        value = props.get(key)
        if value is not None and str(value).strip():
            return str(value).strip()
    return ""


def _centroid(geometry: dict) -> tuple[float, float] | None:
    kind = geometry.get("type")
    coords = geometry.get("coordinates")
    if not coords:
        return None
    if kind == "Point":
        return float(coords[1]), float(coords[0])
    rings: list = []
    if kind == "Polygon":
        rings = [coords[0]]
    elif kind == "MultiPolygon":
        rings = [poly[0] for poly in coords if poly]
    elif kind in ("LineString", "MultiPoint"):
        rings = [coords]
    if not rings:
        return None
    points = [p for ring in rings for p in ring]
    return sum(p[1] for p in points) / len(points), sum(p[0] for p in points) / len(points)


def _read_geojson_features(data: bytes) -> list[dict]:
    doc = json.loads(data.decode("utf-8-sig"))
    if doc.get("type") == "FeatureCollection":
        return list(doc.get("features") or [])
    if doc.get("type") == "Feature":
        return [doc]
    return []


def _osm_source_id(props: dict, fallback: str) -> str:
    raw = _first(props, "@id", "id", "osm_id", "osm_way_id", "OSM_ID")
    osm_type = _first(props, "osm_type", "@type", "type").lower()
    if "/" in raw:  # "node/123"
        osm_type, raw = raw.split("/", 1)
    raw = raw.strip()
    if not raw:
        return fallback
    # "node", "nodes", "ways_poly", "relation", "n", ...: the first letter tells.
    if osm_type[:1] in ("n", "w", "r"):
        return f"{osm_type[0]}{raw.lstrip('-')}"
    return raw.lstrip("-")


_QID = re.compile(r"^Q[1-9][0-9]*$")


def _osm_entry(props: dict, lat: float | None, lng: float | None, file: str, index: int) -> RawEntry:
    name = _first(props, "name", "NAME")
    name_ar = _first(props, "name:ar", "name_ar")
    name_en = _first(props, "name:en", "name_en")
    name_from = ""
    if not (name or name_ar or name_en):
        name, name_from = recover_name(props)
    kind, why = classify_tags(props, (name, name_ar, name_en))
    amenity = _first(props, "amenity", "AMENITY").lower()
    # Wikidata items (fetch_wikidata_schools.py) carry "@source": "wikidata"
    # and their QID; OSM features may carry a "wikidata" tag linking one.
    is_wikidata = str(props.get("@source") or "") == "wikidata"
    qid = str(props.get("@id") if is_wikidata else props.get("wikidata") or "").strip()
    return RawEntry(
        source="wikidata" if is_wikidata else "osm",
        source_id=qid if is_wikidata and qid else _osm_source_id(props, f"{Path(file).stem}-{index}"),
        kind=kind,
        amenity=amenity or "unknown",
        drop_reason="" if kind else why,
        name_from=name_from,
        wikidata=qid if _QID.match(qid) else "",
        name=name,
        name_ar=name_ar,
        name_en=name_en,
        governorate_text=_first(props, "addr:governorate", "addr:province", "addr:state", "is_in:state"),
        city_text=_first(props, "addr:city", "addr:district", "addr:suburb"),
        lat=lat,
        lng=lng,
        file=file,
    )


def read_osm_geojson(data: bytes, file: str) -> Iterator[RawEntry]:
    for i, feature in enumerate(_read_geojson_features(data)):
        props = feature.get("properties") or {}
        point = _centroid(feature.get("geometry") or {})
        yield _osm_entry(props, point[0] if point else None, point[1] if point else None, file, i)


_WKT_POINT = re.compile(r"POINT\s*\(\s*([-\d.]+)\s+([-\d.]+)\s*\)", re.I)


def _float(value: str) -> float | None:
    try:
        return float(_ascii_digits(value).replace("٫", ".").strip())
    except (TypeError, ValueError):
        return None


def _coords_from_row(row: dict) -> tuple[float | None, float | None]:
    lat = _float(_first(row, "lat", "latitude", "Latitude", "LAT", "y", "Y", "خط العرض"))
    lng = _float(_first(row, "lng", "lon", "long", "longitude", "Longitude", "LON", "x", "X", "خط الطول"))
    if lat is None or lng is None:
        match = _WKT_POINT.search(_first(row, "geometry", "WKT", "wkt", "the_geom"))
        if match:
            lng, lat = float(match.group(1)), float(match.group(2))
    return lat, lng


# Headers accepted in ministry, governorate and school-group lists. Any
# other column is ignored (and listed in the report).
LIST_HEADERS = {
    "id": ("source_id", "id", "school_id", "code", "school_code", "كود المدرسة", "الكود", "رقم المدرسة"),
    "name_ar": ("name_ar", "arabic_name", "name (ar)", "اسم المدرسة", "الاسم", "اسم المدرسة بالعربي"),
    "name_en": ("name_en", "english_name", "name (en)", "school_name", "name", "اسم المدرسة بالانجليزي"),
    "kind": ("kind", "type", "stage", "level", "النوع", "المرحلة"),
    "governorate": ("governorate", "gov", "province", "المحافظة"),
    "city": ("city", "district", "area", "idara", "administration", "المدينة", "الإدارة", "الادارة", "الحي", "المنطقة"),
    "source": ("source", "المصدر"),
}

_KG_WORDS = ("kg", "kindergarten", "nursery", "رياض", "روضه", "حضانه")


def _list_kind(text: str) -> str:
    key = normalize_text(text)
    return "kindergarten" if any(w in key.split() or key.startswith(w) for w in _KG_WORDS) else "school"


class InputFileError(Exception):
    """A file that cannot be read; reported, the run goes on."""


def decode_text(data: bytes) -> str:
    """UTF-8 (with or without the BOM Excel adds), UTF-16 (Excel's "Unicode
    text") or Windows-1256 (older Arabic Excel exports)."""
    if data.startswith(b"\xef\xbb\xbf"):
        return data[3:].decode("utf-8")
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        return data.decode("utf-16")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        pass
    try:
        return data.decode("cp1256")
    except UnicodeDecodeError as error:
        raise InputFileError("not UTF-8, UTF-16 or Windows-1256 text; save it as CSV UTF-8") from error


def _sniff_dialect(text: str) -> type[csv.Dialect] | csv.Dialect:
    """Comma, semicolon (Excel in many locales) or tab."""
    sample = "\n".join(text.splitlines()[:20])
    try:
        return csv.Sniffer().sniff(sample, delimiters=",;\t")
    except csv.Error:
        return csv.excel


def _list_row_id(name_ar: str, name_en: str, governorate: str, city: str) -> str:
    """Stable ID for a list row without an ID column: from the normalized
    name, governorate and city (not the row number, which shifts when the
    list is edited)."""
    import hashlib

    key = "|".join(normalize_text(x) for x in (name_ar or name_en, governorate, city))
    return "h" + hashlib.sha1(key.encode("utf-8")).hexdigest()[:12]


def read_csv(data: bytes, file: str, source_name: str) -> tuple[list[RawEntry], list[str]]:
    """An OSM export CSV (has an amenity column) or a school list CSV."""
    text = decode_text(data)
    reader = csv.DictReader(io.StringIO(text), dialect=_sniff_dialect(text))
    headers = [h.strip() for h in (reader.fieldnames or [])]
    rows = [{(k or "").strip(): (v or "") for k, v in row.items()} for row in reader]
    entries: list[RawEntry] = []
    if "amenity" in headers or "osm_id" in headers or "@id" in headers:
        for i, row in enumerate(rows):
            lat, lng = _coords_from_row(row)
            entries.append(_osm_entry(row, lat, lng, file, i))
        return entries, []

    lowered = {h.lower(): h for h in headers}

    def col(name: str) -> str | None:
        for alias in LIST_HEADERS[name]:
            if alias.lower() in lowered:
                return lowered[alias.lower()]
        return None

    cols = {name: col(name) for name in LIST_HEADERS}
    used = {c for c in cols.values() if c}
    coord_like = {"lat", "latitude", "lng", "lon", "long", "longitude", "x", "y", "geometry", "wkt", "خط العرض", "خط الطول"}
    ignored = [h for h in headers if h not in used and h.lower() not in coord_like]
    for i, row in enumerate(rows):
        lat, lng = _coords_from_row(row)
        name_ar = row.get(cols["name_ar"] or "", "").strip()
        name_en = row.get(cols["name_en"] or "", "").strip()
        # A single "name" column may hold Arabic.
        if name_en and not name_ar and has_arabic(name_en):
            name_ar, name_en = name_en, ""
        raw_id = row.get(cols["id"] or "", "").strip() or _list_row_id(
            name_ar, name_en, row.get(cols["governorate"] or "", ""), row.get(cols["city"] or "", "")
        )
        source = normalize_text(row.get(cols["source"] or "", "")).replace(" ", "_") or source_name
        entries.append(
            RawEntry(
                source=f"list_{source}",
                source_id=raw_id,
                kind=_list_kind(row.get(cols["kind"] or "", "") + " " + name_ar + " " + name_en),
                amenity="list",
                name="",
                name_ar=name_ar,
                name_en=name_en,
                governorate_text=row.get(cols["governorate"] or "", "").strip(),
                city_text=row.get(cols["city"] or "", "").strip(),
                lat=lat,
                lng=lng,
                file=file,
            )
        )
    return entries, ignored


def _list_source_name(path: Path) -> str:
    return re.sub(r"[^a-z0-9]+", "_", path.stem.lower()).strip("_") or "list"


OSM_FOLDER = "osm"  # written by fetch_osm_schools.py
WIKIDATA_FOLDER = "wikidata"  # written by fetch_wikidata_schools.py


def read_inputs(folder: Path) -> tuple[list[RawEntry], Boundaries, list[str], list[str]]:
    """All entries in [folder] (not its subfolders, except osm/, wikidata/
    and boundaries/), the boundaries, the files read and any problems. The
    OpenStreetMap download in osm/ is read first: when an HDX export of the
    same data is also there, its copies count as "same source ID twice"."""
    entries: list[RawEntry] = []
    problems: list[str] = []
    files_read: list[str] = []
    boundary_dir = folder / "boundaries"
    boundaries = Boundaries.load(sorted(boundary_dir.glob("*.geojson")) + sorted(boundary_dir.glob("*.json")), problems) if boundary_dir.is_dir() else Boundaries()

    def take(name: str, data: bytes) -> None:
        suffix = Path(name).suffix.lower()
        if suffix in (".geojson", ".json"):
            try:
                entries.extend(read_osm_geojson(data, name))
            except (ValueError, UnicodeDecodeError) as error:
                problems.append(f"{name}: skipped, not valid GeoJSON ({type(error).__name__})")
                return
            files_read.append(name)
        elif suffix == ".csv":
            try:
                found, ignored = read_csv(data, name, _list_source_name(Path(name)))
            except (InputFileError, csv.Error) as error:
                problems.append(f"{name}: skipped, {error}")
                return
            entries.extend(found)
            files_read.append(name)
            if ignored:
                problems.append(f"{name}: columns not used: {', '.join(ignored)}")

    paths: list[Path] = []
    for sub in (OSM_FOLDER, WIKIDATA_FOLDER):
        if (folder / sub).is_dir():
            paths += sorted((folder / sub).iterdir())
    paths += sorted(folder.iterdir())
    for path in paths:
        if not path.is_file() or path.name.startswith(".") or path.name.endswith(".part"):
            continue
        if path.suffix.lower() == ".zip":
            with zipfile.ZipFile(path) as archive:
                for member in sorted(archive.namelist()):
                    take(f"{path.name}/{member}", archive.read(member))
        elif path.suffix.lower() in (".geojson", ".json", ".csv"):
            take(path.relative_to(folder).as_posix(), path.read_bytes())
    return entries, boundaries, files_read, problems


# ---------------------------------------------------------------------------
# Cleaning
# ---------------------------------------------------------------------------

DROP_REASONS = {
    "no_name": "No name",
    "generic_name": "Name says only \"school\"",
    "no_location_or_governorate": "No map location and no governorate",
    "outside_egypt": "Location outside Egypt",
    "not_school_university": "University",
    "not_school_college": "College",
    "not_school_courses": "Courses, centres and academies (language, music, driving, training, ...)",
    "not_school_childcare": "Childcare, not a kindergarten",
    "not_school_other": "Not a school or kindergarten",
    "not_school_feature": "Named like a school but mapped as something else (street, shop, place, historic madrasa, pitch, ...)",
    "building_part": "Name of a building part (\"مبنى ب\", \"Block A\")",
    "wikidata_linked": "Wikidata item already in OpenStreetMap (same item; its names were added there)",
    "name_too_long": "Name longer than 120 characters",
    "repeated_source_id": "Same source ID twice in the input",
}

_SAFE_ID = re.compile(r"[^A-Za-z0-9_-]+")


def doc_id(source: str, source_id: str) -> str:
    """Firestore document ID from the source and its ID (same input, same ID)."""
    value = _SAFE_ID.sub("-", f"{source}-{source_id}").strip("-")
    if len(value) > 64:
        import hashlib

        value = value[:47] + "-" + hashlib.sha1(value.encode()).hexdigest()[:16]
    return value


def clean_name(text: str) -> str:
    text = unicodedata.normalize("NFKC", text)
    text = text.replace("ـ", "")  # tatweel adds nothing to a stored name
    return " ".join(text.split())


@dataclass
class Dropped:
    reason: str
    source_key: str
    name: str
    file: str


def clean(entries: list[RawEntry], boundaries: Boundaries) -> tuple[list[School], list[Dropped]]:
    schools: list[School] = []
    dropped: list[Dropped] = []
    seen: set[str] = set()
    # An OSM school tagged wikidata=Q.. and the Wikidata item Q.. are the
    # same school: the item's labels fill the OSM school's missing names and
    # its key joins the school's keys; the item is not kept on its own.
    linked = {e.wikidata for e in entries if e.source != "wikidata" and e.kind and e.wikidata}
    wikidata_items = {e.source_id: e for e in entries if e.source == "wikidata" and e.kind and e.source_id in linked}
    for e in entries:
        key = f"{e.source}:{e.source_id}"
        display = e.name or e.name_ar or e.name_en

        def drop(reason: str) -> None:
            dropped.append(Dropped(reason, key, display, e.file))

        if e.kind is None:
            drop(e.drop_reason or DROP_AMENITIES.get(e.amenity, "not_school_other"))
            continue
        if e.source == "wikidata" and e.source_id in linked:
            drop("wikidata_linked")
            continue
        item = wikidata_items.get(e.wikidata) if e.source != "wikidata" else None
        name_ar = clean_name(e.name_ar)
        name_en = clean_name(e.name_en)
        name = clean_name(e.name)
        if name:
            if has_arabic(name):
                name_ar = name_ar or name
            else:
                name_en = name_en or name
        if item is not None:
            name_ar = name_ar or clean_name(item.name_ar)
            name_en = name_en or clean_name(item.name_en)
        if not name_ar and not name_en:
            drop("no_name")
            continue
        if not match_tokens(name_ar) and not match_tokens(name_en):
            drop("generic_name")
            continue
        if len(name_ar) > 120 or len(name_en) > 120:
            drop("name_too_long")
            continue
        if key in seen:
            drop("repeated_source_id")
            continue
        has_point = e.lat is not None and e.lng is not None
        if has_point and not in_egypt(e.lat, e.lng):  # type: ignore[arg-type]
            drop("outside_egypt")
            continue
        given = governorate_code(e.governorate_text)
        city_en = city_ar = ""
        if e.city_text:
            if has_arabic(e.city_text):
                city_ar = clean_name(e.city_text)
            else:
                city_en = clean_name(e.city_text)
        if given:
            governorate, method = given, "given"
        elif has_point:
            at = boundaries.governorate_at(e.lat, e.lng)  # type: ignore[arg-type]
            if at:
                governorate, method = at, "boundary"
            else:
                governorate, method = nearest_town(e.lat, e.lng)[0], "nearest"  # type: ignore[arg-type]
        else:
            drop("no_location_or_governorate")
            continue
        if has_point and not city_en and not city_ar:
            town_gov, town_en, town_ar = nearest_town(e.lat, e.lng)  # type: ignore[arg-type]
            if town_gov == governorate:
                city_en, city_ar = town_en, town_ar
        seen.add(key)
        schools.append(
            School(
                id=doc_id(e.source, e.source_id),
                source=e.source,
                source_id=e.source_id,
                source_keys=[key] + ([f"wikidata:{item.source_id}"] if item is not None else []),
                # One name fills in for the other until an admin adds it.
                name_ar=name_ar or name_en,
                name_en=name_en or name_ar,
                kind=e.kind,
                governorate=governorate,
                governorate_method=method,
                city=city_en or city_ar,
                city_ar=city_ar or city_en,
                lat=round(e.lat, 6) if has_point else None,  # type: ignore[arg-type]
                lng=round(e.lng, 6) if has_point else None,  # type: ignore[arg-type]
                match_ar=match_tokens(name_ar) if name_ar else (),
                match_en=match_tokens(name_en) if name_en else (),
                stages=name_tags(name_ar, name_en)[0],
                genders=name_tags(name_ar, name_en)[1],
            )
        )
    return schools, dropped


# ---------------------------------------------------------------------------
# Duplicates
# ---------------------------------------------------------------------------


def name_similarity(a: School, b: School) -> float:
    pairs = [(a.match_ar, b.match_ar), (a.match_en, b.match_en), (a.match_ar, b.match_en), (a.match_en, b.match_ar)]
    return max(token_similarity(x, y) for x, y in pairs)


def _contained(a: School, b: School) -> bool:
    pairs = [(a.match_ar, b.match_ar), (a.match_en, b.match_en), (a.match_ar, b.match_en), (a.match_en, b.match_ar)]
    return any(is_contained(x, y) for x, y in pairs)


def compare(a: School, b: School) -> tuple[str, float, str]:
    """("merge" | "report" | "different", name similarity, why) for two
    entries, before distance:
    - a different kind (kindergarten / school), stage or gender: different;
    - the same words (one slip allowed, rules above) and the same stage
      and gender: merge;
    - the same words but only one says a stage or gender, one name inside
      the other, or half the words or more alike: report, not merge."""
    sim = name_similarity(a, b)
    if a.kind != b.kind:
        return "different", sim, "kindergarten and school"
    if a.stages and b.stages and a.stages != b.stages:
        return "different", sim, "different stage"
    if a.genders and b.genders and a.genders != b.genders:
        return "different", sim, "boys and girls"
    one_sided = bool(a.stages) != bool(b.stages) or bool(a.genders) != bool(b.genders)
    if sim >= MERGE_SIMILARITY:
        if one_sided:
            return "report", sim, "same name, only one says the stage or boys/girls"
        return "merge", sim, "same name"
    if _contained(a, b):
        return "report", sim, "one name inside the other"
    if sim >= REPORT_SIMILARITY:
        return "report", sim, "similar name"
    return "different", sim, "different name"


@dataclass
class LikelyDuplicate:
    a: School
    b: School
    distance_m: float | None
    similarity: float
    why: str


def _source_rank(s: School) -> tuple:
    # Lists from the owner (ministry, governorate, school groups) know the
    # official name best; OSM nodes before ways (a node is usually the gate).
    return (
        0 if s.source.startswith("list_") else 1,
        0 if s.lat is not None else 1,
        0 if s.source_id.startswith("n") else 1,
        s.source,
        s.source_id,
    )


def _cells(lat: float, lng: float) -> tuple[int, int]:
    # About 550 m by 480 m around Cairo: neighbours within 300 m are in the 3x3 block.
    return int(math.floor(lat / 0.005)), int(math.floor(lng / 0.005))


def find_duplicates(schools: list[School]) -> tuple[list[School], list[list[School]], list[LikelyDuplicate]]:
    """Merges entries with the same name (see compare) within 300 m, and a
    list entry without a pin into the one same-name school of its
    governorate. No chains: an entry joins a group only if it also matches
    the group's main entry (and is within 300 m of it), and two groups are
    never joined. Everything borderline goes to the report. Returns the
    merged schools, the merged groups, and pairs to check by hand."""
    likely: list[LikelyDuplicate] = []
    merge_pairs: list[tuple[float, int, int]] = []

    grid: dict[tuple[int, int], list[int]] = {}
    for i, s in enumerate(schools):
        if s.lat is not None and s.lng is not None:
            grid.setdefault(_cells(s.lat, s.lng), []).append(i)

    reach = int(math.ceil(NEARBY_REPORT_DISTANCE_M / 480.0))
    for i, s in enumerate(schools):
        if s.lat is None or s.lng is None:
            continue
        ci, cj = _cells(s.lat, s.lng)
        for di in range(-reach, reach + 1):
            for dj in range(-reach, reach + 1):
                for j in grid.get((ci + di, cj + dj), []):
                    if j <= i:
                        continue
                    t = schools[j]
                    d = distance_m(s.lat, s.lng, t.lat, t.lng)  # type: ignore[arg-type]
                    if d > NEARBY_REPORT_DISTANCE_M:
                        continue
                    verdict, sim, why = compare(s, t)
                    if d <= MERGE_DISTANCE_M and verdict == "merge":
                        merge_pairs.append((d, i, j))
                    elif d <= MERGE_DISTANCE_M and verdict == "report":
                        likely.append(LikelyDuplicate(s, t, d, sim, f"{why}, within 300 m"))
                    elif verdict == "merge":
                        likely.append(LikelyDuplicate(s, t, d, sim, "same name 300 m to 1.5 km apart"))

    # Entries without a pin (lists): the one same-name school of the same
    # governorate (and city when both have one).
    by_name: dict[tuple[str, tuple[str, ...]], list[int]] = {}
    for i, s in enumerate(schools):
        for tokens in (s.match_ar, s.match_en):
            if tokens:
                by_name.setdefault((s.governorate, tokens), []).append(i)
    for i, s in enumerate(schools):
        if s.lat is not None:
            continue
        candidates = {j for tokens in (s.match_ar, s.match_en) if tokens for j in by_name.get((s.governorate, tokens), []) if j != i}
        if s.city:
            same_city = {j for j in candidates if normalize_text(schools[j].city) in (normalize_text(s.city), "") or normalize_text(schools[j].city_ar) == normalize_text(s.city_ar)}
            candidates = same_city or candidates
        verdicts = {j: compare(s, schools[j]) for j in candidates}
        mergeable = sorted(j for j, v in verdicts.items() if v[0] == "merge")
        if len(mergeable) == 1:
            merge_pairs.append((math.inf, i, mergeable[0]))
        for j in sorted(candidates):
            verdict, sim, why = verdicts[j]
            if len(mergeable) > 1 and verdict == "merge":
                likely.append(LikelyDuplicate(s, schools[j], None, sim, "list entry without a pin matches several schools"))
            elif verdict == "report":
                likely.append(LikelyDuplicate(s, schools[j], None, sim, f"{why}, list entry without a pin"))

    # Closest pairs first. A group grows only by single entries that also
    # match its main entry.
    group_of = list(range(len(schools)))
    members: dict[int, list[int]] = {i: [i] for i in range(len(schools))}

    def main_entry(g: int) -> int:
        return min(members[g], key=lambda k: _source_rank(schools[k]))

    for d, i, j in sorted(merge_pairs, key=lambda p: (p[0], schools[p[1]].id, schools[p[2]].id)):
        gi, gj = group_of[i], group_of[j]
        if gi == gj:
            continue
        if len(members[gi]) > 1 and len(members[gj]) > 1:
            likely.append(LikelyDuplicate(schools[i], schools[j], None if d == math.inf else d, 1.0, "both already merged with other entries"))
            continue
        group, single = (gi, j) if len(members[gi]) > 1 or (len(members[gj]) == 1 and gi < gj) else (gj, i)
        main = schools[main_entry(group)]
        newcomer = schools[single]
        near = (
            main.lat is None or newcomer.lat is None
            or distance_m(main.lat, main.lng, newcomer.lat, newcomer.lng) <= MERGE_DISTANCE_M  # type: ignore[arg-type]
        )
        if main is not newcomer and (compare(newcomer, main)[0] != "merge" or not near):
            likely.append(LikelyDuplicate(newcomer, main, None if d == math.inf else d, 1.0, "matches a merged entry but not its main entry"))
            continue
        for k in members.pop(group_of[single]):
            group_of[k] = group
            members[group].append(k)

    merged: list[School] = []
    merged_groups: list[list[School]] = []
    for g in sorted(members):
        group_members = [schools[k] for k in members[g]]
        merged.append(_merge(group_members))
        if len(group_members) > 1:
            merged_groups.append(sorted(group_members, key=_source_rank))
    merged.sort(key=lambda s: s.id)
    merged_groups.sort(key=lambda g: g[0].id)
    likely.sort(key=lambda p: (p.a.governorate, p.a.id, p.b.id))
    return merged, merged_groups, likely


def _merge(members: list[School]) -> School:
    members = sorted(members, key=_source_rank)
    primary = members[0]
    if len(members) == 1:
        return primary

    def best(attr: str, prefer_arabic: bool) -> str:
        """The first value in the wanted script; else the first value at all."""
        values = [getattr(m, attr) for m in members if getattr(m, attr)]
        for value in values:
            if has_arabic(value) == prefer_arabic:
                return value
        return values[0] if values else ""

    located = next((m for m in members if m.lat is not None), primary)
    governorate_from = next((m for m in members if m.governorate_method in ("given", "boundary")), located)
    return School(
        id=primary.id,
        source=primary.source,
        source_id=primary.source_id,
        source_keys=sorted({k for m in members for k in m.source_keys}),
        name_ar=best("name_ar", prefer_arabic=True),
        name_en=best("name_en", prefer_arabic=False),
        kind="kindergarten" if all(m.kind == "kindergarten" for m in members) else "school",
        governorate=governorate_from.governorate,
        governorate_method=governorate_from.governorate_method,
        city=best("city", prefer_arabic=False),
        city_ar=best("city_ar", prefer_arabic=True),
        lat=located.lat,
        lng=located.lng,
        match_ar=primary.match_ar,
        match_en=primary.match_en,
        stages=primary.stages,
        genders=primary.genders,
    )


# ---------------------------------------------------------------------------
# Run and report
# ---------------------------------------------------------------------------


@dataclass
class Result:
    schools: list[School]
    dropped: list[Dropped]
    merged_groups: list[list[School]]
    likely: list[LikelyDuplicate]
    files: list[str]
    problems: list[str]
    read_count: int
    # Per source family (osm, wikidata, list): entries read, and the tag
    # each recovered name came from.
    read_by_source: dict[str, int] = field(default_factory=dict)
    names_recovered: dict[str, int] = field(default_factory=dict)


def run(folder: Path) -> Result:
    entries, boundaries, files, problems = read_inputs(folder)
    cleaned, dropped = clean(entries, boundaries)
    merged, groups, likely = find_duplicates(cleaned)
    read_by_source: dict[str, int] = {}
    recovered: dict[str, int] = {}
    for e in entries:
        fam = source_family(e.source)
        read_by_source[fam] = read_by_source.get(fam, 0) + 1
        if e.name_from:
            recovered[e.name_from] = recovered.get(e.name_from, 0) + 1
    return Result(merged, dropped, groups, likely, files, problems, len(entries), read_by_source, recovered)


def source_family(source: str) -> str:
    """"osm", "wikidata" or "owner CSV" (list_<file>)."""
    if source.startswith("list_"):
        return "owner CSV"
    return source


def schools_json(result: Result, generated_at: str) -> dict:
    return {
        "format": "school-carpool-schools/1",
        "generatedAt": generated_at,
        "files": result.files,
        "count": len(result.schools),
        "schools": [s.to_json() for s in result.schools],
    }


def _label(s: School) -> str:
    names = s.name_ar if s.name_ar == s.name_en else f"{s.name_ar} / {s.name_en}"
    return f"{names} ({', '.join(s.source_keys)})"


def report_markdown(result: Result, generated_at: str, max_examples: int = 20) -> str:
    lines: list[str] = []
    out = lines.append
    out("# Schools import report")
    out("")
    out(f"Generated {generated_at}. Files read: {', '.join(result.files) or 'none'}.")
    out("")
    out("| | Count |")
    out("| --- | ---: |")
    out(f"| Entries read | {result.read_count} |")
    out(f"| Dropped | {len(result.dropped)} |")
    out(f"| Merged into another entry | {sum(len(g) - 1 for g in result.merged_groups)} |")
    out(f"| Schools and kindergartens kept | {len(result.schools)} |")
    out(f"| Likely duplicates to check | {len(result.likely)} |")
    out("")
    if result.read_by_source:
        out("Entries read per source: " + ", ".join(f"{k} {v}" for k, v in sorted(result.read_by_source.items())) + ".")
        out("")
    if result.names_recovered:
        out(
            "Names taken from another tag (the feature had no name, name:ar or name:en): "
            + ", ".join(f"{k} {v}" for k, v in sorted(result.names_recovered.items()))
            + "."
        )
        out("")

    out("## Schools per governorate")
    out("")
    out("| Governorate | Schools | Kindergartens | No pin | Governorate from nearest town |")
    out("| --- | ---: | ---: | ---: | ---: |")
    for gov in GOVERNORATES:
        rows = [s for s in result.schools if s.governorate == gov]
        if not rows:
            continue
        out(
            f"| {gov} | {sum(s.kind == 'school' for s in rows)} | {sum(s.kind == 'kindergarten' for s in rows)} "
            f"| {sum(s.lat is None for s in rows)} | {sum(s.governorate_method == 'nearest' for s in rows)} |"
        )
    nearest = sum(s.governorate_method == "nearest" for s in result.schools)
    if nearest:
        out("")
        out(
            f"{nearest} schools got the governorate of the nearest town (no boundaries file). "
            "Near a border this can be wrong; add the boundaries file (SETUP.md) for an exact answer."
        )
    out("")

    out("## Dropped, and why")
    out("")
    if not result.dropped:
        out("Nothing was dropped.")
    else:
        out("| Reason | Count |")
        out("| --- | ---: |")
        reasons: dict[str, list[Dropped]] = {}
        for d in result.dropped:
            reasons.setdefault(d.reason, []).append(d)
        for reason, items in sorted(reasons.items(), key=lambda kv: (-len(kv[1]), kv[0])):
            out(f"| {DROP_REASONS.get(reason, reason)} | {len(items)} |")
        for reason, items in sorted(reasons.items()):
            out("")
            out(f"### {DROP_REASONS.get(reason, reason)}")
            out("")
            for d in items[:max_examples]:
                out(f"- {d.source_key} {d.name or '(no name)'} [{d.file}]")
            if len(items) > max_examples:
                out(f"- and {len(items) - max_examples} more")
    out("")

    out("## Merged duplicates")
    out("")
    if not result.merged_groups:
        out("No duplicates were merged.")
    for group in result.merged_groups[: max_examples * 5]:
        out(f"- Kept {_label(group[0])}; merged {'; '.join(_label(m) for m in group[1:])}")
    out("")

    out("## Likely duplicates to check")
    out("")
    out("Not merged. If two rows are the same school, merge them in the admin panel or fix the source.")
    out("")
    if not result.likely:
        out("None.")
    for p in result.likely:
        dist = "no pin" if p.distance_m is None else f"{p.distance_m:.0f} m"
        out(f"- [{p.a.governorate}] {_label(p.a)} and {_label(p.b)}: {p.why}, {dist}, name match {p.similarity:.0%}")
    if result.problems:
        out("")
        out("## Problems with the input files")
        out("")
        for problem in result.problems:
            out(f"- {problem}")
    out("")
    return "\n".join(lines)


def summary_text(result: Result) -> str:
    by_gov: dict[str, int] = {}
    for s in result.schools:
        by_gov[s.governorate] = by_gov.get(s.governorate, 0) + 1
    reasons: dict[str, int] = {}
    for d in result.dropped:
        reasons[d.reason] = reasons.get(d.reason, 0) + 1
    kept_by_source: dict[str, int] = {}
    with_source: dict[str, int] = {}
    for s in result.schools:
        fam = source_family(s.source)
        kept_by_source[fam] = kept_by_source.get(fam, 0) + 1
        for fam2 in {source_family(k.split(":", 1)[0]) for k in s.source_keys}:
            with_source[fam2] = with_source.get(fam2, 0) + 1
    dropped_by_source: dict[str, int] = {}
    for d in result.dropped:
        fam = source_family(d.source_key.split(":", 1)[0])
        dropped_by_source[fam] = dropped_by_source.get(fam, 0) + 1
    fams = sorted(set(result.read_by_source) | set(kept_by_source))
    parts = [
        f"Read {result.read_count} entries from {len(result.files)} files.",
        "Per source (read / dropped / kept as main entry / schools with an entry from it): "
        + "; ".join(
            f"{f} {result.read_by_source.get(f, 0)} / {dropped_by_source.get(f, 0)} / {kept_by_source.get(f, 0)} / {with_source.get(f, 0)}"
            for f in fams
        ),
        f"Kept {len(result.schools)} schools; dropped {len(result.dropped)}; merged {sum(len(g) - 1 for g in result.merged_groups)} duplicates; {len(result.likely)} likely duplicates to check.",
        "Per governorate: " + ", ".join(f"{g} {n}" for g, n in sorted(by_gov.items())),
    ]
    if reasons:
        parts.append("Dropped: " + ", ".join(f"{DROP_REASONS.get(r, r)} {n}" for r, n in sorted(reasons.items(), key=lambda kv: -kv[1])))
    if result.names_recovered:
        parts.append(
            "Names recovered from other tags: " + ", ".join(f"{k} {n}" for k, n in sorted(result.names_recovered.items()))
        )
    return "\n".join(parts)
