#!/usr/bin/env python3
"""Download Egypt's places below the governorate from OpenStreetMap (F4 City
-> Area -> District, F46 addresses).

    python3 tools/import_schools/fetch_osm_places.py
    python3 tools/import_schools/fetch_osm_places.py --max-age-days 7

Two kinds of Overpass data, asked together once per governorate
(overpass_split.py: 27 parts, [timeout:180] each, failover, a second pass,
older per-governorate files reused for parts that still fail; one query
for all of Egypt is too heavy for the busy public servers):

1. every administrative boundary relation with admin_level 5 to 10 (out
   geom): the candidates for an Area (qism / markaz / new city) and a
   District (neighbourhood). Which level is which in Egypt is NOT assumed:
   the importer measures, at run time, how many schools each level covers
   and picks the finest level that covers the country well, falling back
   to a coarser level point by point (places_import.py);
2. every named place=suburb|quarter|neighbourhood (OSM wiki: Key:place;
   "suburb" a large part of a city, "quarter" a part of a suburb,
   "neighbourhood" the smallest named part): district names where no
   finer boundary exists.

Writes (git-ignored)

  data/schools/places/egypt_admin_osm.geojson     simplified MultiPolygons
                                                  with admin_level and names
  data/schools/places/egypt_place_points_osm.geojson
  data/schools/places/governorates/EG-xx.geojson  one per governorate, with
                                                  its own fetched_at
  data/schools/places/fetch_report.md             counts per admin level, status
                                                  per governorate

Shapes are simplified to about 30 m (Douglas-Peucker) so each area fits
easily in one Firestore document for the server's point-in-polygon check.
OpenStreetMap data: (c) OpenStreetMap contributors, ODbL 1.0.

Python 3.11+, standard library only. Run by tool/cloud_setup.sh step 12.
"""

from __future__ import annotations

import argparse
import datetime as dt
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from fetch_osm_schools import (  # noqa: E402
    ATTRIBUTION,
    BOUNDARIES_FILE,
    EGYPT_AREA,
    ENDPOINTS,
    QUERY_TIMEOUT_S,
    element_point,
    fetched_at_of,
    overpass,
    query_of,
    relation_multipolygon,
    write_json_atomic,
)
from overpass_split import (  # noqa: E402
    DEFAULT_BUDGET_MIN,
    PART_TIMEOUT_S,
    fetch_parts,
    governorate_areas,
    merge_features,
    status_lines,
    summary_line,
)

LEVELS = (5, 6, 7, 8, 9, 10)
PLACE_VALUES = ("suburb", "quarter", "neighbourhood")

# All of Egypt in one query each (the first version; too heavy for the busy
# public servers, kept for reference and tests). main() asks part_query()
# once per governorate.
ADMIN_QUERY = (
    f"[out:json][timeout:{QUERY_TIMEOUT_S}];\n{EGYPT_AREA}\n"
    f'rel["boundary"="administrative"]["admin_level"~"^({"|".join(str(level) for level in LEVELS)})$"](area.eg);\n'
    "out geom;\n"
)
PLACES_QUERY = (
    f"[out:json][timeout:{QUERY_TIMEOUT_S}];\n{EGYPT_AREA}\n(\n"
    f'  nwr["place"~"^({"|".join(PLACE_VALUES)})$"]["name"](area.eg);\n'
    f'  nwr["place"~"^({"|".join(PLACE_VALUES)})$"]["name:ar"](area.eg);\n'
    ");\nout center;\n"
)



def part_query(area: str, set_name: str = "g", timeout_s: int = PART_TIMEOUT_S) -> str:
    """Boundaries (out geom) and named places (out center) of one governorate."""
    a = f"(area.{set_name})"
    levels = "|".join(str(level) for level in LEVELS)
    places = "|".join(PLACE_VALUES)
    return (
        f"[out:json][timeout:{timeout_s}];\n{area}\n"
        f'rel["boundary"="administrative"]["admin_level"~"^({levels})$"]{a};\n'
        "out geom;\n(\n"
        f'  nwr["place"~"^({places})$"]["name"]{a};\n'
        f'  nwr["place"~"^({places})$"]["name:ar"]{a};\n'
        ");\nout center;\n"
    )


