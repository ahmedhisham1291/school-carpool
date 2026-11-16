"""City -> Area -> District for the schools import and the addresses (F4, F46).

City is the governorate (27 codes, egypt_places.py). Area (qism, markaz or
new city: Nasr City, Maadi, Sheikh Zayed, Smouha ...) and District (a
neighbourhood inside an area: "الحي 14", التجمع الخامس ...) come from the
OpenStreetMap download of fetch_osm_places.py.

Which admin_level is an Area and which a District in Egypt is MEASURED,
not assumed: for each level 5 to 10, the share of the located schools that
fall inside one of its polygons ("coverage"). The Area level is the finest
of 5 to 7 that covers at least AREA_MIN_COVERAGE of the schools (else the
best covered); where it has no polygon, coarser levels are tried first,
then finer ones, point by point. Districts: the finest of 8 to 10 that
covers at least DISTRICT_MIN_COVERAGE, else the best, with the same
fallback; where no district polygon holds a point, the nearest named
place=suburb|quarter|neighbourhood inside the same area (at most
POINT_DISTRICT_KM away) is the district.

Output (places.json, input of functions/scripts/load_schools.ts):
  areas:     id, governorate, nameAr, nameEn, level, centre, bbox, rings
             (simplified outer rings, [lat, lng] pairs), schoolCount
  districts: id, areaId, governorate, nameAr, nameEn, source
             (osm-boundary | osm-place), centre, bbox?, rings?, schoolCount
Each school gets placeAreaId, placeAreaNameAr/En and placeDistrictId.
Standard library only.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from egypt_places import GOVERNORATE_ALIASES
from schools_import import Boundaries, School, _IndexedRing, distance_m, has_arabic, nearest_town, normalize_text

AREA_LEVELS = (5, 6, 7)
DISTRICT_LEVELS = (8, 9, 10)
AREA_MIN_COVERAGE = 0.5
DISTRICT_MIN_COVERAGE = 0.3
POINT_DISTRICT_KM = 1.5
PLACES_FOLDER = "places"
# Areas from the ADM2 file (fetch_adm2.py), when present, replace the OSM
# area levels: OpenStreetMap has almost no qism/markaz boundaries in Egypt.
ADM2_FILE = "egypt_adm2.geojson"
ADM2_LEVEL = 7  # the level stored with the area (the server checks finer levels first)
PLACES_FORMAT = "school-carpool-places/1"


@dataclass
class Shape:
    id: str
    level: int
    name_ar: str
    name_en: str
    rings: list[list[list[float]]]  # [lng, lat] outer rings
    governorate: str = ""
    centre: tuple[float, float] = (0.0, 0.0)  # (lat, lng)
    _index: list[_IndexedRing] = field(default_factory=list, repr=False)

    def __post_init__(self) -> None:
        self._index = [_IndexedRing(r) for r in self.rings if len(r) >= 4]
        # Without each ring's closing point (it repeats the first one).
        pts = [p for r in self.rings for p in (r[:-1] if len(r) > 1 and r[0] == r[-1] else r)]
        if pts and self.centre == (0.0, 0.0):
            self.centre = (sum(p[1] for p in pts) / len(pts), sum(p[0] for p in pts) / len(pts))

    def contains(self, lat: float, lng: float) -> bool:
        return any(r.contains(lat, lng) for r in self._index)

    def bbox(self) -> dict[str, float]:
        pts = [p for r in self.rings for p in r]
        return {
            "minLat": round(min(p[1] for p in pts), 6),
            "minLng": round(min(p[0] for p in pts), 6),
            "maxLat": round(max(p[1] for p in pts), 6),
            "maxLng": round(max(p[0] for p in pts), 6),
        }


@dataclass
class PlacePoint:
    id: str
    kind: str
    name_ar: str
    name_en: str
    lat: float
    lng: float


def _names(props: dict) -> tuple[str, str]:
    name = str(props.get("name") or "").strip()
    ar = str(props.get("name:ar") or "").strip() or (name if has_arabic(name) else "")
    en = str(props.get("name:en") or "").strip() or (name if name and not has_arabic(name) else "")
    return ar or en, en or ar


def _osm_id(props: dict) -> str:
    return f"osm-{str(props.get('osm_type', 'r'))[:1]}{props.get('osm_id')}"


def load(folder: Path) -> tuple[list[Shape], list[PlacePoint]]:
    shapes: list[Shape] = []
    points: list[PlacePoint] = []
    admin = folder / "egypt_admin_osm.geojson"
    if admin.exists():
        for f in json.loads(admin.read_text(encoding="utf-8")).get("features") or []:
            props = f.get("properties") or {}
            geom = f.get("geometry") or {}
            ar, en = _names(props)
            if not ar:
                continue
            polys = geom.get("coordinates") or []
            if geom.get("type") == "Polygon":
                polys = [polys]
            rings = [p[0] for p in polys if p and len(p[0]) >= 4]
            if rings:
                shapes.append(Shape(_osm_id(props), int(props.get("admin_level") or 0), ar, en, rings))
    pts = folder / "egypt_place_points_osm.geojson"
    if pts.exists():
        for f in json.loads(pts.read_text(encoding="utf-8")).get("features") or []:
            props = f.get("properties") or {}
            coords = (f.get("geometry") or {}).get("coordinates") or []
            ar, en = _names(props)
            if ar and len(coords) == 2:
                points.append(PlacePoint(_osm_id(props), str(props.get("place", "")), ar, en, float(coords[1]), float(coords[0])))
    return shapes, points


def load_adm2(folder: Path) -> tuple[list[Shape], str]:
    """The ADM2 areas (fetch_adm2.py) and their source line; ([], "") without the file."""
    path = folder / ADM2_FILE
    if not path.exists():
        return [], ""
    doc = json.loads(path.read_text(encoding="utf-8"))
    shapes: list[Shape] = []
    for f in doc.get("features") or []:
        props = f.get("properties") or {}
        rings = [poly[0] for poly in ((f.get("geometry") or {}).get("coordinates") or []) if poly and len(poly[0]) >= 4]
        ar = str(props.get("name:ar") or "").strip()
        en = str(props.get("name:en") or "").strip()
        if rings and (ar or en) and props.get("id"):
            shapes.append(Shape(str(props["id"]), ADM2_LEVEL, ar or en, en or ar, rings))
    return shapes, f"{doc.get('source', '?')}; licence {doc.get('license', '?')}"


def coverage(shapes: list[Shape], located: list[tuple[float, float]]) -> dict[int, float]:
    """Share of [located] points inside some polygon of each admin level."""
    by_level: dict[int, list[Shape]] = {}
    for s in shapes:
        by_level.setdefault(s.level, []).append(s)
    out: dict[int, float] = {}
    for level, group in by_level.items():
        inside = sum(1 for lat, lng in located if any(s.contains(lat, lng) for s in group))
        out[level] = inside / len(located) if located else 0.0
    return out


def level_order(levels: tuple[int, ...], cover: dict[int, float], min_cover: float) -> list[int]:
    """Preferred level first (finest with enough coverage, else the best
    covered), then coarser levels (finest first), then finer ones. Levels
    with no polygon at all are left out."""
    present = [lv for lv in levels if lv in cover]
    if not present:
        return []
    good = [lv for lv in present if cover.get(lv, 0.0) >= min_cover]
    preferred = max(good) if good else max(present, key=lambda lv: (cover.get(lv, 0.0), lv))
    coarser = sorted((lv for lv in present if lv < preferred), reverse=True)
    finer = sorted(lv for lv in present if lv > preferred)
    return [preferred, *coarser, *finer]


def _gov_of(lat: float, lng: float, boundaries: Boundaries | None) -> str:
    gov = boundaries.governorate_at(lat, lng) if boundaries else None
    return gov or nearest_town(lat, lng)[0]


def _representative(shape: Shape) -> tuple[float, float]:
    """A point inside the shape: its centroid, or else the first vertex
    nudged inwards (a concave shape's centroid can lie outside)."""
    lat, lng = shape.centre
    if shape.contains(lat, lng):
        return lat, lng
    ring = shape.rings[0]
    for i in range(len(ring) - 1):
        mid_lng = (ring[i][0] + ring[i + 1][0] + lng) / 3
        mid_lat = (ring[i][1] + ring[i + 1][1] + lat) / 3
        if shape.contains(mid_lat, mid_lng):
            return mid_lat, mid_lng
    return lat, lng


def choose_layer(shapes: list[Shape], order: list[int]) -> list[Shape]:
    """Shapes of the preferred level, plus shapes of fallback levels whose
    representative point is not already inside a chosen shape: a set that
    does not overlap, finest available first."""
    chosen: list[Shape] = []
    for level in order:
        for s in (x for x in shapes if x.level == level):
            lat, lng = _representative(s)
            if not any(c.contains(lat, lng) for c in chosen):
                chosen.append(s)
    return chosen


@dataclass
class Places:
    areas: list[Shape]
    districts: list[Shape]
    point_districts: list[tuple[PlacePoint, str]]  # (point, areaId)
    area_order: list[int]
    district_order: list[int]
    cover: dict[int, float]
    district_area: dict[str, str] = field(default_factory=dict)
    school_counts: dict[str, int] = field(default_factory=dict)
    district_counts: dict[str, int] = field(default_factory=dict)
    no_area: int = 0
    no_district: int = 0
    area_source: str = "osm"  # "adm2" when the areas come from fetch_adm2.py
    adm2_note: str = ""
    adm2_cover: float = 0.0


def build(
    shapes: list[Shape],
    points: list[PlacePoint],
    schools: list[School],
    boundaries: Boundaries | None,
    adm2: list[Shape] | None = None,
    adm2_note: str = "",
) -> Places:
    located = [(s.lat, s.lng) for s in schools if s.lat is not None and s.lng is not None]
    cover = coverage(shapes, located)  # type: ignore[arg-type]
    area_order = level_order(AREA_LEVELS, cover, AREA_MIN_COVERAGE)
    district_order = level_order(DISTRICT_LEVELS, cover, DISTRICT_MIN_COVERAGE)
    if adm2:
        # ADM2 units are the areas (they tile the country); OSM levels 5-7 are not used.
        areas = list(adm2)
        area_order = []
    else:
        areas = choose_layer([s for s in shapes if s.level in AREA_LEVELS], area_order)
    for a in areas:
        a.governorate = _gov_of(*_representative(a), boundaries)
    districts: list[Shape] = []
    district_area: dict[str, str] = {}
    for d in choose_layer([s for s in shapes if s.level in DISTRICT_LEVELS], district_order):
        lat, lng = _representative(d)
        area = next((a for a in areas if a.contains(lat, lng)), None)
        if area is None:
            continue
        d.governorate = area.governorate
        districts.append(d)
        district_area[d.id] = area.id
    point_districts: list[tuple[PlacePoint, str]] = []
    seen_names: set[tuple[str, str]] = {(district_area[d.id], normalize_text(d.name_ar)) for d in districts}
    for p in points:
        area = next((a for a in areas if a.contains(p.lat, p.lng)), None)
        if area is None or any(d.contains(p.lat, p.lng) for d in districts):
            continue
        key = (area.id, normalize_text(p.name_ar))
        if key in seen_names:
            continue
        seen_names.add(key)
        point_districts.append((p, area.id))
    places = Places(areas, districts, point_districts, area_order, district_order, cover, district_area)
    if adm2:
        places.area_source = "adm2"
        places.adm2_note = adm2_note
        places.adm2_cover = coverage(adm2, located).get(ADM2_LEVEL, 0.0) if located else 0.0  # type: ignore[arg-type]
    return places


def assign(places: Places, schools: list[School]) -> None:
    """Sets place_area_* and place_district_id on each school (an area of
    the school's own governorate only)."""
    by_area_points: dict[str, list[PlacePoint]] = {}
    for p, area_id in places.point_districts:
        by_area_points.setdefault(area_id, []).append(p)
    names = {a.id: a for a in places.areas}
    areas_by_gov: dict[str, list[Shape]] = {}
    for a in places.areas:
        areas_by_gov.setdefault(a.governorate, []).append(a)
    districts_by_area: dict[str, list[Shape]] = {}
    for d in places.districts:
        districts_by_area.setdefault(places.district_area[d.id], []).append(d)
    for s in schools:
        if s.lat is None or s.lng is None:
            # A list entry without a pin: its city/district column, matched
            # by name to an area of its governorate ("قسم"/"مركز" ignored).
            area = area_by_name(areas_by_gov.get(s.governorate, []), s.city_ar, s.city)
        else:
            # The smallest holding area: outlines keep outer rings only, so a
            # city's qism inside its markaz is in both (validator B4).
            holding = [a for a in areas_by_gov.get(s.governorate, []) if a.contains(s.lat, s.lng)]
            area = min(holding, key=lambda a: (_box_size(a), a.id)) if holding else None
        if area is None:
            places.no_area += 1
            continue
        s.place_area_id = area.id
        s.place_area_name_ar = names[area.id].name_ar
        s.place_area_name_en = names[area.id].name_en
        places.school_counts[area.id] = places.school_counts.get(area.id, 0) + 1
        if s.lat is None or s.lng is None:
            places.no_district += 1
            continue
        district = next((d for d in districts_by_area.get(area.id, []) if d.contains(s.lat, s.lng)), None)
        district_id = district.id if district else None
        if district_id is None:
            near = [
                (distance_m(s.lat, s.lng, p.lat, p.lng), p.id) for p in by_area_points.get(area.id, [])
            ]
            near = [n for n in near if n[0] <= POINT_DISTRICT_KM * 1000]
            district_id = min(near)[1] if near else None
        if district_id is None:
            places.no_district += 1
            continue
        s.place_district_id = district_id
        places.district_counts[district_id] = places.district_counts.get(district_id, 0) + 1


def _box_size(shape: Shape) -> float:
    b = shape.bbox()
    return (b["maxLat"] - b["minLat"]) * (b["maxLng"] - b["minLng"])


_AREA_WORDS = {"قسم", "مركز", "حي", "مدينه", "district", "markaz", "qism", "kism", "city", "new"}


def _area_key(name: str) -> str:
    return " ".join(t for t in normalize_text(name).split() if t not in _AREA_WORDS)


def area_by_name(areas: list[Shape], *names: str) -> Shape | None:
    """The one area whose Arabic or English name matches one of [names]
    (normalized, "قسم"/"مركز"/"حي" and similar words ignored), else None."""
    keys = {_area_key(n) for n in names if n and _area_key(n)}
    if not keys:
        return None
    found = [a for a in areas if _area_key(a.name_ar) in keys or _area_key(a.name_en) in keys]
    return found[0] if len(found) == 1 else None


def _rings_latlng(shape: Shape) -> list[list[list[float]]]:
    return [[[round(p[1], 6), round(p[0], 6)] for p in r] for r in shape.rings]


def to_json(places: Places, generated_at: str) -> dict:
    areas = [
        {
            "id": a.id,
            "governorate": a.governorate,
            "nameAr": a.name_ar[:80],
            "nameEn": a.name_en[:80],
            "level": a.level,
            "centre": {"lat": round(a.centre[0], 6), "lng": round(a.centre[1], 6)},
            "bbox": a.bbox(),
            "rings": _rings_latlng(a),
            "schoolCount": places.school_counts.get(a.id, 0),
        }
        for a in sorted(places.areas, key=lambda x: x.id)
    ]
    districts = [
        {
            "id": d.id,
            "areaId": places.district_area[d.id],
            "governorate": d.governorate,
            "nameAr": d.name_ar[:80],
            "nameEn": d.name_en[:80],
            "source": "osm-boundary",
            "centre": {"lat": round(d.centre[0], 6), "lng": round(d.centre[1], 6)},
            "bbox": d.bbox(),
            "rings": _rings_latlng(d),
            "schoolCount": places.district_counts.get(d.id, 0),
        }
        for d in sorted(places.districts, key=lambda x: x.id)
    ]
    gov_of_area = {a.id: a.governorate for a in places.areas}
    districts += [
        {
            "id": p.id,
            "areaId": area_id,
            "governorate": gov_of_area[area_id],
            "nameAr": p.name_ar[:80],
            "nameEn": p.name_en[:80],
            "source": "osm-place",
            "centre": {"lat": round(p.lat, 6), "lng": round(p.lng, 6)},
            "schoolCount": places.district_counts.get(p.id, 0),
        }
        for p, area_id in sorted(places.point_districts, key=lambda x: x[0].id)
    ]
    return {
        "format": PLACES_FORMAT,
        "generatedAt": generated_at,
        "levels": {"area": places.area_order, "district": places.district_order},
        "coverage": {str(k): round(v, 4) for k, v in sorted(places.cover.items())},
        "areas": areas,
        "districts": districts,
    }


def city_label(code: str) -> str:
    """"Cairo / القاهرة": the governorate's English and Arabic names."""
    aliases = GOVERNORATE_ALIASES.get(code, (code,))
    ar = next((a for a in aliases if has_arabic(a)), code)
    en = next((a for a in aliases if not has_arabic(a)), code)
    return f"{en} / {ar}"


def summary_lines(places: Places, schools: list[School], top: int = 15) -> list[str]:
    gov_names = {code: city_label(code) for code in GOVERNORATE_ALIASES}
    cover = ", ".join(f"{lv}: {places.cover.get(lv, 0.0):.0%}" for lv in sorted(places.cover))
    lines = [
        f"Places: admin_level coverage of the schools {cover or 'none (no boundaries downloaded)'}; "
        f"Area levels in order {places.area_order or '-'}, District levels {places.district_order or '-'}."
        + (f" Areas: ADM2 units ({len(places.areas)}, holding {places.adm2_cover:.0%} of the schools; {places.adm2_note})." if places.area_source == "adm2" else ""),
        f"Places: {len(places.areas)} areas, {len(places.districts)} district boundaries, "
        f"{len(places.point_districts)} named places as districts; schools with no area {places.no_area}, "
        f"with an area but no district {places.no_district}.",
    ]
    per_city: dict[str, int] = {}
    for s in schools:
        per_city[s.governorate] = per_city.get(s.governorate, 0) + 1
    lines.append("Schools per city: " + ", ".join(f"{gov_names.get(g, g)} {n}" for g, n in sorted(per_city.items(), key=lambda kv: -kv[1])))
    names = {a.id: (a.name_en, a.governorate) for a in places.areas}
    ranked = sorted(places.school_counts.items(), key=lambda kv: -kv[1])[:top]
    if ranked:
        lines.append(
            f"Top {len(ranked)} areas: "
            + ", ".join(f"{names[i][0]} ({names[i][1]}) {n}" for i, n in ranked)
        )
    return lines


def report_lines(places: Places) -> list[str]:
    out = ["## Places (City -> Area -> District)", ""]
    out.append("Share of located schools inside a boundary of each admin_level (measured at import):")
    out.append("")
    out.append("| admin_level | Coverage |")
    out.append("| ---: | ---: |")
    for lv in sorted(places.cover):
        out.append(f"| {lv} | {places.cover[lv]:.1%} |")
    out.append("")
    out.append(f"Area levels, in order of use: {places.area_order or 'none'}. District levels: {places.district_order or 'none'}.")
    if places.area_source == "adm2":
        out.append("")
        out.append(f"Areas are the {len(places.areas)} ADM2 units ({places.adm2_note}); they hold {places.adm2_cover:.1%} of the located schools.")
    out.append("")
    return out

