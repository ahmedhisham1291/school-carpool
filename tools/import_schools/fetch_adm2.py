#!/usr/bin/env python3
"""Egypt's second-level administrative units (ADM2: qism, markaz, new city)
as the Area layer of City -> Area -> District (F4, F46).

    python3 tools/import_schools/fetch_adm2.py --max-age-days 30
    python3 tools/import_schools/fetch_adm2.py --file ~/Downloads/egy_adm_capmas_20170421_shp.zip

Why: OpenStreetMap has almost no boundaries below the governorate in Egypt
(staging run, 16 Nov 2026: 15 relations at levels 6 to 10, 7,054 schools
with no area). The UN OCHA Common Operational Dataset for Egypt (COD-AB,
HDX dataset "cod-ab-egy", source CAPMAS) has ADM1 = 27 governorates and
ADM2 = 365 units with Arabic and English names (fields ADM2_AR / ADM2_EN,
P-codes ADM2_PCODE, as in every COD-AB; reviewed by OCHA 19 Dec 2024;
checked on a catalog record of the dataset, 16 Nov 2026; the HDX page
itself was not reachable from the build workspace).

Sources, tried in order (the first that gives ADM2 polygons wins):
  1. --file: a local GeoJSON or zipped shapefile (any of the below).
  2. HDX COD-AB: https://data.humdata.org/api/3/action/package_show?id=cod-ab-egy
     -> a resource with "adm2" in its name: GeoJSON, or a zipped shapefile
     (read here with the standard library: .shp + .dbf + .cpg).
  3. geoBoundaries (gbOpen EGY ADM2): https://www.geoboundaries.org/api/current/gbOpen/EGY/ADM2/
     -> "gjDownloadURL" (GeoJSON). English names only (shapeName); the
     Arabic name then falls back to the English one.
Licences: COD-AB on HDX is published by OCHA (licence stated on the HDX
page, usually CC BY-IGO 3.0, "Attribution: OCHA, CAPMAS"); geoBoundaries
gives its licence per boundary in the API answer ("boundaryLicense"). The
licence and source actually used are written to the report and belong in
open item D24.

Writes (git-ignored):
  data/schools/places/egypt_adm2.geojson    MultiPolygons (simplified to ~30 m),
                                            properties id (cod-<pcode>), name:ar,
                                            name:en, adm1 (governorate key), pcode
  data/schools/places/adm2_report.md        source, licence, counts, fields used

Python 3.11+, standard library only.
"""

from __future__ import annotations

import argparse
import datetime as dt
import io
import json
import re
import struct
import sys
import urllib.request
import zipfile
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

from egypt_places import ISO_3166_2  # noqa: E402
from fetch_osm_places import simplify_ring  # noqa: E402
from fetch_osm_schools import fetched_at_of, write_json_atomic  # noqa: E402
from schools_import import governorate_code  # noqa: E402

HDX_PACKAGE = "https://data.humdata.org/api/3/action/package_show?id=cod-ab-egy"
GEOBOUNDARIES = "https://www.geoboundaries.org/api/current/gbOpen/EGY/ADM2/"
USER_AGENT = "school-carpool-schools-import/1.0 (Egypt ADM2 areas; Python urllib)"
OUT_FILE = "egypt_adm2.geojson"
REPORT_FILE = "adm2_report.md"
EXPECTED_MIN = 200  # COD-AB has 365 ADM2 units; fewer than this is not the ADM2 layer

# Field names seen in COD-AB and geoBoundaries files (first one present
# wins; compared without case). OCHA's COD-AB files processed since 2024
# use lower-case adm2_name / adm2_name1 / adm2_name2 with the language of
# each in lang / lang1 / lang2 ("en", "ar"): read by _lang_names first.
NAME_EN_FIELDS = ("ADM2_EN", "admin2Name_en", "ADM2_NAME", "NAME_2", "shapeName")
NAME_AR_FIELDS = ("ADM2_AR", "admin2Name_ar", "NAME_AR_2", "shapeName_ar")
PCODE_FIELDS = ("ADM2_PCODE", "admin2Pcode", "PCODE", "shapeID")
ADM1_FIELDS = ("ADM1_EN", "admin1Name_en", "adm1_name", "ADM1_AR", "NAME_1", "ADM1_PCODE")
# "adm2", "admin2", "ADM2_" in a file or resource name (not adm20).
_ADM2_IN_NAME = re.compile(r"adm(?:in)?[_ ]?2(?!\d)", re.I)