QUERY_ID = "split-1"
PARTIAL_QUERY_ID = "split-1-partial"
PART_QUERY_ID = "places-1"
PARTS_FOLDER = "governorates"

ADMIN_FILE = "egypt_admin_osm.geojson"
POINTS_FILE = "egypt_place_points_osm.geojson"
REPORT_FILE = "fetch_report.md"

# About 30 m in Egypt; a ring with more points than MAX_RING_POINTS is
# simplified again with a larger tolerance.
SIMPLIFY_DEG = 0.0003
MAX_RING_POINTS = 600


def _perp_distance(p: list[float], a: list[float], b: list[float]) -> float:
    (x, y), (x1, y1), (x2, y2) = p, a, b
    dx, dy = x2 - x1, y2 - y1
    if dx == 0 and dy == 0:
        return math.hypot(x - x1, y - y1)
    t = max(0.0, min(1.0, ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy)))
    return math.hypot(x - (x1 + t * dx), y - (y1 + t * dy))


def simplify_line(points: list[list[float]], tolerance: float) -> list[list[float]]:
    """Douglas-Peucker without recursion (rings of tens of thousands of points)."""
    if len(points) < 3:
        return list(points)
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        start, end = stack.pop()
        best, index = 0.0, -1
        for i in range(start + 1, end):
            d = _perp_distance(points[i], points[start], points[end])
            if d > best:
                best, index = d, i
        if index >= 0 and best > tolerance:
            keep[index] = True
            stack.append((start, index))
            stack.append((index, end))
    return [p for p, k in zip(points, keep) if k]


def simplify_ring(ring: list[list[float]], tolerance: float = SIMPLIFY_DEG) -> list[list[float]]:
    """A closed ring simplified, still closed and with at least 4 points.
    The ring is split at its farthest point so the closing point is kept."""
    if len(ring) <= 4:
        return ring
    far = max(range(len(ring)), key=lambda i: (ring[i][0] - ring[0][0]) ** 2 + (ring[i][1] - ring[0][1]) ** 2)
    tol = tolerance
    while True:
        out = simplify_line(ring[: far + 1], tol)[:-1] + simplify_line(ring[far:], tol)
        if len(out) <= MAX_RING_POINTS or tol > 0.05:
            break
        tol *= 2
    if out[0] != out[-1]:
        out.append(out[0])
    return out if len(out) >= 4 else ring


def _round(ring: list[list[float]]) -> list[list[float]]:
    return [[round(x, 6), round(y, 6)] for x, y in ring]


def admin_geojson(answer: dict, fetched_at: str, endpoint: str) -> tuple[dict, dict[int, int], list[str]]:
    """Boundary relations -> FeatureCollection of simplified MultiPolygons
    (holes dropped: an area with an enclave is rare and the enclave's own
    polygon is tested first by the finer level). Returns the collection,
    the count per admin level, and the problems."""
    features: list[dict] = []
    per_level: dict[int, int] = {}
    problems: list[str] = []
    for element in answer.get("elements") or []:
        if element.get("type") != "relation":
            continue
        tags = element.get("tags") or {}
        try:
            level = int(str(tags.get("admin_level", "")))
        except ValueError:
            continue
        if level not in LEVELS or not (tags.get("name") or tags.get("name:ar") or tags.get("name:en")):
            continue
        polygons = relation_multipolygon(element)
        if not polygons:
            problems.append(f"level {level} {tags.get('name:en') or tags.get('name') or element.get('id')}: border has a gap; left out")
            continue
        coords = [[_round(simplify_ring(p[0]))] for p in polygons]
        features.append(
            {
                "type": "Feature",
                "properties": {
                    "admin_level": level,
                    "name": str(tags.get("name", "")),
                    "name:ar": str(tags.get("name:ar", "")),
                    "name:en": str(tags.get("name:en", "")),
                    "osm_id": element.get("id"),
                    "osm_type": "relation",
                },
                "geometry": {"type": "MultiPolygon", "coordinates": coords},
            }
        )
        per_level[level] = per_level.get(level, 0) + 1
    features.sort(key=lambda f: (f["properties"]["admin_level"], f["properties"]["osm_id"]))
    collection = {
        "type": "FeatureCollection",
        "name": "Egypt administrative boundaries below the governorate (OpenStreetMap, admin_level 5-10)",
        "fetched_at": fetched_at,
        "source": endpoint,
        "license": ATTRIBUTION,
        "features": features,
    }
    return collection, per_level, problems


