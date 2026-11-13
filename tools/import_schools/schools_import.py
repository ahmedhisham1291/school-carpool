"""Schools list import for Egypt (F4, Prompt 4B). Python 3.11+, standard library only.

Reads the files the owner puts in data/schools:
  - the Humanitarian Data Exchange (HDX) "Egypt Education Facilities
    (OpenStreetMap Export)" in GeoJSON (points and polygons, plain or
    zipped) or CSV;
  - ministry, governorate or school-group lists as CSV (headers in
    English or Arabic, see LIST_HEADERS);
  - optionally governorate boundaries (GeoJSON, admin level 1) in
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

from egypt_places import EGYPT_BOUNDS, GOVERNORATE_ALIASES, GOVERNORATES, TOWNS

MERGE_DISTANCE_M = 300.0
NEARBY_REPORT_DISTANCE_M = 1500.0
MERGE_SIMILARITY = 0.8
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
    "مدرسه", "مدارس", "المدرسه", "حضانه", "روضه", "school", "schools", "kg",
    "kindergarten", "nursery", "the", "al", "el", "of", "for", "and", "و",
    "ابتدائيه", "اعداديه", "ثانويه", "رسميه", "primary", "preparatory", "secondary",
    "level", "مرحله",
}
_SYNONYMS = {
    "intl": "international", "int": "international", "internationale": "international",
    "lang": "language", "languages": "language", "لغات": "لغات", "للغات": "لغات",
    "الدوليه": "دوليه", "دولي": "دوليه", "الدولي": "دوليه",
    "amer": "american", "brit": "british", "sch": "school",
}


def match_tokens(name: str) -> tuple[str, ...]:
    """Tokens used to compare two names: normalized, generic words removed,
    a leading Arabic article dropped from longer words."""
    tokens = []
    for token in normalize_text(name).split():
        token = _SYNONYMS.get(token, token)
        if token.startswith("ال") and len(token) > 4:
            token = token[2:]
        token = _SYNONYMS.get(token, token)
        if token in _GENERIC or token.startswith("مدرس"):
            continue
        tokens.append(token)
    return tuple(tokens)


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


def _tokens_match(a: str, b: str) -> bool:
    if a == b:
        return True
    return min(len(a), len(b)) >= 4 and _edit_distance_at_most_one(a, b)


def token_similarity(a: tuple[str, ...], b: tuple[str, ...]) -> float:
    """How alike two names are, 0 to 1: the share of words that match (one
    spelling slip allowed in words of 4+ letters). When every word of the
    shorter name is in the longer one ("El Alsson" and "El Alsson British
    International"), the score is at least 0.85."""
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
    share = hits / len(b)
    contained = 0.85 if hits == len(a) else 0.0
    return max(share, contained)


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


def _ring_contains(ring: list, lat: float, lng: float) -> bool:
    inside = False
    n = len(ring)
    for i in range(n):
        x1, y1 = ring[i][0], ring[i][1]
        x2, y2 = ring[(i + 1) % n][0], ring[(i + 1) % n][1]
        if (y1 > lat) != (y2 > lat):
            x = x1 + (lat - y1) * (x2 - x1) / (y2 - y1)
            if lng < x:
                inside = not inside
    return inside


def _polygon_contains(polygon: list, lat: float, lng: float) -> bool:
    if not polygon or not _ring_contains(polygon[0], lat, lng):
        return False
    return not any(_ring_contains(hole, lat, lng) for hole in polygon[1:])


@dataclass
class Boundaries:
    """Governorate polygons (HDX "Egypt - Subnational Administrative Boundaries", admin 1)."""

    shapes: list[tuple[str, list]] = field(default_factory=list)

    def governorate_at(self, lat: float, lng: float) -> str | None:
        for code, polygons in self.shapes:
            if any(_polygon_contains(p, lat, lng) for p in polygons):
                return code
        return None

    @staticmethod
    def load(paths: Iterable[Path], problems: list[str]) -> "Boundaries":
        result = Boundaries()
        for path in paths:
            for feature in _read_geojson_features(path.read_bytes()):
                props = feature.get("properties") or {}
                geometry = feature.get("geometry") or {}
                code = None
                for key in ("ADM1_EN", "ADM1_AR", "admin1Name_en", "admin1Name_ar", "name:en", "name", "NAME_1", "shapeName"):
                    code = governorate_code(str(props.get(key) or ""))
                    if code:
                        break
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
}


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
    if osm_type in ("node", "way", "relation", "n", "w", "r"):
        return f"{osm_type[0]}{raw.lstrip('-')}"
    return raw.lstrip("-")


