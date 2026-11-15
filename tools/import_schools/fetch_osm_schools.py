#!/usr/bin/env python3
"""Download every school and kindergarten in Egypt from OpenStreetMap (F4).

    python3 tools/import_schools/fetch_osm_schools.py                 # schools + governorate boundaries
    python3 tools/import_schools/fetch_osm_schools.py --max-age-days 7  # skip if the last download is newer
    python3 tools/import_schools/fetch_osm_schools.py --no-boundaries

Asks the Overpass API (a read-only query service for OpenStreetMap data)
for every node, way and relation tagged amenity=school or
amenity=kindergarten inside Egypt (`out center;`: node positions, and the
centre of each way and relation), and writes:

  data/schools/osm/egypt_schools_osm.geojson   points (way/relation centres),
                                               OSM tags + osm_id/osm_type,
                                               the shape import_schools.py reads
  data/schools/osm/fetch_report.md             date, server, counts, licence
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

# `out center;` (verbosity "body" plus centres), not `out center tags;`:
# per the Overpass QL documentation, "tags" prints "only ids and tags ...
# and not coordinates", and "center" adds a centre only to ways and
# relations, so nodes would come back without a position. "body" adds the
# node list of each way (a few MB more for all of Egypt), which we ignore.
SCHOOLS_QUERY = f"""[out:json][timeout:{QUERY_TIMEOUT_S}];
{EGYPT_AREA}
nwr["amenity"~"^(school|kindergarten)$"](area.eg);
out center;
"""

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


def overpass(
    query: str,
    endpoints: Iterable[str] = ENDPOINTS,
    *,
    post: Post = http_post,
    sleep: Callable[[float], None] = time.sleep,
    attempts_per_endpoint: int = 2,
    log: Callable[[str], None] = print,
) -> tuple[dict, str]:
    """Runs [query] on the first server that answers; returns (answer, server)."""
    body = urllib.parse.urlencode({"data": query}).encode("utf-8")
    failures: list[str] = []
    for url in endpoints:
        host = urllib.parse.urlparse(url).netloc
        for attempt in range(1, attempts_per_endpoint + 1):
            try:
                log(f"  asking {host} (attempt {attempt} of {attempts_per_endpoint}; can take several minutes)...")
                return check_answer(post(url, body, QUERY_TIMEOUT_S + 60)), url
            except urllib.error.HTTPError as error:
                # 429: too many requests, 504: busy, 406: refused. Pause, as the policy asks.
                reason, wait = f"HTTP {error.code}", (30.0 if error.code in (429, 406) else 15.0) * attempt
            except _Retryable as error:
                reason, wait = str(error), error.wait_s * attempt
            except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as error:
                reason, wait = f"network error ({type(error).__name__})", 10.0 * attempt
            failures.append(f"{host}: {reason}")
            log(f"  {host}: {reason}")
            if attempt < attempts_per_endpoint:
                sleep(wait)
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


def schools_geojson(answer: dict, fetched_at: str, endpoint: str) -> dict:
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


def report_text(fetched_at: str, endpoint: str, school_counts: dict[str, int], boundary_note: str) -> str:
    lines = [
        "# OpenStreetMap schools download",
        "",
        f"- Downloaded: {fetched_at} (UTC)",
        f"- Server: {endpoint} (Overpass API)",
        f"- Elements in the answer: {school_counts['elements']}",
        f"- Written to {SCHOOLS_FILE}: {school_counts['features']}"
        f" (nodes {school_counts.get('type:node', 0)}, ways {school_counts.get('type:way', 0)},"
        f" relations {school_counts.get('type:relation', 0)})",
        f"- amenity=school: {school_counts.get('amenity:school', 0)}, amenity=kindergarten: {school_counts.get('amenity:kindergarten', 0)}",
        f"- Without any name (the import drops them): {school_counts.get('no_name', 0)}",
        f"- Without a position (left out): {school_counts['no_position']}",
        f"- Governorate boundaries: {boundary_note}",
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
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=repo / "data" / "schools" / "osm", help="folder for the schools file")
    parser.add_argument(
        "--boundaries-out", type=Path, default=repo / "data" / "schools" / "boundaries", help="folder for the governorates file"
    )
    parser.add_argument("--no-boundaries", action="store_true", help="do not download governorate boundaries")
    parser.add_argument(
        "--max-age-days", type=float, default=0, help="skip the download when the last one is newer than this (0: always download)"
    )
    parser.add_argument("--endpoint", action="append", help="Overpass interpreter URL to use instead of the public list (repeatable)")
    args = parser.parse_args(argv)
    endpoints = tuple(args.endpoint or ENDPOINTS)

    schools_path = args.out / SCHOOLS_FILE
    boundaries_path = args.boundaries_out / BOUNDARIES_FILE
    now = dt.datetime.now(dt.timezone.utc)
    if args.max_age_days > 0:
        last = fetched_at_of(schools_path)
        if last is not None and now - last < dt.timedelta(days=args.max_age_days):
            print(f"OpenStreetMap schools: the download of {last:%Y-%m-%d %H:%M} UTC is recent; kept (no new download).")
            return 0
    fetched_at = now.strftime("%Y-%m-%dT%H:%M:%SZ")

    print("OpenStreetMap schools: downloading every school and kindergarten in Egypt...")
    try:
        answer, endpoint = overpass(SCHOOLS_QUERY, endpoints)
    except FetchError as error:
        print(f"OpenStreetMap schools: {error}", file=sys.stderr)
        return 1
    collection = schools_geojson(answer, fetched_at, endpoint)
    school_counts = counts(collection, answer)
    if school_counts["features"] < MIN_EXPECTED_SCHOOLS:
        print(
            f"OpenStreetMap schools: only {school_counts['features']} schools came back (expected thousands); "
            "the earlier file is kept. Run again later.",
            file=sys.stderr,
        )
        return 1
    write_json_atomic(schools_path, collection)
    print(f"  wrote {school_counts['features']} schools and kindergartens to {schools_path}")

    boundary_note = "not downloaded (--no-boundaries)"
    if not args.no_boundaries:
        boundary_note = fetch_boundaries(endpoints, fetched_at, boundaries_path)
    (args.out / REPORT_FILE).write_text(report_text(fetched_at, endpoint, school_counts, boundary_note), encoding="utf-8")
    print(f"  boundaries: {boundary_note}")
    print(f"  {ATTRIBUTION}")
    return 0


def fetch_boundaries(endpoints: tuple[str, ...], fetched_at: str, path: Path) -> str:
    """Downloads the governorates; never fails the run (the importer falls
    back to the nearest town). Returns a one-line note for the report."""
    print("OpenStreetMap governorates: downloading the 27 borders (admin_level 4)...")
    try:
        answer, endpoint = overpass(BOUNDARIES_QUERY, endpoints)
    except FetchError as error:
        kept = " (the earlier file is kept)" if path.exists() else ""
        print(f"  governorates skipped: {error}", file=sys.stderr)
        return f"download failed{kept}; the import uses the nearest town for the governorate"
    collection, problems = boundaries_geojson(answer, fetched_at, endpoint)
    for p in problems:
        print(f"  {p}")
    n = len(collection["features"])
    if n == 0:
        return "no usable border came back; the import uses the nearest town for the governorate"
    write_json_atomic(path, collection)
    missing = f"; {EXPECTED_GOVERNORATES - n} missing (nearest town used there)" if n < EXPECTED_GOVERNORATES else ""
    return f"{n} of {EXPECTED_GOVERNORATES} governorates written to {path.name}{missing}"


if __name__ == "__main__":
    raise SystemExit(main())