def points_geojson(answer: dict, fetched_at: str, endpoint: str) -> tuple[dict, dict[str, int]]:
    features: list[dict] = []
    per_kind: dict[str, int] = {}
    for element in answer.get("elements") or []:
        kind = str(element.get("type"))
        osm_id = element.get("id")
        if kind not in ("node", "way", "relation") or not isinstance(osm_id, int):
            continue
        tags = element.get("tags") or {}
        place = str(tags.get("place", ""))
        point = element_point(element)
        if place not in PLACE_VALUES or point is None:
            continue
        features.append(
            {
                "type": "Feature",
                "properties": {
                    "place": place,
                    "name": str(tags.get("name", "")),
                    "name:ar": str(tags.get("name:ar", "")),
                    "name:en": str(tags.get("name:en", "")),
                    "osm_id": osm_id,
                    "osm_type": kind,
                },
                "geometry": {"type": "Point", "coordinates": [round(point[1], 7), round(point[0], 7)]},
            }
        )
        per_kind[place] = per_kind.get(place, 0) + 1
    features.sort(key=lambda f: (f["properties"]["osm_type"], f["properties"]["osm_id"]))
    return (
        {
            "type": "FeatureCollection",
            "name": "Egypt named suburbs, quarters and neighbourhoods (OpenStreetMap)",
            "fetched_at": fetched_at,
            "source": endpoint,
            "license": ATTRIBUTION,
            "features": features,
        },
        per_kind,
    )


def part_geojson(answer: dict, fetched_at: str, endpoint: str) -> dict:
    """One governorate's answer -> one FeatureCollection holding both the
    simplified boundaries (MultiPolygon) and the named places (Point)."""
    admin, _, problems = admin_geojson(answer, fetched_at, endpoint)
    points, _ = points_geojson(answer, fetched_at, endpoint)
    return {
        "type": "FeatureCollection",
        "name": "Egypt places below the governorate, one governorate (OpenStreetMap)",
        "fetched_at": fetched_at,
        "source": endpoint,
        "license": ATTRIBUTION,
        "problems": problems,
        "features": admin["features"] + points["features"],
    }


def split_merged(features: list[dict], fetched_at: str, source: str, query_id: str) -> tuple[dict, dict, dict[int, int], dict[str, int]]:
    """Merged part features -> (admin collection, points collection, count
    per admin level, count per place kind)."""
    admin = [f for f in features if (f.get("geometry") or {}).get("type") != "Point"]
    points = [f for f in features if (f.get("geometry") or {}).get("type") == "Point"]
    admin.sort(key=lambda f: (f["properties"]["admin_level"], f["properties"]["osm_id"]))
    per_level: dict[int, int] = {}
    for f in admin:
        per_level[f["properties"]["admin_level"]] = per_level.get(f["properties"]["admin_level"], 0) + 1
    per_kind: dict[str, int] = {}
    for f in points:
        per_kind[f["properties"]["place"]] = per_kind.get(f["properties"]["place"], 0) + 1
    head = {"type": "FeatureCollection", "fetched_at": fetched_at, "query": query_id, "source": source, "license": ATTRIBUTION}
    return (
        {**head, "name": "Egypt administrative boundaries below the governorate (OpenStreetMap, admin_level 5-10)", "features": admin},
        {**head, "name": "Egypt named suburbs, quarters and neighbourhoods (OpenStreetMap)", "features": points},
        per_level,
        per_kind,
    )