# New cities the owner expects to see as areas (approximate centres, for the
# report only: which ADM2 unit holds each).
NEW_CITIES: tuple[tuple[str, float, float], ...] = (
    ("Sheikh Zayed / الشيخ زايد", 30.050, 30.983),
    ("6th of October / 6 أكتوبر", 29.938, 30.927),
    ("New Cairo, Fifth Settlement / القاهرة الجديدة، التجمع", 30.028, 31.470),
    ("Obour / العبور", 30.228, 31.476),
    ("Shorouk / الشروق", 30.121, 31.611),
    ("10th of Ramadan / العاشر من رمضان", 30.296, 31.750),
)


class Adm2Error(Exception):
    pass


# ---------------------------------------------------------------------------
# Shapefile (polygons) and dBase, standard library only
# ---------------------------------------------------------------------------


def read_dbf(data: bytes, encoding: str = "utf-8") -> list[dict[str, str]]:
    """Rows of a dBase III file as {field: text}."""
    n_records, header_len, record_len = struct.unpack("<IHH", data[4:12])
    fields: list[tuple[str, int]] = []
    pos = 32
    while data[pos] != 0x0D:
        name = data[pos : pos + 11].split(b"\x00")[0].decode("ascii", "replace")
        length = data[pos + 16]
        fields.append((name, length))
        pos += 32
    rows: list[dict[str, str]] = []
    for i in range(n_records):
        start = header_len + i * record_len
        record = data[start : start + record_len]
        if not record or record[:1] == b"*":  # deleted
            continue
        row: dict[str, str] = {}
        off = 1
        for name, length in fields:
            raw = record[off : off + length]
            try:
                value = raw.decode(encoding)
            except UnicodeDecodeError:
                value = raw.decode("cp1256", "replace")
            row[name] = value.strip().strip("\x00")
            off += length
        rows.append(row)
    return rows


def read_shp_polygons(data: bytes) -> list[list[list[list[float]]]]:
    """Each record's rings ([lng, lat] lists) of a polygon shapefile (types
    5, 15, 25); a null shape gives []."""
    out: list[list[list[list[float]]]] = []
    pos = 100
    while pos + 8 <= len(data):
        _rec, length_words = struct.unpack(">ii", data[pos : pos + 8])
        content = data[pos + 8 : pos + 8 + length_words * 2]
        pos += 8 + length_words * 2
        if len(content) < 4:
            out.append([])
            continue
        shape_type = struct.unpack("<i", content[:4])[0]
        if shape_type == 0:
            out.append([])
            continue
        if shape_type not in (5, 15, 25):
            raise Adm2Error(f"shape type {shape_type} is not a polygon")
        n_parts, n_points = struct.unpack("<ii", content[36:44])
        parts = list(struct.unpack(f"<{n_parts}i", content[44 : 44 + 4 * n_parts]))
        base = 44 + 4 * n_parts
        pts = [list(struct.unpack("<dd", content[base + 16 * k : base + 16 * k + 16])) for k in range(n_points)]
        rings = [pts[parts[j] : (parts[j + 1] if j + 1 < n_parts else n_points)] for j in range(n_parts)]
        out.append([r for r in rings if len(r) >= 4])
    return out


def _ring_area(ring: list[list[float]]) -> float:
    return sum(ring[i][0] * ring[i + 1][1] - ring[i + 1][0] * ring[i][1] for i in range(len(ring) - 1)) / 2


