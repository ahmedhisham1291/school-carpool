#!/usr/bin/env python3
"""Schools and kindergartens in Egypt from Overture Maps Places (F4, third source).

    pip install --user duckdb                      # once (Cloud Shell)
    python3 tools/import_schools/fetch_overture_schools.py --max-age-days 30
    python3 tools/import_schools/fetch_overture_schools.py --from-raw --min-confidence 0.7   # no download

Overture Maps Places is an open dataset of points of interest built from
business listings (Meta, Microsoft, Foursquare, PinMeTo, BrightQuery and
others). It does NOT include OpenStreetMap data, so it adds schools that OSM
and Wikidata lack. Checked on docs.overturemaps.org and the Overture
schema/docs repositories on 16 Nov 2026:

- Data: GeoParquet at s3://overturemaps-us-west-2/release/<RELEASE>/theme=places/type=place/*
  (anonymous read, region us-west-2). The latest release is the "latest"
  field of https://stac.overturemaps.org/catalog.json (2026-10-21.0 on
  16 Nov 2026; the next is due 18 Nov 2026).
- Schema (places, schema v1.17+): id, names.primary, names.common (map
  language -> name), taxonomy.primary / taxonomy.hierarchy /
  taxonomy.alternates, basic_category, confidence (0 to 1, "how confident
  we are that the place exists"), operating_status (open,
  temporarily_closed, permanently_closed), sources (dataset, record_id,
  license, ...), addresses (freeform, locality, region, country), bbox.
  The old "categories" property was removed in September 2026.
- Categories used (taxonomy 2026-09-23.0): education > place_of_learning >
  school and its children (elementary_school, middle_school, high_school,
  kindergarten, preschool, private_school, public_school, charter_school,
  montessori_school, waldorf_school, religious_school), and
  day_care_preschool / child_care_and_day_care (nurseries). college_university
  only when the "university" category is on (data/schools/categories.json).
- Licence: CDLA Permissive 2.0 for most providers; Foursquare data under
  Apache 2.0 (NOTICE); AllThePlaces under CC0. Attribution: "Overture Maps
  Foundation, overturemaps.org" plus the providers' lines (ATTRIBUTION).

Only Egypt's box is read: DuckDB pushes the bbox filter down to the
Parquet row groups, so a few hundred MB are read, not the whole world. The
box also covers bits of Libya, Sudan, Gaza, Israel, Jordan and Saudi Arabia:
places with another country in their address are dropped here, and the
importer drops points across the border lines (schools_import.beyond_border).

Writes (git-ignored):
  data/schools/overture/raw/egypt_places_raw.json        every row the query returned
  data/schools/overture/egypt_schools_overture.geojson   rows above the confidence
                                                         threshold, as the importer reads
  data/schools/overture/fetch_report.md                  release, counts, licence

The importer applies the same keep/drop rules as for OpenStreetMap
(schools_import.classify_overture) and merges an Overture place into the
OSM or Wikidata school with the same name within 300 m; Overture is never
the main entry when another source has the school.

Python 3.11+, the duckdb package (with its httpfs extension, installed on
first use from DuckDB's extension server). Nothing about parents is read
or written: these are public places.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
import urllib.request
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

from fetch_osm_schools import fetched_at_of, write_json_atomic  # noqa: E402
from schools_import import (  # noqa: E402
    CATEGORIES_FILE,
    OVERTURE_KG_CATEGORIES,
    OVERTURE_NURSERY_CATEGORIES,
    OVERTURE_SCHOOL_CATEGORIES,
    OVERTURE_UNIVERSITY_CATEGORIES,
    load_categories,
)

STAC_CATALOG = "https://stac.overturemaps.org/catalog.json"
FALLBACK_RELEASE = "2026-10-21.0"
S3_PLACES = "s3://overturemaps-us-west-2/release/{release}/theme=places/type=place/*"
S3_REGION = "us-west-2"
USER_AGENT = "school-carpool-schools-import/1.0 (Overture release lookup; Python urllib)"

# Egypt's box (as EGYPT_BOUNDS in egypt_places.py, a little tighter on the
# west and south where the border is a straight line).
BOX = {"xmin": 24.6, "xmax": 37.1, "ymin": 21.7, "ymax": 31.8}
# Rows below this are not even downloaded; the threshold that decides what
# the import sees is --min-confidence (rows between the two stay in the raw
# file, so another threshold needs no new download).
FETCH_FLOOR = 0.2
DEFAULT_MIN_CONFIDENCE = 0.5
CONFIDENCE_BANDS = (0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9)

QUERY_ID = "overture-places-1"
RAW_FILE = "egypt_places_raw.json"
OUT_FILE = "egypt_schools_overture.geojson"
REPORT_FILE = "fetch_report.md"

ATTRIBUTION = (
    "Overture Maps Foundation, overturemaps.org. Places data from Meta, Microsoft, PinMeTo, Krick, RenderSEO, "
    "DAC, BrightQuery, Birdeye, Uberall and OpenTravel Alliance under CDLA Permissive 2.0 "
    "(https://cdla.dev/permissive-2-0/); Foursquare data (c) Foursquare Labs, Inc., under Apache 2.0, "
    "transformed to the Overture schema (https://opensource.foursquare.com/places-notice-txt/); "
    "AllThePlaces data under CC0 1.0."
)


def categories_for(categories: dict[str, bool]) -> list[str]:
    values = set(OVERTURE_SCHOOL_CATEGORIES) | set(OVERTURE_KG_CATEGORIES)
    if categories.get("nursery", True):
        values |= OVERTURE_NURSERY_CATEGORIES
    if categories.get("university", False):
        values |= OVERTURE_UNIVERSITY_CATEGORIES
    return sorted(values)


def overture_sql(release: str, categories: list[str], box: dict[str, float] = BOX, floor: float = FETCH_FLOOR) -> str:
    """The DuckDB query. Places are points, so bbox.xmin/ymin is the point
    (Overture's DuckDB guide filters places the same way); no spatial
    extension is needed. Struct and map columns go out as JSON text so the
    result does not depend on how a DuckDB version maps them to Python."""
    cats = ", ".join(f"'{c}'" for c in categories)
    return f"""SELECT
  id,
  bbox.xmin AS lon,
  bbox.ymin AS lat,
  to_json(names) AS names,
  taxonomy.primary AS category,
  to_json(taxonomy.alternates) AS alternates,
  basic_category,
  confidence,
  operating_status,
  to_json(sources) AS sources,
  to_json(addresses) AS addresses
FROM read_parquet('{S3_PLACES.format(release=release)}', hive_partitioning = 1)
WHERE bbox.xmin BETWEEN {box['xmin']} AND {box['xmax']}
  AND bbox.ymin BETWEEN {box['ymin']} AND {box['ymax']}
  AND (taxonomy.primary IN ({cats}) OR list_has_any(coalesce(taxonomy.alternates, []::VARCHAR[]), [{cats}]))
  AND coalesce(confidence, 0) >= {floor}
ORDER BY id"""


COLUMNS = ("id", "lon", "lat", "names", "category", "alternates", "basic_category", "confidence", "operating_status", "sources", "addresses")


def latest_release(fetch: Callable[[str], bytes] | None = None) -> str:
    """The "latest" release named by Overture's STAC catalog, else FALLBACK_RELEASE."""

    def get(url: str) -> bytes:
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as r:  # noqa: S310 (fixed https URL)
            return r.read()

    try:
        doc = json.loads((fetch or get)(STAC_CATALOG).decode("utf-8"))
        value = str(doc.get("latest") or "")
        if value and value[:4].isdigit():
            return value
    except Exception as error:  # noqa: BLE001 (any failure: use the fallback)
        print(f"Overture: could not read the release catalog ({type(error).__name__}); using {FALLBACK_RELEASE}.", file=sys.stderr)
    return FALLBACK_RELEASE


class DuckDBMissing(Exception):
    pass


def run_duckdb(sql: str) -> list[dict]:
    """Runs [sql] with DuckDB (anonymous S3). Raises DuckDBMissing when the
    package is not installed."""
    try:
        import duckdb  # type: ignore[import-not-found]
    except ImportError as error:
        raise DuckDBMissing(str(error)) from error
    con = duckdb.connect()
    try:
        con.execute("INSTALL httpfs; LOAD httpfs;")
        con.execute(f"SET s3_region = '{S3_REGION}';")
        cursor = con.execute(sql)
        names = [d[0] for d in cursor.description]
        return [dict(zip(names, row)) for row in cursor.fetchall()]
    finally:
        con.close()


# ---------------------------------------------------------------------------
# Conversion
# ---------------------------------------------------------------------------


def _json(value: object) -> object:
    if isinstance(value, str):
        try:
            return json.loads(value)
        except ValueError:
            return None
    return value


def _common(names: dict) -> dict[str, str]:
    """names.common as {language: name}: DuckDB writes a MAP either as an
    object or as a list of {key, value}."""
    common = names.get("common") if isinstance(names, dict) else None
    if isinstance(common, dict):
        return {str(k): str(v) for k, v in common.items() if v}
    if isinstance(common, list):
        out = {}
        for item in common:
            if isinstance(item, dict) and item.get("key") and item.get("value"):
                out[str(item["key"])] = str(item["value"])
        return out
    return {}


def _band(confidence: float) -> str:
    low = max((b for b in CONFIDENCE_BANDS if confidence >= b), default=0.0)
    return f"{low:.1f}+"


def to_geojson(rows: list[dict], min_confidence: float, fetched_at: str, release: str) -> tuple[dict, dict[str, dict[str, int]]]:
    """Raw rows -> the FeatureCollection the importer reads (properties
    "@source": "overture", "@id", name, name:ar, name:en,
    overture:category, overture:confidence, overture:datasets, addr:city)
    and counts for the report."""
    stats: dict[str, dict[str, int]] = {k: {} for k in ("rows", "category", "band", "dataset", "skipped", "kept")}

    def bump(group: str, key: str) -> None:
        stats[group][key] = stats[group].get(key, 0) + 1

    features: list[dict] = []
    seen: set[str] = set()
    for row in rows:
        bump("rows", "all")
        pid = str(row.get("id") or "")
        lon, lat = row.get("lon"), row.get("lat")
        if not pid or not isinstance(lon, (int, float)) or not isinstance(lat, (int, float)) or pid in seen:
            bump("skipped", "no id or position, or a repeat")
            continue
        seen.add(pid)
        category = str(row.get("category") or "")
        alternates = _json(row.get("alternates")) or []
        if category not in set(categories_for({"nursery": True, "university": True})):
            # Matched through an alternate category only: use that one.
            category = next((a for a in alternates if isinstance(a, str) and a in categories_for({"nursery": True, "university": True})), category)
        bump("category", category or "?")
        confidence = float(row.get("confidence") or 0.0)
        bump("band", _band(confidence))
        sources = _json(row.get("sources")) or []
        datasets = sorted({str(s.get("dataset")) for s in sources if isinstance(s, dict) and s.get("dataset")})
        for d in datasets:
            bump("dataset", d)
        if str(row.get("operating_status") or "") == "permanently_closed":
            bump("skipped", "permanently closed")
            continue
        if confidence < min_confidence:
            bump("skipped", f"confidence below {min_confidence}")
            continue
        addresses = _json(row.get("addresses")) or []
        first = addresses[0] if addresses and isinstance(addresses[0], dict) else {}
        country = str(first.get("country") or "").upper()
        if country and country != "EG":
            bump("skipped", "address in another country")
            continue
        names = _json(row.get("names")) or {}
        common = _common(names)
        primary = str(names.get("primary") or "") if isinstance(names, dict) else ""
        props: dict[str, object] = {
            "@source": "overture",
            "@id": pid,
            "name": primary,
            "name:ar": common.get("ar", ""),
            "name:en": common.get("en", ""),
            "overture:category": category,
            "overture:confidence": round(confidence, 3),
            "overture:datasets": ";".join(datasets),
        }
        if first.get("locality"):
            props["addr:city"] = str(first["locality"])
        if common.get("ar"):
            bump("kept", "with an Arabic name")
        if common.get("en"):
            bump("kept", "with an English name")
        bump("kept", "all")
        features.append(
            {"type": "Feature", "properties": props, "geometry": {"type": "Point", "coordinates": [round(float(lon), 7), round(float(lat), 7)]}}
        )
    features.sort(key=lambda f: str(f["properties"]["@id"]))
    collection = {
        "type": "FeatureCollection",
        "name": "Egypt schools and kindergartens from Overture Maps Places",
        "fetched_at": fetched_at,
        "query": QUERY_ID,
        "release": release,
        "min_confidence": min_confidence,
        "license": ATTRIBUTION,
        "features": features,
    }
    return collection, stats


def _counts(d: dict[str, int]) -> str:
    return ", ".join(f"{k} {v}" for k, v in sorted(d.items(), key=lambda kv: (-kv[1], kv[0]))) or "none"


def report_text(fetched_at: str, release: str, min_confidence: float, stats: dict[str, dict[str, int]]) -> str:
    return "\n".join(
        [
            "# Overture Maps Places download (schools and kindergartens)",
            "",
            f"- Downloaded: {fetched_at} (UTC), release {release} ({S3_PLACES.format(release=release)})",
            f"- Rows from the query (confidence >= {FETCH_FLOOR}): {stats['rows'].get('all', 0)}",
            f"- Written for the import (confidence >= {min_confidence}, not permanently closed, Egypt): {stats['kept'].get('all', 0)}"
            f" (with an Arabic name {stats['kept'].get('with an Arabic name', 0)}, with an English name {stats['kept'].get('with an English name', 0)})",
            f"- Per category: {_counts(stats['category'])}",
            f"- Per confidence band: {_counts(stats['band'])}",
            f"- Per upstream dataset: {_counts(stats['dataset'])}",
            f"- Not written: {_counts(stats['skipped'])}",
            "- The import decides what is kept (same rules as OpenStreetMap, plus the name check) and merges"
            " Overture places into the OSM or Wikidata school with the same name within 300 m.",
            "",
            "## Licence and attribution",
            "",
            ATTRIBUTION,
            "",
            "This attribution goes on the app's about/licences screen with the OpenStreetMap",
            "and Wikidata lines before the public launch (docs/open-items.md D24).",
            "",
        ]
    )


def summary_line(stats: dict[str, dict[str, int]], release: str, min_confidence: float) -> str:
    return (
        f"Overture places (release {release}): {stats['rows'].get('all', 0)} rows, "
        f"{stats['kept'].get('all', 0)} with confidence >= {min_confidence}"
    )


def main(argv: list[str] | None = None) -> int:
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=repo / "data" / "schools" / "overture")
    parser.add_argument("--max-age-days", type=float, default=0, help="keep a raw download newer than this (0: always download)")
    parser.add_argument("--min-confidence", type=float, default=DEFAULT_MIN_CONFIDENCE)
    parser.add_argument("--release", help=f"Overture release (default: the latest in {STAC_CATALOG})")
    parser.add_argument("--from-raw", action="store_true", help="convert the raw file again (another threshold); no download")
    parser.add_argument("--categories", type=Path, help="categories.json (default data/schools/categories.json)")
    parser.add_argument("--print-sql", action="store_true", help="print the query and stop")
    args = parser.parse_args(argv)
    raw_path = args.out / "raw" / RAW_FILE
    now = dt.datetime.now(dt.timezone.utc)
    fetched_at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    categories = categories_for(load_categories(args.categories or repo / "data" / "schools" / CATEGORIES_FILE))
    query_id = QUERY_ID + "+" + "+".join(categories)

    raw = None
    if args.from_raw or args.max_age_days > 0:
        last = fetched_at_of(raw_path)
        try:
            candidate = json.loads(raw_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            candidate = None
        recent = last is not None and now - last < dt.timedelta(days=max(args.max_age_days, 0))
        if candidate and candidate.get("query") == query_id and (args.from_raw or recent):
            raw = candidate
            print(f"Overture: the download of {last:%Y-%m-%d} (release {raw.get('release')}) is recent; converted again, no download.")
        elif args.from_raw:
            print(f"Overture: no usable raw file at {raw_path} (or made for other categories); run without --from-raw.", file=sys.stderr)
            return 1
    if raw is None:
        release = args.release or latest_release()
        sql = overture_sql(release, categories)
        if args.print_sql:
            print(sql)
            return 0
        print(f"Overture: reading schools and kindergartens in Egypt's box from release {release} (a few minutes)...")
        try:
            rows = run_duckdb(sql)
        except DuckDBMissing:
            print(
                "Overture: the duckdb Python package is not installed. Install it with\n"
                "  pip install --user duckdb\n"
                "and run this script again (Overture is skipped until then; OSM and Wikidata still load).",
                file=sys.stderr,
            )
            return 3
        except Exception as error:  # noqa: BLE001 (DuckDB raises its own error types)
            print(f"Overture: the query failed ({type(error).__name__}: {str(error)[:300]}). The earlier files, if any, are kept.", file=sys.stderr)
            return 1
        rows = [{k: r.get(k) for k in COLUMNS} for r in rows]
        raw = {"fetched_at": fetched_at, "query": query_id, "release": release, "license": ATTRIBUTION, "rows": rows}
        write_json_atomic(raw_path, raw)
    collection, stats = to_geojson(raw["rows"], args.min_confidence, str(raw["fetched_at"]), str(raw["release"]))
    write_json_atomic(args.out / OUT_FILE, collection)
    (args.out / REPORT_FILE).write_text(report_text(str(raw["fetched_at"]), str(raw["release"]), args.min_confidence, stats), encoding="utf-8")
    print("  " + summary_line(stats, str(raw["release"]), args.min_confidence))
    print(f"  per category: {_counts(stats['category'])}")
    print(f"  per confidence band: {_counts(stats['band'])}")
    print(f"  per upstream dataset: {_counts(stats['dataset'])}")
    print(f"  {ATTRIBUTION}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
