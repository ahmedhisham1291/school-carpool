"""Schools list import for Egypt (F4, Prompt 4B). Python 3.11+, standard library only.

Reads the files the owner puts in data/schools:
  - the Humanitarian Data Exchange (HDX) "Egypt Education Facilities
    (OpenStreetMap Export)" in GeoJSON (points and polygons, plain or
    zipped) or CSV;
  - ministry, governorate or school-group lists as CSV (headers in
    English or Arabic, see LIST_HEADERS);
  - the OpenStreetMap download of fetch_osm_schools.py in data/schools/osm/
    (same shape as the HDX export, read before the files above);
  - the Wikidata download (fetch_wikidata_schools.py) in data/schools/wikidata/
    and the Overture Maps Places download (fetch_overture_schools.py) in
    data/schools/overture/;
  - which categories count (data/schools/categories.json, see CATEGORY_DEFAULTS);
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
from name_clean import fix_text, repair_mojibake, script_check

# What counts, in one place. Owner decision 16 Nov 2026 (docs/DECISIONS.md):
# schools, kindergartens and nurseries only. "university" (universities,
# colleges, higher institutes) is a switch kept OFF; when ON they are kept
# with kind "university" (the server and the search index accept that kind;
# the app and admin type filter is not built while it is off). Overridden by
# data/schools/categories.json ({"categories": {"university": false, ...}}).
CATEGORY_DEFAULTS: dict[str, bool] = {"school": True, "kindergarten": True, "nursery": True, "university": False}
CATEGORIES: dict[str, bool] = dict(CATEGORY_DEFAULTS)
CATEGORIES_FILE = "categories.json"


def set_categories(values: dict[str, bool] | None) -> dict[str, bool]:
    """Sets the categories (unknown keys ignored; schools and kindergartens
    cannot be switched off). Returns the previous setting."""
    previous = dict(CATEGORIES)
    CATEGORIES.clear()
    CATEGORIES.update(CATEGORY_DEFAULTS)
    for key, value in (values or {}).items():
        if key in ("nursery", "university") and isinstance(value, bool):
            CATEGORIES[key] = value
    return previous


def load_categories(path: Path) -> dict[str, bool]:
    """Reads categories.json (missing file: the defaults) and applies it."""
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
        values = doc.get("categories") if isinstance(doc, dict) else None
    except (OSError, ValueError):
        values = None
    set_categories(values if isinstance(values, dict) else None)
    return dict(CATEGORIES)


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
    if not (b["min_lat"] <= lat <= b["max_lat"] and b["min_lng"] <= lng <= b["max_lng"]):
        return False
    return not beyond_border(lat, lng)


def beyond_border(lat: float, lng: float) -> bool:
    """True for a point inside Egypt's box that is in a neighbour (Overture
    Places is fetched by box, not by country). Straight-line borders, with a
    small margin on Egypt's side of the doubt:
    - Libya: west of 24.98 E (the border runs along 25 E);
    - Sudan: south of 21.99 N (the 22nd parallel; Halaib, north of it, stays);
    - Gaza and Israel: east of the Rafah (31.32 N 34.22 E) - Taba (29.49 N
      34.91 E) line, north of Taba;
    - Jordan and Saudi Arabia: east of 34.95 E north of 27.5 N (east of the
      Gulf of Aqaba; Egypt's Red Sea coast is west of 34 E there)."""
    if lng < 24.98 or lat < 21.99:
        return True
    if lat >= 29.49:
        # x of the Rafah-Taba line at this latitude
        t = (31.32 - lat) / (31.32 - 29.49)
        if lng > 34.22 + t * (34.91 - 34.22) + 0.01:
            return True
    return lat > 27.5 and lng > 34.95


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
# Higher education: dropped while CATEGORIES["university"] is off.
UNIVERSITY_AMENITIES = {"university", "college"}
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
_SCHOOL_NAME_EN = re.compile(r"\b(school|schools|kindergarten|kindergartens|preschool|nursery)\b|(?<![0-9] )\bkg\b")
_KG_NAME_EN = re.compile(r"\b(kindergarten|kindergartens|preschool|nursery)\b|(?<![0-9] )\bkg\b")
_NOT_SCHOOL_NAME = (
    (re.compile(r"\b(university|faculty)\b|جامعه|^كليه|\bكليه\b"), "not_school_university"),
    (
        re.compile(
            r"\b(driving|training|music|dance|ballet|courses|course)\b"
            r"|قياده|تدريب|موسيقي|رقص|باليه|كورسات"
        ),
        "not_school_courses",
    ),
    # Tutoring centres (Egypt's "سنتر" / "مركز دروس"), exam courses: never
    # schools, even when a Facebook page files them as one (16 Nov 2026).
    (
        re.compile(
            r"\b(tutoring|tuition|lessons|ielts|toefl|icdl|sat prep)\b"
            r"|دروس|كورس|تقويه|سنتر|مجموعات تقويه"
        ),
        "not_school_tutoring",
    ),
    # Quran memorisation (دار تحفيظ, كتاب): religious study circles, not
    # schools (Al-Azhar institutes are kept before this rule).
    (re.compile(r"تحفيظ|\bقران\b|\bالقران\b|\bquran\b|\bkoran\b|\bhifz\b|(^|\s)(ال)?كتاب(\s|$)"), "not_school_quran"),
)
# Words that make a preschool category clearly a preschool (Overture).
_KID_WORDS = re.compile(
    r"\b(kids|kid|child|children|baby|babies|toddlers?|nursery|montessori|preschool|kindergarten|kg|daycare|day care)\b"
    r"|اطفال|طفل|حضانه|روضه|براعم|الصغار|كيدز|بيبي|مونتيسوري|نيرسري"
)
# Weaker words: they drop a name only when it does not itself read like a
# school's. "مركز" is also the word for a district (markaz) in Egyptian
# school names ("مدرسة ... بمركز دسوق"), and some real schools are called
# "... Academy School" or "... Center School".
# "تمريض" / nursing is weak too: in Egypt "مدرسة التمريض الثانوية" is a
# secondary (technical) school; a nursing institute or faculty is not.
_NOT_SCHOOL_NAME_WEAK = re.compile(r"\b(academy|center|centre|nursing|institute|club)\b|اكاديميه|مركز|تمريض|معهد|نادي")
# Al-Azhar institutes (معهد أزهري ابتدائي / إعدادي / ثانوي) are the
# Azhar system's primary, preparatory and secondary schools: schools for
# this app (owner, 16 Nov 2026), however they are tagged (amenity=school,
# college, none). Al-Azhar University and its faculties are not.
_AR_INSTITUTE = r"(?:^|\s)(?:ال)?معهد(?=\s|$)"
_AR_AZHAR = r"(?:^|\s)(?:ال)?ازهر"
_AZHAR_INSTITUTE = re.compile(
    rf"{_AR_INSTITUTE}.*{_AR_AZHAR}|{_AR_AZHAR}.*{_AR_INSTITUTE}|\bazhar\w*\b.*\binstitut|\binstitut\w*\b.*\bazhar"
)
# French-style school names in Egypt ("Collège de la Salle", "Collège
# Saint-Marc", "Collège du Sacré-Cœur") are schools, not colleges.
_COLLEGE_SCHOOL = re.compile(r"\bcoll[eè]ge (de|du|des|saint|st|sainte|notre)\b")
# A name that reads like a centre or institute, not a school, when the
# feature is tagged amenity=language_school (language centres).
_COURSES_LIKE = re.compile(r"\b(institute|center|centre|academy|courses)\b|معهد|مركز|سنتر|اكاديميه|كورسات")
# A named school building is not dropped for these alone (religious
# schools carry religion=*; main kept every named building=school).
_BUILDING_OK_KEYS = {"religion"}
_BUILDING_PART = re.compile(r"^(مبني|عماره|جناح|فصول|بلوك|building|block|wing|hall)\b")
_MINISTRY = re.compile(r"وزاره|مديريه|اداره|ministry|directorate|governorate|محافظه")


def is_azhar_institute(name: str) -> bool:
    n = normalize_text(name)
    return bool(n) and bool(_AZHAR_INSTITUTE.search(n)) and not re.search(r"جامعه|كليه|\buniversity\b|\bfaculty\b", n)


def name_says_school(name: str) -> str | None:
    """"kindergarten" or "school" when [name] looks like a school's name, else None."""
    n = normalize_text(name)
    if not n:
        return None
    if is_azhar_institute(name) or _COLLEGE_SCHOOL.search(n):
        return "school"
    if _KG_NAME_AR.search(n) or _KG_NAME_EN.search(n):
        return "kindergarten"
    if _SCHOOL_NAME_AR.search(n) or _SCHOOL_NAME_EN.search(n):
        return "school"
    return None


def name_says_not_school(*names: str) -> str | None:
    if any(is_azhar_institute(n) for n in names if n):
        return None
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
    street_like = any(_first(props, k) for k in ("highway", "railway", "public_transport", "place", "historic"))
    if not street_like and any(is_azhar_institute(n) for n in names if n):
        return "school", "azhar"
    for key, value, keep, drop_table in (
        ("amenity", amenity, KEEP_AMENITIES, DROP_AMENITIES),
        ("education", _first(props, "education").lower(), KEEP_EDUCATION, DROP_EDUCATION),
    ):
        if value in keep:
            return keep[value], key
        if value == "childcare" and CATEGORIES["nursery"]:
            # A nursery (حضانة): kept with the kindergartens (owner, 16 Nov 2026).
            return "kindergarten", "childcare"
        if value in UNIVERSITY_AMENITIES and CATEGORIES["university"]:
            return "university", key
        if value in drop_table:
            reason = drop_table[value]
            # Conservative: an Egyptian "language school" (مدرسة لغات) or a
            # school mapped as a college/prep school is a school when its
            # name reads like one and nothing in it says courses/university.
            by_name = next((k for k in (name_says_school(n) for n in names) if k), None)
            if (
                by_name
                and reason in ("not_school_courses", "not_school_college")
                and value not in ("driving_school", "music_school", "dancing_school", "flight_school", "cooking_school", "art_school")
                and not name_says_not_school(*names)
                and not (value == "language_school" and any(_COURSES_LIKE.search(normalize_text(n)) for n in names if n))
            ):
                return by_name, f"{key}_name"
            return None, reason
    school_building = _first(props, "building").lower() in ("school", "kindergarten")
    named_school = any(name_says_school(n) for n in names if n)

    def tolerated(key: str) -> bool:
        # A school building keeps its religion tag (church and Azhar schools).
        # Not a building=yes named "مدرسة ...": religion there is a historic
        # madrasa mosque ("مدرسة السلطان حسن"). Conservative (16 Nov 2026):
        # office=educational_institution with a school's name is how some
        # mappers tag a private school's premises.
        if key in _BUILDING_OK_KEYS and school_building:
            return True
        return key == "office" and named_school and _first(props, "office").lower() == "educational_institution"

    if amenity or any(_first(props, k) for k in OTHER_FEATURE_KEYS if not tolerated(k)):
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
            if CATEGORIES["university"]:
                return "university", "isced"
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


# Overture Maps Places taxonomy (docs repo static/taxonomy/2026-09-23.0/
# taxonomy.csv, read 16 Nov 2026): education > place_of_learning > school
# and its children, and the day-care preschool under family_service.
OVERTURE_SCHOOL_CATEGORIES = {
    "school", "elementary_school", "middle_school", "high_school", "private_school", "public_school",
    "charter_school", "montessori_school", "waldorf_school", "religious_school",
}
OVERTURE_KG_CATEGORIES = {"kindergarten", "preschool", "day_care_preschool"}
OVERTURE_NURSERY_CATEGORIES = {"child_care_and_day_care"}
OVERTURE_UNIVERSITY_CATEGORIES = {"college_university"}
OVERTURE_CATEGORIES = OVERTURE_SCHOOL_CATEGORIES | OVERTURE_KG_CATEGORIES | OVERTURE_NURSERY_CATEGORIES | OVERTURE_UNIVERSITY_CATEGORIES


def classify_overture(category: str, names: tuple[str, ...]) -> tuple[str | None, str]:
    """(kind, why) for an Overture place, the same way classify_tags does
    for OpenStreetMap. Overture categories come from business listings
    (Meta pages and others) and are looser than OSM tags, so the name
    rules apply to every Overture place: a name that says university,
    courses, driving, ... is dropped even under a school category; a
    religious school or a day-care place is kept only when its name reads
    like a school, an Azhar institute or a nursery."""
    if any(is_azhar_institute(n) for n in names if n):
        return "school", "azhar"
    by_name = next((k for k in (name_says_school(n) for n in names) if k), None)
    if category in OVERTURE_UNIVERSITY_CATEGORIES:
        return ("university", "overture") if CATEGORIES["university"] else (None, "not_school_university")
    if category not in OVERTURE_CATEGORIES:
        return None, "not_school_other"
    kid = any(_KID_WORDS.search(normalize_text(n)) for n in names if n)
    not_school = name_says_not_school(*names)
    if not_school == "not_school_courses" and kid and category in OVERTURE_KG_CATEGORIES | OVERTURE_NURSERY_CATEGORIES:
        # "Kids Academy", "Baby Club", "حضانة ... سنتر"-free kids centres:
        # filed as a preschool and named for small children -> a preschool.
        not_school = None
    if not_school:
        return None, not_school
    if category in OVERTURE_NURSERY_CATEGORIES:
        if CATEGORIES["nursery"] and (by_name == "kindergarten" or kid):
            return "kindergarten", "overture"
        return None, "not_school_childcare"
    if category == "religious_school" and not by_name:
        return None, "not_school_other"  # Quran memorisation centres and the like
    if category in OVERTURE_KG_CATEGORIES:
        return "kindergarten", "overture"
    return by_name or "school", "overture"


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
    category: str = ""  # OSM amenity/education/building value, or the Overture category
    confidence: float | None = None  # Overture's confidence
    name_fix: str = ""  # "mojibake" / "normalised" when fix_text changed a name
    review_keep: bool = False  # decisions.csv "keep": the name rules do not drop it
    raw_names: str = ""  # name | name:ar | name:en as read (review_input.csv)


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
    # City -> Area -> District (places_import.py); empty without places data.
    place_area_id: str = ""
    place_area_name_ar: str = ""
    place_area_name_en: str = ""
    place_district_id: str = ""
    confidence: float | None = None  # Overture's; ranks Overture entries in a merge
    merged_from: list[str] = field(default_factory=list)  # ids merged into this one (dedupe.py)

    def to_json(self) -> dict:
        place = (
            {
                "placeAreaId": self.place_area_id,
                "placeAreaNameAr": self.place_area_name_ar,
                "placeAreaNameEn": self.place_area_name_en,
                "placeDistrictId": self.place_district_id or None,
            }
            if self.place_area_id
            else {}
        )
        return {
            **place,
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
            **({"mergedFrom": self.merged_from} if self.merged_from else {}),
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
    raw_names = (_first(props, "name", "NAME"), _first(props, "name:ar", "name_ar"), _first(props, "name:en", "name_en"))
    # Mojibake repaired, presentation forms and fancy letters normalised,
    # controls and emoji removed, before any rule (name_clean.py).
    name, name_ar, name_en = (fix_text(n) for n in raw_names)
    name_fix = ""
    if any(repair_mojibake(n) != n for n in raw_names if n):
        name_fix = "mojibake"
    elif (name, name_ar, name_en) != raw_names:
        name_fix = "normalised"
    name_from = ""
    source_tag = str(props.get("@source") or "")
    if not (name or name_ar or name_en):
        name, name_from = recover_name(props)
        name = fix_text(name)
    if source_tag == "overture":
        # Overture Maps Places (fetch_overture_schools.py): its own category.
        category = _first(props, "overture:category").lower()
        kind, why = classify_overture(category, (name, name_ar, name_en))
        amenity = f"overture:{category or 'unknown'}"
    else:
        kind, why = classify_tags(props, (name, name_ar, name_en))
        amenity = _first(props, "amenity", "AMENITY").lower()
    # Wikidata items (fetch_wikidata_schools.py) carry "@source": "wikidata"
    # and their QID; OSM features may carry a "wikidata" tag linking one.
    is_wikidata = source_tag == "wikidata"
    is_overture = source_tag == "overture"
    qid = str(props.get("@id") if is_wikidata else props.get("wikidata") or "").strip()
    if is_overture:
        source, source_id = "overture", str(props.get("@id") or f"{Path(file).stem}-{index}")
    elif is_wikidata:
        source, source_id = "wikidata", qid or _osm_source_id(props, f"{Path(file).stem}-{index}")
    else:
        source, source_id = "osm", _osm_source_id(props, f"{Path(file).stem}-{index}")
    return RawEntry(
        source=source,
        source_id=source_id,
        kind=kind,
        amenity=amenity or "unknown",
        drop_reason="" if kind else why,
        name_from=name_from,
        wikidata=qid if _QID.match(qid) and not is_overture else "",
        category=(
            _first(props, "overture:category")
            if is_overture
            else _first(props, "amenity", "education", "building", "school", "AMENITY").lower()
        ),
        confidence=_float(str(props.get("overture:confidence"))) if is_overture else None,
        name_fix=name_fix,
        raw_names=" | ".join(raw_names),
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
OVERTURE_FOLDER = "overture"  # written by fetch_overture_schools.py (its raw/ subfolder is not read)


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
    for sub in (OSM_FOLDER, WIKIDATA_FOLDER, OVERTURE_FOLDER):
        if (folder / sub).is_dir():
            paths += sorted((folder / sub).iterdir())
    paths += sorted(folder.iterdir())
    for path in paths:
        if not path.is_file() or path.name.startswith(".") or path.name.endswith(".part") or path.name == CATEGORIES_FILE:
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
    "not_school_tutoring": "Tutoring centres and exam courses (سنتر, دروس, IELTS, ...)",
    "not_school_quran": "Quran memorisation (دار تحفيظ, كتاب)",
    "not_school_childcare": "Childcare, not a kindergarten",
    "not_school_other": "Not a school or kindergarten",
    "not_school_feature": "Named like a school but mapped as something else (street, shop, place, historic madrasa, pitch, ...)",
    "building_part": "Name of a building part (\"مبنى ب\", \"Block A\")",
    "wikidata_linked": "Wikidata item already in OpenStreetMap (same item; its names were added there)",
    "name_too_long": "Name longer than 120 characters",
    "name_script": "Name not in Arabic or English",
    "review_drop": "Dropped by the review (data/schools/review/decisions.csv)",
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
    entry: RawEntry | None = None


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
            dropped.append(Dropped(reason, key, display, e.file, e))

        if e.kind is None:
            drop(e.drop_reason or DROP_AMENITIES.get(e.amenity, "not_school_other"))
            continue
        if e.source == "wikidata" and e.source_id in linked:
            drop("wikidata_linked")
            continue
        item = wikidata_items.get(e.wikidata) if e.source != "wikidata" else None
        raw = (clean_name(e.name_ar), clean_name(e.name_en), clean_name(e.name))
        name_ar, name_en, name = (script_check(n) if n else "" for n in raw)
        if e.review_keep:
            name_ar, name_en, name = raw  # a reviewer kept it: no script check
        if any(raw) and not (name_ar or name_en or name):
            drop("name_script")
            continue
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
        if not match_tokens(name_ar) and not match_tokens(name_en) and not e.review_keep:
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
                confidence=e.confidence,
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
    keep: str = ""  # dedupe.KEEP_TEXT key: why it is deliberately not merged


@dataclass
class MergeLink:
    """One entry merged into a group's main entry, and by which rule."""

    kept_id: str
    merged_id: str
    rule: str
    distance_m: float | None


# Main entry of a merged group: owner lists, then OpenStreetMap, Wikidata,
# and Overture last (business listings: names and pins are the least
# curated; an Overture place matching an OSM school only adds its key).
_SOURCE_ORDER = {"osm": 1, "wikidata": 2, "overture": 3}


def _source_rank(s: School) -> tuple:
    # Lists from the owner (ministry, governorate, school groups) know the
    # official name best; OSM nodes before ways (a node is usually the gate).
    return (
        0 if s.source.startswith("list_") else 1,
        # Overture is never the main entry when another source has the
        # school, even one without a pin (its pin is still used, _merge).
        1 if s.source == "overture" else 0,
        0 if s.lat is not None else 1,
        _SOURCE_ORDER.get(s.source, 0),
        0 if s.source == "osm" and s.source_id.startswith("n") else 1,
        -(s.confidence or 0.0),
        s.source,
        s.source_id,
    )


def _cells(lat: float, lng: float) -> tuple[int, int]:
    # About 550 m by 480 m around Cairo: neighbours within 300 m are in the 3x3 block.
    return int(math.floor(lat / 0.005)), int(math.floor(lng / 0.005))


def find_duplicates(
    schools: list[School], links: list[MergeLink] | None = None, separate: list[tuple[str, str]] | None = None
) -> tuple[list[School], list[list[School]], list[LikelyDuplicate]]:
    """Merges the same school found more than once (rules in dedupe.py:
    same name within 500 m, 85 % alike within 300 m, Arabic/English alike
    within 300 m, one name inside the other within 100 m, a school's KG
    section within 300 m, same name within 2 km), and a list entry without
    a pin into the one same-name school of its governorate. No chains: an
    entry joins a group only if it is also the same school as the group's
    main entry by a rule, and two groups are never joined. What looks alike
    but is deliberately kept apart goes to the report with the reason.
    Returns the merged schools, the merged groups and those pairs; [links]
    (if given) receives one MergeLink per merged entry."""
    import dedupe

    likely: list[LikelyDuplicate] = []
    merge_pairs: list[tuple[float, int, int, str]] = []

    grid: dict[tuple[int, int], list[int]] = {}
    for i, s in enumerate(schools):
        if s.lat is not None and s.lng is not None:
            grid.setdefault(dedupe.cells(s.lat, s.lng), []).append(i)

    verdict_of: dict[tuple[int, int], tuple[dedupe.Verdict, float]] = {}
    # Cheap first check: two names that share no core word and no consonant
    # skeleton cannot match any rule (thousands of schools within 2 km in Cairo).
    keys = [dedupe.quick_keys(s) for s in schools]
    # Generic names ("النور", "Al Nour"): only the same site merges (dedupe.py).
    common_set = dedupe.common_cores(schools)
    common = [dedupe.is_common(s, common_set) for s in schools]
    # Pairs a reviewer kept apart (decisions.csv "separate").
    apart = {frozenset(p) for p in (separate or [])}

    def kept_apart(a: School, b: School) -> bool:
        return any(frozenset((x, y)) in apart for x in a.source_keys for y in b.source_keys)

    def judged(i: int, j: int) -> tuple[dedupe.Verdict, float] | None:
        key = (min(i, j), max(i, j))
        if key not in verdict_of:
            a, b = schools[key[0]], schools[key[1]]
            if a.lat is None or b.lat is None:
                return None
            d = distance_m(a.lat, a.lng, b.lat, b.lng)  # type: ignore[arg-type]
            if kept_apart(a, b):
                verdict_of[key] = (dedupe.Verdict(None, "separate", 0.0), d)
            else:
                verdict_of[key] = (dedupe.judge(a, b, d, common[key[0]] or common[key[1]]), d)
        return verdict_of[key]

    for i, s in enumerate(schools):
        if s.lat is None or s.lng is None:
            continue
        ci, cj = dedupe.cells(s.lat, s.lng)
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                for j in grid.get((ci + di, cj + dj), []):
                    if j <= i:
                        continue
                    t = schools[j]
                    d = distance_m(s.lat, s.lng, t.lat, t.lng)  # type: ignore[arg-type]
                    if keys[i] and keys[j] and not (keys[i] & keys[j]):
                        continue
                    if d > dedupe.FAR_SAME_NAME_M:
                        continue
                    if kept_apart(s, t):
                        continue
                    v = dedupe.judge(s, t, d, common[i] or common[j])
                    verdict_of[(i, j)] = (v, d)
                    if v.rule:
                        merge_pairs.append((d, i, j, v.rule))
                    elif v.keep and v.keep != "stage" and d <= dedupe.REPORT_M:
                        # Different stages or boys/girls are known to be
                        # different schools: not reported.
                        likely.append(LikelyDuplicate(s, t, d, v.similarity, dedupe.KEEP_TEXT[v.keep], v.keep))

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
        candidates = {j for j in candidates if not kept_apart(s, schools[j])}
        verdicts = {j: compare(s, schools[j]) for j in candidates}
        mergeable = sorted(j for j, v in verdicts.items() if v[0] == "merge")
        if len(mergeable) == 1:
            merge_pairs.append((math.inf, i, mergeable[0], "list_no_pin"))
        for j in sorted(candidates):
            verdict, sim, why = verdicts[j]
            if len(mergeable) > 1 and verdict == "merge":
                likely.append(LikelyDuplicate(s, schools[j], None, sim, "list entry without a pin matches several schools", "list"))
            elif verdict == "report":
                likely.append(LikelyDuplicate(s, schools[j], None, sim, f"{why}, list entry without a pin", "one_sided"))

    # Closest pairs first (stronger rules first at the same distance). A
    # group grows only by single entries that are the same school as its
    # main entry.
    group_of = list(range(len(schools)))
    members: dict[int, list[int]] = {i: [i] for i in range(len(schools))}
    rule_of: dict[int, tuple[str, float | None]] = {}

    def main_entry(g: int) -> int:
        return min(members[g], key=lambda k: _source_rank(schools[k]))

    order = {r: n for n, r in enumerate(dedupe.RULES + ("list_no_pin",))}
    for d, i, j, rule in sorted(merge_pairs, key=lambda p: (p[0], order[p[3]], schools[p[1]].id, schools[p[2]].id)):
        gi, gj = group_of[i], group_of[j]
        if gi == gj:
            continue
        if len(members[gi]) > 1 and len(members[gj]) > 1:
            likely.append(LikelyDuplicate(schools[i], schools[j], None if d == math.inf else d, 1.0, dedupe.KEEP_TEXT["chain_conflict"], "chain_conflict"))
            continue
        group, single = (gi, j) if len(members[gi]) > 1 or (len(members[gj]) == 1 and gi < gj) else (gj, i)
        main_i = main_entry(group)
        if main_i != single and rule != "list_no_pin":
            check = judged(single, main_i)
            if check is None or not check[0].rule:
                likely.append(LikelyDuplicate(schools[single], schools[main_i], None if d == math.inf else d, 1.0, dedupe.KEEP_TEXT["chain_conflict"], "chain_conflict"))
                continue
        dist = None if d == math.inf else d
        for k in (i, j):
            rule_of.setdefault(k, (rule, dist))
        for k in members.pop(group_of[single]):
            group_of[k] = group
            members[group].append(k)

    merged: list[School] = []
    merged_groups: list[list[School]] = []
    for g in sorted(members):
        group_members = [schools[k] for k in members[g]]
        survivor = _merge(group_members)
        merged.append(survivor)
        if len(group_members) > 1:
            merged_groups.append(sorted(group_members, key=_source_rank))
            if links is not None:
                for k in members[g]:
                    if schools[k].id != survivor.id:
                        rule, dist = rule_of.get(k, ("same_name_500m", None))
                        links.append(MergeLink(survivor.id, schools[k].id, rule, dist))
    merged.sort(key=lambda s: s.id)
    merged_groups.sort(key=lambda g: g[0].id)
    # A pair whose two entries ended in one group is not "to check".
    final = {schools[k].id: g for g in members for k in members[g]}
    likely = [p for p in likely if final.get(p.a.id) != final.get(p.b.id)]
    seen: set[tuple[str, str]] = set()
    unique: list[LikelyDuplicate] = []
    for p in sorted(likely, key=lambda p: (p.a.governorate, p.a.id, p.b.id)):
        key = tuple(sorted((p.a.id, p.b.id)))
        if key not in seen:
            seen.add(key)  # type: ignore[arg-type]
            unique.append(p)
    if links is not None:
        links.sort(key=lambda l: (l.kept_id, l.merged_id))
    return merged, merged_groups, unique


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

    # Most precise position: OSM, then Wikidata, then the most confident Overture (members are ranked so).
    located = next((m for m in members if m.lat is not None), primary)
    governorate_from = next((m for m in members if m.governorate_method in ("given", "boundary")), located)
    return School(
        id=primary.id,
        source=primary.source,
        source_id=primary.source_id,
        source_keys=sorted({k for m in members for k in m.source_keys}),
        name_ar=best("name_ar", prefer_arabic=True),
        name_en=best("name_en", prefer_arabic=False),
        kind=primary.kind if primary.kind == "university" else ("kindergarten" if all(m.kind == "kindergarten" for m in members) else "school"),
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
        confidence=primary.confidence,
        merged_from=sorted({m.id for m in members if m.id != primary.id} | {x for m in members for x in m.merged_from}),
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
    boundaries: Boundaries | None = None
    entries: list[RawEntry] = field(default_factory=list)
    merge_links: list[MergeLink] = field(default_factory=list)
    name_fixes: dict[str, int] = field(default_factory=dict)  # "mojibake" / "normalised" -> entries
    review: "ReviewOutcome | None" = None


def run(folder: Path, decisions: list["Decision"] | None = None) -> Result:
    entries, boundaries, files, problems = read_inputs(folder)
    review = ReviewOutcome()
    apply_entry_decisions(decisions or [], entries, review)
    cleaned, dropped = clean(entries, boundaries)
    links: list[MergeLink] = []
    # "separate": two entries the rules would merge that are different schools.
    separate = [(d.key, d.value) for d in (decisions or []) if d.action == "separate"]
    for d in decisions or []:
        if d.action == "separate":
            review.count(d.action)
    merged, groups, likely = find_duplicates(cleaned, links, separate)
    merged, groups = apply_merge_decisions(decisions or [], merged, groups, links, review)
    # A reviewer's kind is final, also after merges.
    kinds = {d.key: d.value for d in (decisions or []) if d.action == "set_kind"}
    for sch in merged:
        for k in sch.source_keys:
            if k in kinds:
                sch.kind = kinds[k]
    read_by_source: dict[str, int] = {}
    recovered: dict[str, int] = {}
    fixes: dict[str, int] = {}
    for e in entries:
        fam = source_family(e.source)
        read_by_source[fam] = read_by_source.get(fam, 0) + 1
        if e.name_from:
            recovered[e.name_from] = recovered.get(e.name_from, 0) + 1
        if e.name_fix:
            fixes[e.name_fix] = fixes.get(e.name_fix, 0) + 1
    result = Result(merged, dropped, groups, likely, files, problems, len(entries), read_by_source, recovered, boundaries, entries, links)
    result.name_fixes = fixes
    result.review = review
    return result


# ---------------------------------------------------------------------------
# Review decisions (data/schools/review/decisions.csv), applied after the rules
# ---------------------------------------------------------------------------

REVIEW_FOLDER = "review"
DECISIONS_FILE = "decisions.csv"
DECISION_COLUMNS = ("source", "source_id", "action", "value", "reason")
DECISION_ACTIONS = ("drop", "rename_ar", "rename_en", "merge_into", "separate", "keep", "set_kind")
_OSM_LONG_ID = re.compile(r"^(node|way|relation)/(\d+)$")


@dataclass
class Decision:
    source: str
    source_id: str
    action: str
    value: str
    reason: str
    line: int

    @property
    def key(self) -> str:
        return f"{self.source}:{self.source_id}"


@dataclass
class ReviewOutcome:
    applied: dict[str, int] = field(default_factory=dict)  # action -> count
    unmatched: list[Decision] = field(default_factory=list)  # key (or merge target) not in this run
    problems: list[str] = field(default_factory=list)  # rows that could not be read

    def count(self, action: str) -> None:
        self.applied[action] = self.applied.get(action, 0) + 1


def normalize_key(source: str, source_id: str) -> tuple[str, str]:
    """The importer's source key: osm n123 / w123 / r123 ("node/123" is
    accepted), wikidata Q123, overture <id>, list_<file> <row id>."""
    source = source.strip().lower()
    source_id = source_id.strip()
    m = _OSM_LONG_ID.match(source_id)
    if source == "osm" and m:
        source_id = f"{m.group(1)[0]}{m.group(2)}"
    return source, source_id


def load_decisions(path: Path) -> tuple[list[Decision], list[str]]:
    """The review's decisions (UTF-8 CSV, header source,source_id,action,value,reason).
    Rows that cannot be used are reported, never fatal."""
    if not path.exists():
        return [], []
    problems: list[str] = []
    out: list[Decision] = []
    reader = csv.DictReader(io.StringIO(path.read_text(encoding="utf-8-sig")))
    missing = [c for c in DECISION_COLUMNS[:3] if c not in (reader.fieldnames or [])]
    if missing:
        return [], [f"{path.name}: missing columns {', '.join(missing)}"]
    for n, row in enumerate(reader, start=2):
        source, source_id = normalize_key(row.get("source") or "", row.get("source_id") or "")
        action = (row.get("action") or "").strip().lower()
        value = (row.get("value") or "").strip()
        if not source or not source_id or action not in DECISION_ACTIONS:
            problems.append(f"{path.name} line {n}: unusable row (source, source_id and an action of {', '.join(DECISION_ACTIONS)})")
            continue
        if action in ("rename_ar", "rename_en") and not value:
            problems.append(f"{path.name} line {n}: {action} needs a value")
            continue
        if action == "set_kind" and value not in ("school", "kindergarten"):
            problems.append(f"{path.name} line {n}: set_kind value must be school or kindergarten")
            continue
        if action in ("merge_into", "separate"):
            if ":" not in value and "," not in value:
                problems.append(f"{path.name} line {n}: {action} value must be a source key like osm:n123")
                continue
            vs, vi = re.split("[:,]", value, maxsplit=1)
            value = ":".join(normalize_key(vs, vi))
        out.append(Decision(source, source_id, action, value, (row.get("reason") or "").strip(), n))
    return out, problems


def apply_entry_decisions(decisions: list[Decision], entries: list[RawEntry], review: ReviewOutcome) -> None:
    """drop / keep / set_kind / rename_* on the raw entries, before cleaning
    (merge_into comes after the duplicates, apply_merge_decisions)."""
    by_key: dict[str, list[RawEntry]] = {}
    for e in entries:
        by_key.setdefault(f"{e.source}:{e.source_id}", []).append(e)
    order = {"keep": 0, "set_kind": 1, "rename_ar": 2, "rename_en": 2, "drop": 3}
    for d in sorted((d for d in decisions if d.action not in ("merge_into", "separate")), key=lambda d: (order[d.action], d.line)):
        targets = by_key.get(d.key)
        if not targets:
            review.unmatched.append(d)
            continue
        for e in targets:
            if d.action == "drop":
                e.kind, e.drop_reason, e.review_keep = None, "review_drop", False
            elif d.action == "keep":
                if e.kind is None:
                    e.kind = next((k for k in (name_says_school(n) for n in (e.name, e.name_ar, e.name_en) if n) if k), "school")
                    e.drop_reason = ""
                e.review_keep = True
            elif d.action == "set_kind":
                if e.kind is not None:
                    e.kind = d.value
            elif d.action == "rename_ar":
                e.name_ar = d.value
            elif d.action == "rename_en":
                e.name_en = d.value
        review.count(d.action)


def apply_merge_decisions(
    decisions: list[Decision], schools: list[School], groups: list[list[School]], links: list[MergeLink], review: ReviewOutcome
) -> tuple[list[School], list[list[School]]]:
    """merge_into: the kept school holding key A joins the one holding key B
    (B's school stays the main entry)."""
    merges = [d for d in decisions if d.action == "merge_into"]
    if not merges:
        return schools, groups
    holder: dict[str, School] = {k: s for s in schools for k in s.source_keys}
    out = {s.id: s for s in schools}
    for d in merges:
        a, b = holder.get(d.key), holder.get(d.value)
        if a is None or b is None:
            review.unmatched.append(d)
            continue
        a, b = out.get(a.id, a), out.get(b.id, b)
        if a.id == b.id:
            review.count(d.action)
            continue
        combined = _merge([b, a])
        combined = School(**{**combined.__dict__, "id": b.id, "source": b.source, "source_id": b.source_id,
                             "lat": b.lat if b.lat is not None else a.lat, "lng": b.lng if b.lng is not None else a.lng,
                             "merged_from": sorted(set(b.merged_from) | set(a.merged_from) | {a.id})})
        out.pop(a.id, None)
        out[b.id] = combined
        for k in combined.source_keys:
            holder[k] = combined
        links.append(MergeLink(b.id, a.id, "review", None))
        review.count(d.action)
    links.sort(key=lambda l: (l.kept_id, l.merged_id))
    return sorted(out.values(), key=lambda s: s.id), groups


def review_lines(result: "Result") -> list[str]:
    r = result.review
    if r is None or not (r.applied or r.unmatched or r.problems):
        return []
    lines = [
        "Review decisions applied: " + (", ".join(f"{a} {n}" for a, n in sorted(r.applied.items())) or "none")
        + f"; not matched in this run: {len(r.unmatched)}"
    ]
    for d in r.unmatched[:20]:
        lines.append(f"  not matched: line {d.line} {d.key} {d.action} {d.value}".rstrip())
    lines += [f"  {p}" for p in r.problems[:20]]
    return lines


REVIEW_INPUT_COLUMNS = (
    "source", "source_id", "name_ar", "name_en", "raw_names", "kind", "category", "confidence",
    "governorate", "lat", "lon", "drop_reason", "group_id",
)


def write_review_input(result: "Result", path: Path) -> int:
    """build/schools/review_input.csv: one row per entry read (kept or
    dropped), for the review of every name. Public place data only;
    positions rounded to 3 decimals (about 100 m)."""
    dropped = {}
    for d in result.dropped:
        dropped.setdefault(d.source_key, d.reason)
    school_of = {k: s for s in result.schools for k in s.source_keys}
    buffer = io.StringIO()
    writer = csv.DictWriter(buffer, fieldnames=REVIEW_INPUT_COLUMNS)
    writer.writeheader()
    seen: set[str] = set()
    for e in result.entries:
        key = f"{e.source}:{e.source_id}"
        if key in seen:
            continue
        seen.add(key)
        s = school_of.get(key)
        gov = s.governorate if s else (governorate_code(e.governorate_text) or "")
        if not gov and e.lat is not None and e.lng is not None:
            at = result.boundaries.governorate_at(e.lat, e.lng) if result.boundaries else None
            gov = at or nearest_town(e.lat, e.lng)[0]
        writer.writerow(
            {
                "source": e.source,
                "source_id": e.source_id,
                "name_ar": s.name_ar if s else e.name_ar,
                "name_en": s.name_en if s else e.name_en,
                "raw_names": e.raw_names,
                "kind": s.kind if s else (e.kind or ""),
                "category": e.category,
                "confidence": "" if e.confidence is None else f"{e.confidence:.2f}",
                "governorate": gov,
                "lat": "" if e.lat is None else f"{e.lat:.3f}",
                "lon": "" if e.lng is None else f"{e.lng:.3f}",
                "drop_reason": "" if s else dropped.get(key, ""),
                "group_id": s.id if s else "",
            }
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\ufeff" + buffer.getvalue(), encoding="utf-8")
    return len(seen)


def source_family(source: str) -> str:
    """"osm", "wikidata", "overture" or "owner CSV" (list_<file>)."""
    if source.startswith("list_"):
        return "owner CSV"
    return source


DROPPED_CSV_COLUMNS = ("name", "name_ar", "name_en", "source", "source_id", "category", "governorate", "confidence", "file")


def dropped_rows(result: Result) -> dict[str, list[dict[str, str]]]:
    """Dropped entries per reason, as CSV rows (public place data only:
    names, source, category, governorate, Overture confidence; no position)."""
    out: dict[str, list[dict[str, str]]] = {}
    for d in result.dropped:
        e = d.entry
        gov = ""
        if e is not None:
            gov = governorate_code(e.governorate_text) or ""
            if not gov and e.lat is not None and e.lng is not None:
                at = result.boundaries.governorate_at(e.lat, e.lng) if result.boundaries else None
                gov = at or nearest_town(e.lat, e.lng)[0]
        source, _, source_id = d.source_key.partition(":")
        out.setdefault(d.reason, []).append(
            {
                "name": d.name,
                "name_ar": e.name_ar if e else "",
                "name_en": e.name_en if e else "",
                "source": source,
                "source_id": source_id,
                "category": e.category if e else "",
                "governorate": gov,
                "confidence": "" if e is None or e.confidence is None else f"{e.confidence:.2f}",
                "file": d.file,
            }
        )
    return out


def write_dropped_csvs(result: Result, folder: Path) -> list[tuple[str, int, Path]]:
    """build/schools/dropped_<reason>.csv (UTF-8 with BOM so Excel shows
    Arabic). Returns (reason, count, path), largest first. Old files of
    reasons that no longer occur are removed."""
    folder.mkdir(parents=True, exist_ok=True)
    for old in folder.glob("dropped_*.csv"):
        old.unlink()
    written: list[tuple[str, int, Path]] = []
    for reason, rows in dropped_rows(result).items():
        path = folder / f"dropped_{reason}.csv"
        buffer = io.StringIO()
        writer = csv.DictWriter(buffer, fieldnames=DROPPED_CSV_COLUMNS)
        writer.writeheader()
        for row in sorted(rows, key=lambda r: (r["source"], r["governorate"], r["name"])):
            writer.writerow(row)
        path.write_text("\ufeff" + buffer.getvalue(), encoding="utf-8")
        written.append((reason, len(rows), path))
    written.sort(key=lambda w: (-w[1], w[0]))
    return written


def dropped_by_source_lines(result: Result) -> list[str]:
    """"Dropped per reason and source: No name: osm 373, overture 2; ..."."""
    table: dict[str, dict[str, int]] = {}
    for d in result.dropped:
        fam = source_family(d.source_key.split(":", 1)[0])
        table.setdefault(d.reason, {})[fam] = table.setdefault(d.reason, {}).get(fam, 0) + 1
    ranked = sorted(table.items(), key=lambda kv: -sum(kv[1].values()))
    return [
        "Dropped per reason and source: "
        + "; ".join(f"{DROP_REASONS.get(r, r)}: " + ", ".join(f"{f} {n}" for f, n in sorted(c.items())) for r, c in ranked)
    ] if ranked else []


def dedupe_lines(result: Result) -> list[str]:
    """Auto-merged per rule, and what is left to check (and why)."""
    import dedupe

    per_rule: dict[str, int] = {}
    for link in result.merge_links:
        per_rule[link.rule] = per_rule.get(link.rule, 0) + 1
    left: dict[str, int] = {}
    for p in result.likely:
        left[p.keep or "similar"] = left.get(p.keep or "similar", 0) + 1
    lines = [
        f"Auto-merged duplicates: {len(result.merge_links)}"
        + (" (" + ", ".join(f"{dedupe.RULE_TEXT.get(r, r)} {n}" for r, n in sorted(per_rule.items(), key=lambda kv: -kv[1])) + ")" if per_rule else "")
    ]
    lines.append(
        f"Left apart on purpose (look alike, not merged): {len(result.likely)}"
        + (" (" + ", ".join(f"{dedupe.KEEP_TEXT.get(k, k)} {n}" for k, n in sorted(left.items(), key=lambda kv: -kv[1])) + ")" if left else "")
    )
    return lines


MERGED_CSV_COLUMNS = ("group", "kept_id", "merged_id", "kept_name_ar", "kept_name_en", "merged_name_ar", "merged_name_en", "distance_m", "rule")


def write_merged_csv(result: Result, groups_before: dict[str, School], path: Path) -> int:
    """build/schools/merged.csv: one row per entry merged into another
    (group = the kept id). [groups_before] maps every entry id to its
    School before the merge (for its own names)."""
    kept = {s.id: s for s in result.schools}
    buffer = io.StringIO()
    writer = csv.DictWriter(buffer, fieldnames=MERGED_CSV_COLUMNS)
    writer.writeheader()
    for link in result.merge_links:
        k = kept.get(link.kept_id)
        m = groups_before.get(link.merged_id)
        writer.writerow(
            {
                "group": link.kept_id,
                "kept_id": link.kept_id,
                "merged_id": link.merged_id,
                "kept_name_ar": k.name_ar if k else "",
                "kept_name_en": k.name_en if k else "",
                "merged_name_ar": m.name_ar if m else "",
                "merged_name_en": m.name_en if m else "",
                "distance_m": "" if link.distance_m is None else f"{link.distance_m:.0f}",
                "rule": link.rule,
            }
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\ufeff" + buffer.getvalue(), encoding="utf-8")
    return len(result.merge_links)


def schools_json(result: Result, generated_at: str) -> dict:
    return {
        "format": "school-carpool-schools/1",
        "generatedAt": generated_at,
        "files": result.files,
        "count": len(result.schools),
        "schools": [s.to_json() for s in result.schools],
        # Entries the rules drop now (the loader takes earlier copies out of
        # the list: out of search, kept as documents). Not the bookkeeping
        # reasons (an entry read twice, a Wikidata item already in OSM).
        "dropped": sorted(
            ({"key": d.source_key, "reason": d.reason} for d in result.dropped if d.reason not in ("repeated_source_id", "wikidata_linked")),
            key=lambda x: x["key"],
        ),
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
    if result.name_fixes:
        parts.append(
            "Names fixed: "
            + ", ".join(f"{'mojibake repaired' if k == 'mojibake' else 'presentation forms, fancy letters, controls or emoji cleaned'} {n}" for k, n in sorted(result.name_fixes.items()))
        )
    if result.names_recovered:
        parts.append(
            "Names recovered from other tags: " + ", ".join(f"{k} {n}" for k, n in sorted(result.names_recovered.items()))
        )
    return "\n".join(parts)