def shapefile_features(files: dict[str, bytes]) -> list[dict]:
    """GeoJSON-like features from {.shp, .dbf, .cpg?, .prj?} bytes. Outer
    rings are the clockwise ones (shapefile rule); holes are dropped."""
    shp = next((v for k, v in files.items() if k.lower().endswith(".shp")), None)
    dbf = next((v for k, v in files.items() if k.lower().endswith(".dbf")), None)
    if shp is None or dbf is None:
        raise Adm2Error("the shapefile needs .shp and .dbf")
    cpg = next((v for k, v in files.items() if k.lower().endswith(".cpg")), b"UTF-8")
    prj = next((v for k, v in files.items() if k.lower().endswith(".prj")), b"")
    if prj and b"GEOGCS" not in prj.upper() and b"GEOGCRS" not in prj.upper():
        raise Adm2Error("the shapefile is not in longitude/latitude (WGS 84)")
    encoding = cpg.decode("ascii", "ignore").strip().lower() or "utf-8"
    encoding = {"utf-8": "utf-8", "utf8": "utf-8", "65001": "utf-8", "1256": "cp1256"}.get(encoding, encoding)
    rows = read_dbf(dbf, encoding)
    shapes = read_shp_polygons(shp)
    features = []
    for row, rings in zip(rows, shapes):
        outers = [r for r in rings if _ring_area(r) < 0] or rings  # clockwise = outer
        if outers:
            features.append({"type": "Feature", "properties": row, "geometry": {"type": "MultiPolygon", "coordinates": [[r] for r in outers]}})
    return features


def features_from_bytes(name: str, data: bytes) -> list[dict]:
    """ADM2 features from a GeoJSON or a zip (GeoJSON or shapefile inside;
    the member with "adm2" in its name is preferred)."""
    if name.lower().endswith(".zip") or data[:2] == b"PK":
        archive = zipfile.ZipFile(io.BytesIO(data))
        names = archive.namelist()
        geojsons = [n for n in names if n.lower().endswith((".geojson", ".json"))]
        pick = [n for n in geojsons if _ADM2_IN_NAME.search(n)] or ([] if any("adm" in n.lower() for n in geojsons) else geojsons)
        if pick:
            return features_from_bytes(pick[0], archive.read(pick[0]))
        shps = [n for n in names if n.lower().endswith(".shp")]
        shp = next((n for n in shps if _ADM2_IN_NAME.search(n)), shps[0] if len(shps) == 1 else None)
        if shp is None:
            raise Adm2Error(f"no ADM2 layer in {name} ({len(shps)} shapefiles)")
        stem = shp[:-4]
        return shapefile_features({n: archive.read(n) for n in names if n.startswith(stem + ".")})
    doc = json.loads(data.decode("utf-8-sig"))
    return list(doc.get("features") or [])


def _first(props: dict, keys: tuple[str, ...]) -> tuple[str, str]:
    lower = {str(k).lower(): k for k in props}
    for k in keys:
        real = k if k in props else lower.get(k.lower())
        v = props.get(real) if real is not None else None
        if v is not None and str(v).strip():
            return str(v).strip(), str(real)
    return "", ""


def _lang_names(props: dict) -> dict[str, tuple[str, str]]:
    """{"en": (name, field), "ar": ...} from adm2_name[N] + lang[N] (COD-AB since 2024)."""
    lower = {str(k).lower(): k for k in props}
    out: dict[str, tuple[str, str]] = {}
    for suffix in ("", "1", "2", "3"):
        name_key, lang_key = lower.get(f"adm2_name{suffix}"), lower.get(f"lang{suffix}")
        if name_key is None or lang_key is None:
            continue
        name, lang = str(props.get(name_key) or "").strip(), str(props.get(lang_key) or "").strip().lower()[:2]
        if name and lang and lang not in out:
            out[lang] = (name, str(name_key))
    return out


_SAFE = re.compile(r"[^A-Za-z0-9_-]+")