def _osm_entry(props: dict, lat: float | None, lng: float | None, file: str, index: int) -> RawEntry:
    amenity = _first(props, "amenity", "AMENITY").lower()
    kind = KEEP_AMENITIES.get(amenity)
    if not amenity and _first(props, "building").lower() in ("school", "kindergarten"):
        kind = _first(props, "building").lower()
        amenity = kind
    return RawEntry(
        source="osm",
        source_id=_osm_source_id(props, f"{Path(file).stem}-{index}"),
        kind=kind,
        amenity=amenity or "unknown",
        name=_first(props, "name", "NAME"),
        name_ar=_first(props, "name:ar", "name_ar"),
        name_en=_first(props, "name:en", "name_en"),
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


def read_csv(data: bytes, file: str, source_name: str) -> tuple[list[RawEntry], list[str]]:
    """An OSM export CSV (has an amenity column) or a school list CSV."""
    text = data.decode("utf-8-sig")
    reader = csv.DictReader(io.StringIO(text))
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
        raw_id = row.get(cols["id"] or "", "").strip() or str(i + 1)
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


def read_inputs(folder: Path) -> tuple[list[RawEntry], Boundaries, list[str], list[str]]:
    """All entries in [folder] (not its subfolders, except boundaries/), the
    boundaries, the files read and any problems."""
    entries: list[RawEntry] = []
    problems: list[str] = []
    files_read: list[str] = []
    boundary_dir = folder / "boundaries"
    boundaries = Boundaries.load(sorted(boundary_dir.glob("*.geojson")) + sorted(boundary_dir.glob("*.json")), problems) if boundary_dir.is_dir() else Boundaries()

    def take(name: str, data: bytes) -> None:
        suffix = Path(name).suffix.lower()
        if suffix in (".geojson", ".json"):
            entries.extend(read_osm_geojson(data, name))
            files_read.append(name)
        elif suffix == ".csv":
            found, ignored = read_csv(data, name, _list_source_name(Path(name)))
            entries.extend(found)
            files_read.append(name)
            if ignored:
                problems.append(f"{name}: columns not used: {', '.join(ignored)}")

    for path in sorted(folder.iterdir()):
        if not path.is_file() or path.name.startswith("."):
            continue
        if path.suffix.lower() == ".zip":
            with zipfile.ZipFile(path) as archive:
                for member in sorted(archive.namelist()):
                    take(f"{path.name}/{member}", archive.read(member))
        elif path.suffix.lower() in (".geojson", ".json", ".csv"):
            take(path.name, path.read_bytes())
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
    "not_school_courses": "Courses (language, music, driving)",
    "not_school_childcare": "Childcare, not a kindergarten",
    "not_school_other": "Not a school or kindergarten",
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
    for e in entries:
        key = f"{e.source}:{e.source_id}"
        display = e.name or e.name_ar or e.name_en

        def drop(reason: str) -> None:
            dropped.append(Dropped(reason, key, display, e.file))

        if e.kind is None:
            drop(DROP_AMENITIES.get(e.amenity, "not_school_other"))
            continue
        name_ar = clean_name(e.name_ar)
        name_en = clean_name(e.name_en)
        name = clean_name(e.name)
        if name:
            if has_arabic(name):
                name_ar = name_ar or name
            else:
                name_en = name_en or name
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
                source_keys=[key],
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
            )
        )
    return schools, dropped


# ---------------------------------------------------------------------------
# Duplicates
# ---------------------------------------------------------------------------


def name_similarity(a: School, b: School) -> float:
    pairs = [(a.match_ar, b.match_ar), (a.match_en, b.match_en), (a.match_ar, b.match_en), (a.match_en, b.match_ar)]
    return max(token_similarity(x, y) for x, y in pairs)


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
    """Merges entries with a similar name within 300 m (and list entries
    without a pin into a same-name school in the same governorate). Returns
    the merged schools, the merged groups, and pairs to check by hand."""
    parent = list(range(len(schools)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(i: int, j: int) -> None:
        ri, rj = find(i), find(j)
        if ri != rj:
            parent[max(ri, rj)] = min(ri, rj)

    grid: dict[tuple[int, int], list[int]] = {}
    for i, s in enumerate(schools):
        if s.lat is not None and s.lng is not None:
            grid.setdefault(_cells(s.lat, s.lng), []).append(i)

    likely: list[LikelyDuplicate] = []
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
                    sim = name_similarity(s, t)
                    if d <= MERGE_DISTANCE_M and sim >= MERGE_SIMILARITY:
                        union(i, j)
                    elif d <= MERGE_DISTANCE_M and sim >= REPORT_SIMILARITY:
                        likely.append(LikelyDuplicate(s, t, d, sim, "similar name within 300 m"))
                    elif sim >= 0.999 and s.kind == t.kind:
                        likely.append(LikelyDuplicate(s, t, d, sim, "same name 300 m to 1.5 km apart"))

    # Entries without a pin (lists): merge into a same-name school of the
    # same governorate (and city when both have one).
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
        if len(candidates) == 1:
            union(i, next(iter(candidates)))
        elif len(candidates) > 1:
            for j in sorted(candidates):
                likely.append(LikelyDuplicate(s, schools[j], None, 1.0, "list entry without a pin matches several schools"))

    groups: dict[int, list[School]] = {}
    for i, s in enumerate(schools):
        groups.setdefault(find(i), []).append(s)

    merged: list[School] = []
    merged_groups: list[list[School]] = []
    for members in groups.values():
        merged.append(_merge(members))
        if len(members) > 1:
            merged_groups.append(sorted(members, key=_source_rank))
    merged.sort(key=lambda s: s.id)
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


def run(folder: Path) -> Result:
    entries, boundaries, files, problems = read_inputs(folder)
    cleaned, dropped = clean(entries, boundaries)
    merged, groups, likely = find_duplicates(cleaned)
    return Result(merged, dropped, groups, likely, files, problems, len(entries))


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
    parts = [
        f"Read {result.read_count} entries from {len(result.files)} files.",
        f"Kept {len(result.schools)} schools; dropped {len(result.dropped)}; merged {sum(len(g) - 1 for g in result.merged_groups)} duplicates; {len(result.likely)} likely duplicates to check.",
        "Per governorate: " + ", ".join(f"{g} {n}" for g, n in sorted(by_gov.items())),
    ]
    if reasons:
        parts.append("Dropped: " + ", ".join(f"{DROP_REASONS.get(r, r)} {n}" for r, n in sorted(reasons.items())))
    return "\n".join(parts)