def main(argv: list[str] | None = None) -> int:
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=repo / "data" / "schools" / "places")
    parser.add_argument("--boundaries", type=Path, default=repo / "data" / "schools" / "boundaries" / BOUNDARIES_FILE,
                        help="governorates download (fetch_osm_schools.py): its relation ids are the search areas")
    parser.add_argument("--max-age-days", type=float, default=0)
    parser.add_argument("--endpoint", action="append", help="Overpass interpreter URL (repeatable)")
    parser.add_argument("--prefer", help="the Overpass server to ask first (the one that just answered)")
    parser.add_argument("--max-minutes", type=float, default=DEFAULT_BUDGET_MIN, help="time budget for new requests")
    args = parser.parse_args(argv)
    endpoints = tuple(args.endpoint or ENDPOINTS)
    admin_path = args.out / ADMIN_FILE
    now = dt.datetime.now(dt.timezone.utc)
    if args.max_age_days > 0:
        last = fetched_at_of(admin_path)
        if (
            last is not None
            and now - last < dt.timedelta(days=args.max_age_days)
            and (args.out / POINTS_FILE).exists()
            and query_of(admin_path) == QUERY_ID
        ):
            print(f"OpenStreetMap places: the download of {last:%Y-%m-%d %H:%M} UTC is recent; kept (no new download).")
            return 0
    fetched_at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    parts = governorate_areas(args.boundaries if args.boundaries.exists() else None)
    print(f"OpenStreetMap places: boundaries (admin_level 5-10) and named places, per governorate ({len(parts)} parts)...")
    split = fetch_parts(
        parts,
        lambda part: part_query(part.area),
        part_geojson,
        args.out / PARTS_FOLDER,
        query_id=PART_QUERY_ID,
        fetch=lambda q, eps, first: overpass(q, eps, rounds=1, prefer=first, timeout_s=PART_TIMEOUT_S),
        endpoints=endpoints,
        prefer=args.prefer,
        max_age_days=args.max_age_days,
        budget_s=max(args.max_minutes, 1.0) * 60,
        now=now,
        # A governorate may have no boundary below level 4 and no named
        # place in OpenStreetMap; the area ids come from the governorates
        # download, so an empty answer is not taken as an error here.
        min_features=lambda _part: 0,
    )
    features = merge_features(split.collections.values())
    problems = [p for c in split.collections.values() for p in (c.get("problems") or [])]
    for p in problems[:20]:
        print(f"  {p}")
    if len(problems) > 20:
        print(f"  ... and {len(problems) - 20} more borders with gaps")
    servers = ", ".join(sorted({s.server for s in split.statuses if s.server})) or "-"
    admin, points, per_level, per_kind = split_merged(features, fetched_at, servers, QUERY_ID if split.complete else PARTIAL_QUERY_ID)
    gov_lines = status_lines(split)
    print("  " + summary_line(split))
    for line in gov_lines:
        if "NO data" in line or "older file" in line:
            print("  " + line[2:])
    if not admin["features"] and not points["features"]:
        print("OpenStreetMap places: nothing came back; the earlier files, if any, are kept.", file=sys.stderr)
        return 1
    write_json_atomic(admin_path, admin)
    write_json_atomic(args.out / POINTS_FILE, points)
    lines = [
        "# OpenStreetMap places download",
        "",
        f"- Downloaded: {fetched_at} (UTC) from {servers}, one query per governorate",
        "- Boundaries per admin_level: " + (", ".join(f"{k}: {v}" for k, v in sorted(per_level.items())) or "none"),
        f"- Borders left out (gaps in OpenStreetMap): {len(problems)}",
        "- Named places: " + (", ".join(f"{k}: {v}" for k, v in sorted(per_kind.items())) or "none"),
        "- Which level becomes Area and which District is measured by the import (report.md, 'Places').",
        "",
        "## Per governorate",
        "",
        *gov_lines,
        "",
        "Summary: " + summary_line(split),
        "",
        "## Licence",
        "",
        ATTRIBUTION,
        "",
    ]
    (args.out / REPORT_FILE).write_text("\n".join(lines), encoding="utf-8")
    print("  boundaries per level: " + (", ".join(f"{k}: {v}" for k, v in sorted(per_level.items())) or "none"))
    print("  named places: " + (", ".join(f"{k}: {v}" for k, v in sorted(per_kind.items())) or "none"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