def to_collection(features: list[dict], source: str, licence: str, fetched_at: str) -> tuple[dict, dict[str, object]]:
    """The places file: id cod-<pcode>, names, governorate key, simplified
    outer rings. Returns it and facts for the report."""
    out: list[dict] = []
    used: dict[str, str] = {}
    no_gov = 0
    for f in features:
        props = f.get("properties") or {}
        geom = f.get("geometry") or {}
        by_lang = _lang_names(props)
        en, k_en = by_lang.get("en") or _first(props, NAME_EN_FIELDS)
        ar, k_ar = by_lang.get("ar") or _first(props, NAME_AR_FIELDS)
        pcode, k_pc = _first(props, PCODE_FIELDS)
        adm1, _ = _first(props, ADM1_FIELDS)
        used.update({k: v for k, v in (("name:en", k_en), ("name:ar", k_ar), ("id", k_pc)) if v})
        if not (en or ar) or not pcode:
            continue
        coords = geom.get("coordinates") or []
        polys = [coords] if geom.get("type") == "Polygon" else coords
        rings = [simplify_ring([[float(x), float(y)] for x, y, *_ in p[0]]) for p in polys if p and len(p[0]) >= 4]
        if not rings:
            continue
        gov = governorate_code(adm1) or ""
        if not gov:
            iso = _first(props, ("ADM1_PCODE",))[0]
            gov = ISO_3166_2.get(iso, "")
        if not gov:
            no_gov += 1
        out.append(
            {
                "type": "Feature",
                "properties": {"id": "cod-" + _SAFE.sub("-", pcode)[:60], "pcode": pcode, "name:ar": ar or en, "name:en": en or ar, "adm1": gov},
                "geometry": {"type": "MultiPolygon", "coordinates": [[[[round(x, 6), round(y, 6)] for x, y in r]] for r in rings]},
            }
        )
    out.sort(key=lambda f: f["properties"]["id"])
    collection = {
        "type": "FeatureCollection",
        "name": "Egypt ADM2 (qism / markaz / new city)",
        "fetched_at": fetched_at,
        "source": source,
        "license": licence,
        "features": out,
    }
    return collection, {"fields": used, "count": len(out), "no_governorate": no_gov, "arabic": bool(used.get("name:ar"))}


# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

Get = Callable[[str], bytes]


def http_get(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=120) as r:  # noqa: S310 (fixed https hosts)
        return r.read()


def from_hdx(get: Get) -> tuple[list[dict], str, str]:
    doc = json.loads(get(HDX_PACKAGE).decode("utf-8"))
    result = doc.get("result") or {}
    licence = str(result.get("license_title") or result.get("license_id") or "see the HDX page")
    resources = result.get("resources") or []

    def score(r: dict) -> int:
        text = f"{r.get('name', '')} {r.get('url', '')}".lower()
        fmt = str(r.get("format", "")).lower()
        s = 0
        if _ADM2_IN_NAME.search(text):
            s += 4
        if "geojson" in fmt or text.endswith(".geojson"):
            s += 3
        if "shp" in fmt or "shp" in text:
            s += 2
        if "zip" in text:
            s += 1
        if "xlsx" in text or "csv" in fmt or "emf" in text or "pdf" in text:
            s -= 10
        return s

    for r in sorted(resources, key=score, reverse=True):
        if score(r) <= 0 or not r.get("url"):
            continue
        try:
            feats = features_from_bytes(str(r["url"]), get(str(r["url"])))
        except (Adm2Error, ValueError, zipfile.BadZipFile, KeyError) as error:
            print(f"  HDX resource {r.get('name')}: {error}", file=sys.stderr)
            continue
        if len(feats) >= EXPECTED_MIN:
            return feats, f"OCHA COD-AB Egypt (HDX cod-ab-egy), {r.get('name')}", f"{licence}; attribution: OCHA, CAPMAS"
    raise Adm2Error("no ADM2 layer found among the HDX resources")


