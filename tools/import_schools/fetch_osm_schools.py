#!/usr/bin/env python3
"""Download every school and kindergarten in Egypt from OpenStreetMap (F4).

    python3 tools/import_schools/fetch_osm_schools.py                 # schools + governorate boundaries
    python3 tools/import_schools/fetch_osm_schools.py --max-age-days 7  # skip if the last download is newer
    python3 tools/import_schools/fetch_osm_schools.py --no-boundaries
    python3 tools/import_schools/fetch_osm_schools.py --max-minutes 40   # time budget for new requests

Asks the Overpass API (a read-only query service for OpenStreetMap data)
for every node, way and relation that may be a school or kindergarten
(the broad query below; `out center;`: node positions, and the centre of
each way and relation). The broad query for all of Egypt at once timed out
on every public server (16 Nov 2026), so it runs once per governorate
(overpass_split.py: 27 parts, [timeout:180] each, failover, a second pass,
older per-governorate files reused for parts that still fail), plus the
narrow amenity-only query for all of Egypt as a safety net. Writes:

  data/schools/osm/egypt_schools_osm.geojson   all parts merged, each OSM object
                                               once: points (way/relation
                                               centres), OSM tags + osm_id/osm_type,
                                               the shape import_schools.py reads
  data/schools/osm/governorates/EG-xx.geojson  one per governorate (and EG for
                                               the safety net), each with its
                                               own fetched_at
  data/schools/osm/fetch_report.md             date, servers, counts, status per
                                               governorate, licence
  data/schools/boundaries/egypt_governorates_osm.geojson
                                               the 27 governorates (admin_level 4),
                                               for an exact governorate per school

Both folders are git-ignored. OpenStreetMap data is (c) OpenStreetMap
contributors, available under the Open Database License (ODbL 1.0):
https://www.openstreetmap.org/copyright

Python 3.11+, standard library only. Runs in Google Cloud Shell
(tool/cloud_setup.sh step 12). Public Overpass servers are shared and
sometimes busy: each is tried in turn, with retries and a pause after
"too many requests" (their usage policy asks for 30 seconds).
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, Iterable

# Public instances without an API key, from the OpenStreetMap wiki page
# "Overpass API" (section "Public Overpass API instances", read 15 Nov 2026).
ENDPOINTS: tuple[str, ...] = (
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
)

# The server-side limit. The main server's usage policy (wiki "Overpass
# API", read 15 Nov 2026) asks that "your requests are processed in no more
# than 10 minutes"; a higher timeout also makes a busy server more likely
# to refuse the query up front. The schools query normally takes well
# under two minutes.
QUERY_TIMEOUT_S = 540
USER_AGENT = "school-carpool-schools-import/1.0 (OpenStreetMap schools list; Python urllib)"

EGYPT_AREA = 'area["ISO3166-1"="EG"][admin_level=2]->.eg;'

# What the broad query asks for. The download is deliberately wider than
# what we keep: tools/import_schools/schools_import.py (classify_tags) is
# the single place that decides what counts as a school or kindergarten
# and why anything else is dropped. Tags checked on the OpenStreetMap wiki
# (Tag:amenity=school, Proposal:Education_tag approved Feb 2025, Item for
# education=kindergarten), 16 Nov 2026.
#
# - amenity=school|kindergarten: the main tags (all of them, named or not;
#   an unnamed one may carry its name in official_name, alt_name, ...);
# - education=school|kindergarten: the approved 2025 key, same meaning;
# - building=school|kindergarten, school=*, isced:level=*: only with a name
#   (a nameless building cannot be searched);
# - any feature whose name, name:ar or name:en looks like a school
#   (starts with مدرس / مدارس / روض / حضان, optionally after "ال" or
#   "مجمع ", or contains school / kindergarten, or the word KG), except
#   streets (highway=*: "شارع المدرسة" is a street named after a school).
NAME_KEYS: tuple[str, ...] = ("name", "name:ar", "name:en")
ARABIC_NAME_RE = "^(مجمع )?(ال)?(مدرس|مدارس)|^(روض|حضان)"
LATIN_NAME_RE = "school|kindergarten"
KG_NAME_RE = "(^|[^A-Za-z])KG([^A-Za-z]|$)"


def amenity_values(categories: dict[str, bool] | None = None) -> tuple[str, ...]:
    """amenity / education values asked for, from data/schools/categories.json
    (schools_import.CATEGORIES): childcare for nurseries, university and
    college only when that switch is on (owner: off, 16 Nov 2026)."""
    c = categories or {}
    values = ["school", "kindergarten"]
    if c.get("nursery", True):
        values.append("childcare")
    if c.get("university", False):
        values += ["university", "college"]
    return tuple(values)


def query_id_for(base: str, values: tuple[str, ...]) -> str:
    """A download is reused only when made for the same categories."""
    extra = [v for v in values if v not in ("school", "kindergarten")]
    return base + ("+" + "+".join(extra) if extra else "")


def schools_query(
    timeout_s: int = QUERY_TIMEOUT_S,
    broad: bool = True,
    area: str = EGYPT_AREA,
    set_name: str = "eg",
    values: tuple[str, ...] = ("school", "kindergarten"),
) -> str:
    """The Overpass QL query for schools in Egypt, or in the area that the
    statement [area] stores in the set [set_name] (one governorate, see
    overpass_split.py). `out center;` (verbosity "body" plus centres), not
    `out center tags;`: per the Overpass QL documentation "tags" prints no
    coordinates and "center" adds a centre only to ways and relations.
    [broad]=False is the original narrow query (amenity only)."""
    a = f"(area.{set_name})"
    v = "|".join(values)
    clauses = [f'nwr["amenity"~"^({v})$"]{a};']
    if broad:
        clauses.append(f'nwr["education"~"^({v})$"]{a};')
        for key in NAME_KEYS:
            clauses.append(f'nwr["building"~"^(school|kindergarten)$"]["{key}"]{a};')
            clauses.append(f'nwr["school"]["{key}"]{a};')
            clauses.append(f'nwr["isced:level"]["{key}"]{a};')
        for key in NAME_KEYS:
            clauses.append(f'nwr["{key}"~"{ARABIC_NAME_RE}"][!"highway"]{a};')
            clauses.append(f'nwr["{key}"~"{LATIN_NAME_RE}",i][!"highway"]{a};')
            clauses.append(f'nwr["{key}"~"{KG_NAME_RE}"][!"highway"]{a};')
    body = "\n".join(f"  {c}" for c in clauses)
    return f"[out:json][timeout:{timeout_s}];\n{area}\n(\n{body}\n);\nout center;\n"


# --- Pieces per governorate (since the 16 Nov 2026 staging run) -------------
#
# The per-governorate broad query still timed out in Alexandria, Cairo and
# Giza: maps.mail.ru stopped it at line 16, the case-insensitive Latin name
# regex (`nwr["name"~"school|kindergarten",i]`). An unanchored,
# case-insensitive value regex cannot use Overpass' tag index and has to look
# at every name value; the anchored Arabic regex on line 15 finished. So
# each governorate is now asked in three pieces, each failing on its own:
#
#   tags   amenity/education values, and named building=school, school=*,
#          isced:level=*: exact tag lookups only, cheap;
#   names  the anchored Arabic regexes on name and name:ar (no Latin regex);
#   named  every NAMED feature with an amenity, building, office, landuse,
#          education or school key, no regex at all (in the big
#          governorates per quadrant of its bbox); the Latin and KG name
#          rules run HERE in Python (refine_named), so only school-like
#          features are stored.
#
# Not measured here (no Overpass access from the build workspace): the cost
# of each piece on the public servers; the per-part status in the report
# shows which pieces finish.
PIECES = ("tags", "names", "named")
NAMED_KEYS = ("amenity", "building", "office", "landuse", "education", "school")
_LATIN_SCHOOL = re.compile(LATIN_NAME_RE, re.I)
_KG = re.compile(KG_NAME_RE)


def piece_query(kind: str, area: str, bbox: tuple[float, float, float, float] | None, values: tuple[str, ...],
                timeout_s: int, set_name: str = "g") -> str:
    """The Overpass query of one piece of a governorate (see PIECES)."""
    a = f"(area.{set_name})"
    if kind == "named" and bbox is not None:
        a += f"({bbox[0]},{bbox[1]},{bbox[2]},{bbox[3]})"
    v = "|".join(values)
    if kind == "tags":
        clauses = [f'nwr["amenity"~"^({v})$"]{a};', f'nwr["education"~"^({v})$"]{a};']
        for key in NAME_KEYS:
            clauses.append(f'nwr["building"~"^(school|kindergarten)$"]["{key}"]{a};')
            clauses.append(f'nwr["school"]["{key}"]{a};')
            clauses.append(f'nwr["isced:level"]["{key}"]{a};')
    elif kind == "names":
        clauses = [f'nwr["{key}"~"{ARABIC_NAME_RE}"][!"highway"]{a};' for key in ("name", "name:ar")]
    elif kind == "named":
        clauses = [f'nwr["{key}"]["name"]{a};' for key in NAMED_KEYS]
    else:
        raise ValueError(kind)
    body = "\n".join(f"  {c}" for c in clauses)
    return f"[out:json][timeout:{timeout_s}];\n{area}\n(\n{body}\n);\nout center;\n"


def school_like(props: dict) -> bool:
    """A named feature worth storing from a "named" piece: a name that reads
    like a school's in Arabic or English (the rules of schools_import, plus
    the Latin and KG patterns the broad query used)."""
    from schools_import import name_says_school  # local: keeps this module light to import

    for key in NAME_KEYS:
        n = str(props.get(key) or "")
        if n and (name_says_school(n) or _LATIN_SCHOOL.search(n) or _KG.search(n)):
            return True
    return False


def refine_named(part, collection: dict) -> dict:
    """Keeps only school-like features of a "named" piece."""
    if getattr(part, "kind", "") != "named":
        return collection
    collection["features"] = [f for f in collection["features"] if school_like(f.get("properties") or {})]
    return collection


SCHOOLS_QUERY = schools_query()  # all of Egypt in one query: kept for reference and tests
# Stored in the download: a download made by another query (the narrow one
# of the first version, a fallback, or a split run that had to use older
# files for some governorates) is never reused as "recent".
QUERY_ID = "split-1"
PARTIAL_QUERY_ID = "split-1-partial"
PART_QUERY_ID = "pieces-1"  # per-governorate pieces (overpass_split.py); + extra amenity values
NATIONAL_QUERY_ID = "narrow-2"
NARROW_SCHOOLS_QUERY = schools_query(broad=False)
PARTS_FOLDER = "governorates"  # data/schools/osm/governorates/EG-xx.geojson (not read by the importer)
NATIONAL_PART = "EG"  # the narrow amenity-only query for all of Egypt, as a safety net

# Governorates are admin_level 4 in Egypt and carry ISO3166-2=EG-xx; the tag
# filter keeps the neighbours' provinces out (they touch the border).
BOUNDARIES_QUERY = f"""[out:json][timeout:{QUERY_TIMEOUT_S}];
{EGYPT_AREA}
rel["boundary"="administrative"]["admin_level"="4"]["ISO3166-2"~"^EG-"](area.eg);
out geom;
"""

ATTRIBUTION = (
    "Data (c) OpenStreetMap contributors, available under the Open Database License (ODbL 1.0): "
    "https://www.openstreetmap.org/copyright"
)

SCHOOLS_FILE = "egypt_schools_osm.geojson"
BOUNDARIES_FILE = "egypt_governorates_osm.geojson"
REPORT_FILE = "fetch_report.md"  # not .json: the importer reads every .json in the folder

# Egypt has many thousands of schools in OpenStreetMap; an answer with fewer
# than this is a server problem (a cut-off or an empty area), not the data.
MIN_EXPECTED_SCHOOLS = 1000
# 27 governorates; fewer means the boundaries answer is incomplete.
EXPECTED_GOVERNORATES = 27


class FetchError(Exception):
    """Every server failed, or the answer was not usable."""


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

Post = Callable[[str, bytes, float], bytes]


def http_post(url: str, body: bytes, timeout: float) -> bytes:
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={"User-Agent": USER_AGENT, "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 (fixed https endpoints)
        return response.read()


class _Retryable(Exception):
    def __init__(self, message: str, wait_s: float) -> None:
        super().__init__(message)
        self.wait_s = wait_s


def check_answer(data: bytes) -> dict:
    """The decoded Overpass answer; raises _Retryable when the server says it
    gave up (Overpass answers 200 with a "remark" on a timeout or memory
    error, and the elements are then incomplete)."""
    try:
        doc = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        raise _Retryable(f"the answer is not JSON ({type(error).__name__})", 30) from error
    if not isinstance(doc, dict) or not isinstance(doc.get("elements"), list):
        raise _Retryable("the answer has no elements list", 30)
    remark = str(doc.get("remark") or "")
    if "error" in remark.lower() or "timed out" in remark.lower():
        raise _Retryable(f"the server stopped the query: {remark[:200]}", 60)
    return doc


def ordered_endpoints(endpoints: Iterable[str], prefer: str | None) -> list[str]:
    """[endpoints] with [prefer] (the server that just answered) first."""
    items = list(dict.fromkeys(endpoints))
    if prefer and prefer in items:
        items.remove(prefer)
        items.insert(0, prefer)
    return items


def overpass(
    query: str,
    endpoints: Iterable[str] = ENDPOINTS,
    *,
    post: Post = http_post,
    sleep: Callable[[float], None] = time.sleep,
    rounds: int = 2,
    prefer: str | None = None,
    log: Callable[[str], None] = print,
    timeout_s: float = QUERY_TIMEOUT_S,
) -> tuple[dict, str]:
    """Runs [query] on the first server that answers; returns (answer, server).

    Each round asks every server once, starting with [prefer]. A busy
    answer (502, 503, 504, a network error) moves on to the next server at
    once instead of waiting on the same one; only when every server failed
    does it pause (30 s, then 60 s) and try a new round. The main server's
    policy asks for 30 s after 429 or 406, which the pause covers."""
    body = urllib.parse.urlencode({"data": query}).encode("utf-8")
    failures: list[str] = []
    order = ordered_endpoints(endpoints, prefer)
    for round_no in range(1, rounds + 1):
        for url in order:
            host = urllib.parse.urlparse(url).netloc
            try:
                log(f"  asking {host} (round {round_no} of {rounds}; can take a few minutes)...")
                return check_answer(post(url, body, timeout_s + 60)), url
            except urllib.error.HTTPError as error:
                reason = f"HTTP {error.code}"
            except _Retryable as error:
                reason = str(error)
            except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as error:
                reason = f"network error ({type(error).__name__})"
            failures.append(f"{host}: {reason}")
            log(f"  {host}: {reason}; trying the next server")
        if round_no < rounds:
            sleep(30.0 * round_no)
    raise FetchError(
        "no Overpass server gave a complete answer:\n  "
        + "\n  ".join(failures)
        + "\nPublic servers are sometimes busy. Wait 10 minutes and run the same command again."
    )


# ---------------------------------------------------------------------------
# Conversion
# ---------------------------------------------------------------------------

_TYPES = {"node": "node", "way": "way", "relation": "relation"}


def element_point(element: dict) -> tuple[float, float] | None:
    """(lat, lng) of a node, or the centre Overpass gives a way or relation."""
    if element.get("type") == "node":
        lat, lon = element.get("lat"), element.get("lon")
    else:
        center = element.get("center") or {}
        lat, lon = center.get("lat"), center.get("lon")
    if isinstance(lat, (int, float)) and isinstance(lon, (int, float)):
        return float(lat), float(lon)
    return None


def schools_geojson(answer: dict, fetched_at: str, endpoint: str, query_id: str = QUERY_ID) -> dict:
    """Overpass JSON -> a GeoJSON FeatureCollection shaped like the HDX
    OpenStreetMap export: properties are the OSM tags plus osm_id and
    osm_type (and "@id", e.g. "way/123", which the importer reads first so a
    stray "id" tag cannot change the ID); geometry is a Point at the node or
    at the centre of the way or relation. Elements without a position are
    left out and counted."""
    features: list[dict] = []
    for element in answer.get("elements") or []:
        kind = _TYPES.get(str(element.get("type")))
        osm_id = element.get("id")
        if kind is None or not isinstance(osm_id, int):
            continue
        point = element_point(element)
        if point is None:
            continue
        tags = element.get("tags") or {}
        properties = {str(k): str(v) for k, v in tags.items() if isinstance(k, str)}
        properties.update({"osm_id": osm_id, "osm_type": kind, "@id": f"{kind}/{osm_id}"})
        features.append(
            {
                "type": "Feature",
                "properties": properties,
                "geometry": {"type": "Point", "coordinates": [round(point[1], 7), round(point[0], 7)]},
            }
        )
    features.sort(key=lambda f: (f["properties"]["osm_type"], f["properties"]["osm_id"]))
    return {
        "type": "FeatureCollection",
        "name": "Egypt schools and kindergartens from OpenStreetMap (Overpass API)",
        "fetched_at": fetched_at,
        "query": query_id,
        "source": endpoint,
        "license": ATTRIBUTION,
        "features": features,
    }


def counts(collection: dict, answer: dict) -> dict[str, int]:
    result = {"elements": len(answer.get("elements") or []), "features": len(collection["features"])}
    for f in collection["features"]:
        p = f["properties"]
        result[f"type:{p['osm_type']}"] = result.get(f"type:{p['osm_type']}", 0) + 1
        amenity = p.get("amenity", "")
        result[f"amenity:{amenity}"] = result.get(f"amenity:{amenity}", 0) + 1
        if not (p.get("name") or p.get("name:ar") or p.get("name:en")):
            result["no_name"] = result.get("no_name", 0) + 1
    result["no_position"] = result["elements"] - result["features"]
    return result


# --- boundaries -------------------------------------------------------------


def _key(point: list[float]) -> tuple[float, float]:
    return round(point[0], 7), round(point[1], 7)


def stitch_rings(ways: list[list[list[float]]]) -> list[list[list[float]]] | None:
    """Joins way pieces ([lng, lat] lists) end to end into closed rings.
    Pieces may run either way. Returns None when a ring cannot be closed
    (a gap in the relation): the caller then skips that governorate."""
    pending = [w for w in ways if len(w) >= 2]
    rings: list[list[list[float]]] = []
    by_end: dict[tuple[float, float], list[int]] = {}
    for i, w in enumerate(pending):
        by_end.setdefault(_key(w[0]), []).append(i)
        by_end.setdefault(_key(w[-1]), []).append(i)
    used = [False] * len(pending)
    for start in range(len(pending)):
        if used[start]:
            continue
        used[start] = True
        ring = list(pending[start])
        while _key(ring[0]) != _key(ring[-1]):
            end = _key(ring[-1])
            nxt = next((j for j in by_end.get(end, []) if not used[j]), None)
            if nxt is None:
                return None
            used[nxt] = True
            piece = pending[nxt]
            if _key(piece[0]) != end:
                piece = piece[::-1]
            ring.extend(piece[1:])
        if len(ring) >= 4:
            rings.append(ring)
    return rings


def _ring_contains(ring: list[list[float]], lng: float, lat: float) -> bool:
    inside = False
    n = len(ring)
    for i in range(n):
        x1, y1 = ring[i]
        x2, y2 = ring[(i + 1) % n]
        if (y1 > lat) != (y2 > lat) and lng < x1 + (lat - y1) * (x2 - x1) / (y2 - y1):
            inside = not inside
    return inside


def relation_multipolygon(relation: dict) -> list | None:
    """GeoJSON MultiPolygon coordinates of a boundary relation from
    `out geom` (member ways carry a "geometry" list of {lat, lon}). Inner
    rings become holes of the outer ring that contains them."""
    outer_ways: list[list[list[float]]] = []
    inner_ways: list[list[list[float]]] = []
    for member in relation.get("members") or []:
        if member.get("type") != "way":
            continue
        geometry = member.get("geometry") or []
        line = [[float(p["lon"]), float(p["lat"])] for p in geometry if isinstance(p, dict) and "lat" in p and "lon" in p]
        if len(line) < 2:
            continue
        (inner_ways if member.get("role") == "inner" else outer_ways).append(line)
    outers = stitch_rings(outer_ways)
    inners = stitch_rings(inner_ways) if inner_ways else []
    if not outers or inners is None:
        return None
    polygons: list[list] = [[ring] for ring in outers]
    for hole in inners:
        for polygon in polygons:
            if _ring_contains(polygon[0], hole[0][0], hole[0][1]):
                polygon.append(hole)
                break
    return polygons


def boundaries_geojson(answer: dict, fetched_at: str, endpoint: str) -> tuple[dict, list[str]]:
    """Overpass `out geom` relations -> FeatureCollection of MultiPolygons
    with ISO3166-2, name, name:ar and name:en (what Boundaries.load in
    schools_import.py reads). Returns the collection and the problems."""
    features: list[dict] = []
    problems: list[str] = []
    for element in answer.get("elements") or []:
        if element.get("type") != "relation":
            continue
        tags = element.get("tags") or {}
        label = f"{tags.get('ISO3166-2', '?')} {tags.get('name:en') or tags.get('name') or element.get('id')}"
        coords = relation_multipolygon(element)
        if coords is None:
            problems.append(f"{label}: its border has a gap in OpenStreetMap; left out (nearest town is used there)")
            continue
        features.append(
            {
                "type": "Feature",
                "properties": {
                    "ISO3166-2": str(tags.get("ISO3166-2", "")),
                    "name": str(tags.get("name", "")),
                    "name:ar": str(tags.get("name:ar", "")),
                    "name:en": str(tags.get("name:en", "")),
                    "osm_id": element.get("id"),
                    "osm_type": "relation",
                },
                "geometry": {"type": "MultiPolygon", "coordinates": coords},
            }
        )
    features.sort(key=lambda f: f["properties"]["ISO3166-2"])
    collection = {
        "type": "FeatureCollection",
        "name": "Egypt governorates from OpenStreetMap (admin_level 4, Overpass API)",
        "fetched_at": fetched_at,
        "source": endpoint,
        "license": ATTRIBUTION,
        "features": features,
    }
    return collection, problems


# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------


def write_json_atomic(path: Path, doc: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".part")
    tmp.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def query_of(path: Path) -> str:
    """The "query" id of an earlier download ("" for the first version)."""
    try:
        with path.open("rb") as f:
            head = f.read(4096).decode("utf-8", "ignore")
        marker = '"query":"'
        start = head.index(marker) + len(marker)
        return head[start : head.index('"', start)]
    except (OSError, ValueError):
        return ""


def fetched_at_of(path: Path) -> dt.datetime | None:
    """When an earlier download was made (its "fetched_at"), or None."""
    try:
        with path.open("rb") as f:
            head = f.read(4096).decode("utf-8", "ignore")
        marker = '"fetched_at":"'
        start = head.index(marker) + len(marker)
        return dt.datetime.strptime(head[start : start + 20], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except (OSError, ValueError):
        return None


def report_text(
    fetched_at: str,
    endpoint: str,
    school_counts: dict[str, int],
    boundary_note: str,
    query_kind: str = "broad",
    governorate_lines: list[str] | None = None,
) -> str:
    lines = [
        "# OpenStreetMap schools download",
        "",
        f"- Downloaded: {fetched_at} (UTC)",
        f"- Server: {endpoint} (Overpass API), query: {query_kind}",
        f"- Elements in the answer: {school_counts['elements']}",
        f"- Written to {SCHOOLS_FILE}: {school_counts['features']}"
        f" (nodes {school_counts.get('type:node', 0)}, ways {school_counts.get('type:way', 0)},"
        f" relations {school_counts.get('type:relation', 0)})",
        f"- amenity=school: {school_counts.get('amenity:school', 0)}, amenity=kindergarten: {school_counts.get('amenity:kindergarten', 0)},"
        f" other (building, education, school, isced:level or a school-like name; the import decides): "
        f"{school_counts['features'] - school_counts.get('amenity:school', 0) - school_counts.get('amenity:kindergarten', 0)}",
        f"- Without any name (the import drops them): {school_counts.get('no_name', 0)}",
        f"- Without a position (left out): {school_counts['no_position']}",
        f"- Governorate boundaries: {boundary_note}",
    ]
    if governorate_lines:
        lines += ["", "## Per governorate (broad query, one per governorate)", "", *governorate_lines]
    lines += [
        "",
        "## Licence",
        "",
        ATTRIBUTION,
        "",
        "The app shows school names and places taken from this data; the",
        "attribution \"(c) OpenStreetMap contributors\" belongs in the app's",
        "about/licences screen before the public launch (docs/open-items.md).",
        "",
    ]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    from overpass_split import (  # local: overpass_split imports this module
        DEFAULT_BUDGET_MIN,
        PART_TIMEOUT_S,
        Part,
        fetch_parts,
        sub_parts,
        governorate_areas,
        merge_features,
        status_lines,
        summary_line,
    )

    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=repo / "data" / "schools" / "osm", help="folder for the schools file")
    parser.add_argument(
        "--boundaries-out", type=Path, default=repo / "data" / "schools" / "boundaries", help="folder for the governorates file"
    )
    parser.add_argument("--no-boundaries", action="store_true", help="do not download governorate boundaries")
    parser.add_argument(
        "--max-age-days", type=float, default=0,
        help="keep files newer than this (whole download and each governorate; 0: always download)",
    )
    parser.add_argument("--endpoint", action="append", help="Overpass interpreter URL to use instead of the public list (repeatable)")
    parser.add_argument("--prefer", help="the Overpass server to ask first")
    parser.add_argument("--max-minutes", type=float, default=DEFAULT_BUDGET_MIN, help="time budget for new requests")
    parser.add_argument("--categories", type=Path, help="categories.json (default data/schools/categories.json)")
    args = parser.parse_args(argv)
    endpoints = tuple(args.endpoint or ENDPOINTS)

    schools_path = args.out / SCHOOLS_FILE
    boundaries_path = args.boundaries_out / BOUNDARIES_FILE
    parts_dir = args.out / PARTS_FOLDER
    from schools_import import CATEGORIES_FILE, load_categories  # local: keeps this module light to import

    values = amenity_values(load_categories(args.categories or repo / "data" / "schools" / CATEGORIES_FILE))
    part_id = query_id_for(PART_QUERY_ID, values)
    national_id = query_id_for(NATIONAL_QUERY_ID, values)
    merged_id = query_id_for(QUERY_ID, values)
    now = dt.datetime.now(dt.timezone.utc)
    if args.max_age_days > 0:
        last = fetched_at_of(schools_path)
        if last is not None and now - last < dt.timedelta(days=args.max_age_days) and query_of(schools_path) == merged_id:
            print(f"OpenStreetMap schools: the download of {last:%Y-%m-%d %H:%M} UTC is recent; kept (no new download).")
            return 0
    fetched_at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    budget_s = max(args.max_minutes, 1.0) * 60
    started = time.monotonic()

    # Governorates first: their relation ids are the search areas below.
    boundary_note = "not downloaded (--no-boundaries)"
    prefer = args.prefer
    if not args.no_boundaries:
        last_b = fetched_at_of(boundaries_path)
        if args.max_age_days > 0 and last_b is not None and now - last_b < dt.timedelta(days=args.max_age_days):
            boundary_note = f"recent file of {last_b:%Y-%m-%d} kept"
        else:
            boundary_note, server = fetch_boundaries(tuple(ordered_endpoints(endpoints, prefer)), fetched_at, boundaries_path)
            prefer = server or prefer
    governorates = governorate_areas(boundaries_path if boundaries_path.exists() else None)
    parts = sub_parts(governorates, PIECES, split_kinds=("named",))

    def ask(query: str, eps: list[str], first: str | None) -> tuple[dict, str]:
        return overpass(query, eps, rounds=1, prefer=first, timeout_s=PART_TIMEOUT_S)

    print("OpenStreetMap schools: amenity/education values asked for: " + ", ".join(values))
    print(
        f"OpenStreetMap schools: {len(governorates)} governorates in {len(parts)} queries "
        f"(tags, Arabic names, named features; [timeout:{PART_TIMEOUT_S}] each)..."
    )
    split = fetch_parts(
        parts,
        lambda part: piece_query(part.kind, part.area, part.bbox, values, PART_TIMEOUT_S),
        lambda answer, stamp, server: schools_geojson(answer, stamp, server, part_id),
        parts_dir,
        query_id=part_id,
        fetch=ask,
        endpoints=endpoints,
        prefer=prefer,
        max_age_days=args.max_age_days,
        budget_s=budget_s,
        now=now,
        refine=refine_named,
        # Only the tags piece must find something (every governorate has
        # amenity=school); a piece of names may be empty.
        min_features=lambda part: 1 if part.kind == "tags" else 0,
    )
    # Safety net: the narrow amenity-only query for all of Egypt (it
    # finished on 16 Nov 2026 when the broad one did not). It also catches
    # a school outside every governorate area (on the coast, on a gap).
    print("OpenStreetMap schools: the amenity-only query for all of Egypt (safety net)...")
    national = fetch_parts(
        [Part(NATIONAL_PART, "", EGYPT_AREA, "EG all of Egypt, amenity only")],
        lambda _part: schools_query(broad=False, values=values),
        lambda answer, stamp, server: schools_geojson(answer, stamp, server, national_id),
        parts_dir,
        query_id=national_id,
        # One round per pass (fetch_parts' second pass is the retry), so a
        # request started near the end of --max-minutes cannot add another
        # hour of rounds on top of the budget.
        fetch=lambda q, eps, first: overpass(q, eps, rounds=1, prefer=first),
        endpoints=endpoints,
        prefer=split.last_server or prefer,
        max_age_days=args.max_age_days,
        budget_s=max(budget_s - (time.monotonic() - started), 60.0),
        now=now,
        min_features=lambda _p: MIN_EXPECTED_SCHOOLS,
    )
    features = merge_features([*split.collections.values(), *national.collections.values()])
    servers = sorted({s.server for s in split.statuses + national.statuses if s.server})
    complete = split.complete and national.complete
    collection = {
        "type": "FeatureCollection",
        "name": "Egypt schools and kindergartens from OpenStreetMap (Overpass API, per governorate)",
        "fetched_at": fetched_at,
        "query": merged_id if complete else PARTIAL_QUERY_ID,
        "source": ", ".join(servers),
        "license": ATTRIBUTION,
        "governorates": [
            {"code": s.code, "status": s.status, "fetched_at": s.fetched_at, "features": s.features}
            for s in split.statuses + national.statuses
        ],
        "features": features,
    }
    school_counts = counts(collection, {"elements": features})
    gov_lines = status_lines(split) + status_lines(national)
    print("  " + summary_line(split))
    for line in gov_lines:
        if "NO data" in line or "older file" in line:
            print("  " + line[2:])
    if school_counts["features"] < MIN_EXPECTED_SCHOOLS:
        print(
            f"OpenStreetMap schools: only {school_counts['features']} schools in all parts together (expected thousands); "
            "the earlier file is kept. Run again later.",
            file=sys.stderr,
        )
        return 1
    write_json_atomic(schools_path, collection)
    kind = "broad, per governorate" + ("" if split.complete else " (some governorates from older files or missing; see below)")
    (args.out / REPORT_FILE).write_text(
        report_text(fetched_at, ", ".join(servers) or "-", school_counts, boundary_note, kind, gov_lines + ["", "Summary: " + summary_line(split)]),
        encoding="utf-8",
    )
    print(f"  wrote {school_counts['features']} schools and kindergartens to {schools_path}")
    print(f"  boundaries: {boundary_note}")
    print(f"  {ATTRIBUTION}")
    return 0


def fetch_boundaries(endpoints: tuple[str, ...], fetched_at: str, path: Path) -> tuple[str, str | None]:
    """Downloads the governorates; never fails the run (the importer falls
    back to the nearest town). Returns a one-line note for the report and
    the server that answered (None when none did)."""
    print("OpenStreetMap governorates: downloading the 27 borders (admin_level 4)...")
    try:
        answer, endpoint = overpass(BOUNDARIES_QUERY, endpoints)
    except FetchError as error:
        kept = " (the earlier file is kept)" if path.exists() else ""
        print(f"  governorates skipped: {error}", file=sys.stderr)
        return f"download failed{kept}; the import uses the nearest town for the governorate", None
    collection, problems = boundaries_geojson(answer, fetched_at, endpoint)
    for p in problems:
        print(f"  {p}")
    n = len(collection["features"])
    if n == 0:
        return "no usable border came back; the import uses the nearest town for the governorate", endpoint
    write_json_atomic(path, collection)
    missing = f"; {EXPECTED_GOVERNORATES - n} missing (nearest town used there)" if n < EXPECTED_GOVERNORATES else ""
    return f"{n} of {EXPECTED_GOVERNORATES} governorates written to {path.name}{missing}", endpoint


if __name__ == "__main__":
    raise SystemExit(main())