def from_geoboundaries(get: Get) -> tuple[list[dict], str, str]:
    meta = json.loads(get(GEOBOUNDARIES).decode("utf-8"))
    url = str(meta.get("gjDownloadURL") or "")
    if not url:
        raise Adm2Error("geoBoundaries gave no download URL")
    feats = features_from_bytes(url, get(url))
    if len(feats) < EXPECTED_MIN:
        raise Adm2Error(f"geoBoundaries ADM2 has only {len(feats)} units")
    source = f"geoBoundaries gbOpen EGY ADM2 ({meta.get('boundarySource', '?')}, {meta.get('boundaryYearRepresented', '?')})"
    return feats, source, str(meta.get("boundaryLicense") or "see geoBoundaries")


def new_city_lines(collection: dict) -> list[str]:
    """Which ADM2 unit holds each expected new city (report and summary)."""
    from places_import import Shape

    shapes = [
        Shape(f["properties"]["id"], 0, f["properties"]["name:ar"], f["properties"]["name:en"], [p[0] for p in f["geometry"]["coordinates"]])
        for f in collection["features"]
    ]
    lines = []
    for label, lat, lng in NEW_CITIES:
        hit = next((s for s in shapes if s.contains(lat, lng)), None)
        lines.append(f"- {label}: " + (f"area \"{hit.name_en}\" / \"{hit.name_ar}\" ({hit.id})" if hit else "in no ADM2 unit"))
    return lines


def main(argv: list[str] | None = None) -> int:
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=repo / "data" / "schools" / "places")
    parser.add_argument("--file", type=Path, help="a downloaded GeoJSON or zipped shapefile with the ADM2 layer")
    parser.add_argument("--max-age-days", type=float, default=0)
    parser.add_argument("--no-geoboundaries", action="store_true", help="do not fall back to geoBoundaries (English names only)")
    args = parser.parse_args(argv)
    path = args.out / OUT_FILE
    now = dt.datetime.now(dt.timezone.utc)
    if args.max_age_days > 0 and not args.file:
        last = fetched_at_of(path)
        if last is not None and now - last < dt.timedelta(days=args.max_age_days):
            print(f"ADM2 areas: the download of {last:%Y-%m-%d} is recent; kept.")
            return 0
    fetched_at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    attempts: list[tuple[str, Callable[[], tuple[list[dict], str, str]]]] = []
    if args.file:
        attempts.append(("file", lambda: (features_from_bytes(args.file.name, args.file.read_bytes()), f"local file {args.file.name}", "as stated by its publisher")))
    attempts.append(("HDX COD-AB", lambda: from_hdx(http_get)))
    if not args.no_geoboundaries:
        attempts.append(("geoBoundaries", lambda: from_geoboundaries(http_get)))
    for label, attempt in attempts:
        try:
            feats, source, licence = attempt()
        except Exception as error:  # noqa: BLE001 (each source may fail its own way; try the next)
            print(f"ADM2 areas: {label} failed ({type(error).__name__}: {str(error)[:200]})", file=sys.stderr)
            continue
        collection, facts = to_collection(feats, source, licence, fetched_at)
        if facts["count"] < EXPECTED_MIN:
            print(f"ADM2 areas: {label} gave only {facts['count']} usable units; skipped", file=sys.stderr)
            continue
        write_json_atomic(path, collection)
        cities = new_city_lines(collection)
        lines = [
            "# Egypt ADM2 areas",
            "",
            f"- Downloaded: {fetched_at} (UTC)",
            f"- Source: {source}",
            f"- Licence: {licence}",
            f"- Units written: {facts['count']} (without a governorate: {facts['no_governorate']})",
            f"- Fields used: {facts['fields']}" + ("" if facts["arabic"] else " (NO Arabic names in this source: Arabic shows the English name)"),
            "",
            "## New cities",
            "",
            *cities,
            "",
        ]
        (args.out / REPORT_FILE).write_text("\n".join(lines), encoding="utf-8")
        print(f"ADM2 areas: {facts['count']} units from {source}; licence {licence}")
        for line in cities:
            print("  " + line[2:])
        return 0
    print(
        "ADM2 areas: no source worked. Download the Egypt COD-AB boundaries (HDX dataset cod-ab-egy) by hand and run\n"
        "  python3 tools/import_schools/fetch_adm2.py --file <the zip or geojson>",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
