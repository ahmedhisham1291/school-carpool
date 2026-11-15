#!/usr/bin/env python3
"""Download Egypt's schools and kindergartens from Wikidata (F4, second source).

    python3 tools/import_schools/fetch_wikidata_schools.py
    python3 tools/import_schools/fetch_wikidata_schools.py --max-age-days 7

Asks the Wikidata Query Service (SPARQL) for every item that is an instance
of school (Q3914) or kindergarten (Q126807), or of any subclass of them
(primary, secondary, international, private school, ...), whose country
(P17) is Egypt (Q79) and that has coordinates (P625), with its Arabic and
English labels. Writes

  data/schools/wikidata/egypt_schools_wikidata.geojson
  data/schools/wikidata/fetch_report.md

in the GeoJSON shape the importer reads: properties "@source": "wikidata",
"@id": the QID, name:ar, name:en, and an OSM-style amenity derived from the
item's classes (school, kindergarten, or university/college/training/
historic for classes that are not schools for this app; the importer's
classify_tags then keeps or drops them with the same rules as OSM). An OSM
school tagged wikidata=Q.. and the same item are merged by the importer;
other overlaps go through the usual name + distance duplicate merge.

Wikidata's data is CC0 (public domain, no attribution required; Wikidata
asks for a credit, given in the report). Wikimedia's User-Agent policy asks
for a descriptive User-Agent with a way to reach the operator: set
WIKIDATA_CONTACT (an email address or a web page) to add one.

Python 3.11+, standard library only. Runs in Google Cloud Shell
(tool/cloud_setup.sh step 12).
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
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

from fetch_osm_schools import fetched_at_of, write_json_atomic  # noqa: E402

ENDPOINT = "https://query.wikidata.org/sparql"
SCHOOL_QID = "Q3914"
KINDERGARTEN_QID = "Q126807"
EGYPT_QID = "Q79"

# The service stops a query after 60 seconds. Country first (with the
# optimizer off, the triples run in the order written): a few hundred
# thousand Egyptian items, then their classes walked up to school or
# kindergarten, instead of every school on Earth.
SPARQL = f"""SELECT ?item ?coord ?labelAr ?labelEn ?root ?typeLabel WHERE {{
  hint:Query hint:optimizer "None" .
  ?item wdt:P17 wd:{EGYPT_QID} .
  ?item wdt:P625 ?coord .
  ?item wdt:P31 ?type .
  VALUES ?root {{ wd:{SCHOOL_QID} wd:{KINDERGARTEN_QID} }}
  ?type wdt:P279* ?root .
  FILTER NOT EXISTS {{ ?item wdt:P576 ?dissolved . }}
  OPTIONAL {{ ?item rdfs:label ?labelAr . FILTER(LANG(?labelAr) = "ar") }}
  OPTIONAL {{ ?item rdfs:label ?labelEn . FILTER(LANG(?labelEn) = "en") }}
  OPTIONAL {{ ?type rdfs:label ?typeLabel . FILTER(LANG(?typeLabel) = "en") }}
}}
"""

LICENCE = (
    "Wikidata (https://www.wikidata.org): data under CC0 1.0 (public domain); "
    "attribution is not required, credit given as \"Wikidata\"."
)
SCHOOLS_FILE = "egypt_schools_wikidata.geojson"
REPORT_FILE = "fetch_report.md"

# Classes (English labels, lower case) that are not schools for this app,
# mapped to the OSM-style tag the importer already drops.
NOT_SCHOOL_CLASSES: tuple[tuple[str, dict[str, str]], ...] = (
    (r"universit|faculty|higher education", {"amenity": "university"}),
    (r"\bcollege\b", {"amenity": "college"}),
    # Not "language school": in Egypt a language school is an ordinary
    # school teaching in a foreign language (the OSM rules keep them too).
    (r"driving|music|dance|ballet|art school|conservator|training|vocational|military|police|nursing",
     {"amenity": "training"}),
    (r"madrasa|mosque|mausoleum|museum|monument|archaeolog|historic|heritage|ruin", {"historic": "yes"}),
)
KINDERGARTEN_CLASSES = re.compile(r"kindergarten|preschool|nursery school")


class FetchError(Exception):
    pass


def user_agent() -> str:
    contact = os.environ.get("WIKIDATA_CONTACT", "").strip()
    who = f"; {contact}" if contact else ""
    return f"SchoolCarpoolSchoolsImport/1.0 (non-profit school carpool app, Egypt schools list{who}) Python-urllib"


Post = Callable[[str, bytes, dict[str, str], float], bytes]


def http_post(url: str, body: bytes, headers: dict[str, str], timeout: float) -> bytes:
    request = urllib.request.Request(url, data=body, method="POST", headers=headers)
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 (fixed https endpoint)
        return response.read()


def run_query(
    query: str = SPARQL,
    *,
    post: Post = http_post,
    sleep: Callable[[float], None] = time.sleep,
    attempts: int = 3,
    log: Callable[[str], None] = print,
) -> dict:
    body = urllib.parse.urlencode({"query": query, "format": "json"}).encode("utf-8")
    headers = {
        "User-Agent": user_agent(),
        "Accept": "application/sparql-results+json",
        "Content-Type": "application/x-www-form-urlencoded",
    }
    failures: list[str] = []
    for attempt in range(1, attempts + 1):
        try:
            log(f"  asking query.wikidata.org (attempt {attempt} of {attempts})...")
            doc = json.loads(post(ENDPOINT, body, headers, 90).decode("utf-8"))
            if not isinstance(doc, dict) or not isinstance(doc.get("results", {}).get("bindings"), list):
                raise ValueError("no results.bindings")
            return doc
        except urllib.error.HTTPError as error:
            retry_after = error.headers.get("Retry-After") if error.headers else None
            wait = float(retry_after) if retry_after and retry_after.isdigit() else 30.0 * attempt
            reason = f"HTTP {error.code}"
            if error.code == 403:
                failures.append(reason + " (refused; set WIKIDATA_CONTACT, see the script's help)")
                break
        except (ValueError, UnicodeDecodeError) as error:
            reason, wait = f"bad answer ({type(error).__name__})", 30.0 * attempt
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as error:
            reason, wait = f"network error ({type(error).__name__})", 15.0 * attempt
        failures.append(reason)
        log(f"  query.wikidata.org: {reason}")
        if attempt < attempts:
            sleep(min(wait, 120.0))
    raise FetchError("Wikidata did not answer: " + "; ".join(failures) + ". Run the same command again later.")


_POINT = re.compile(r"Point\(\s*([-0-9.eE]+)\s+([-0-9.eE]+)\s*\)")


def parse_point(wkt: str) -> tuple[float, float] | None:
    """(lat, lng) of a WKT "Point(lng lat)" literal (Wikidata's P625 form)."""
    m = _POINT.search(wkt or "")
    if not m:
        return None
    lng, lat = float(m.group(1)), float(m.group(2))
    if not (-90 <= lat <= 90 and -180 <= lng <= 180):
        return None
    return lat, lng


def _value(binding: dict, key: str) -> str:
    return str((binding.get(key) or {}).get("value") or "")


def classes_to_tags(type_labels: set[str], roots: set[str]) -> dict[str, str]:
    """OSM-style tags for an item from its classes' English labels and the
    root(s) it was found under (school or kindergarten)."""
    joined = " | ".join(sorted(t.lower() for t in type_labels))
    for pattern, tags in NOT_SCHOOL_CLASSES:
        if re.search(pattern, joined):
            return dict(tags)
    if roots == {KINDERGARTEN_QID} or KINDERGARTEN_CLASSES.search(joined):
        return {"amenity": "kindergarten"}
    return {"amenity": "school"}


def schools_geojson(answer: dict, fetched_at: str) -> dict:
    """SPARQL JSON results -> GeoJSON FeatureCollection, one Point per item
    (rows of the same item are merged; the first coordinate in sorted order
    is used so reruns give the same file)."""
    items: dict[str, dict] = {}
    for b in answer.get("results", {}).get("bindings", []):
        uri = _value(b, "item")
        qid = uri.rsplit("/", 1)[-1]
        if not re.fullmatch(r"Q[1-9][0-9]*", qid):
            continue
        item = items.setdefault(qid, {"coords": set(), "ar": "", "en": "", "types": set(), "roots": set()})
        if _value(b, "coord"):
            item["coords"].add(_value(b, "coord"))
        item["ar"] = item["ar"] or _value(b, "labelAr")
        item["en"] = item["en"] or _value(b, "labelEn")
        if _value(b, "typeLabel"):
            item["types"].add(_value(b, "typeLabel"))
        if _value(b, "root"):
            item["roots"].add(_value(b, "root").rsplit("/", 1)[-1])
    features = []
    for qid in sorted(items, key=lambda q: int(q[1:])):
        item = items[qid]
        point = next((p for p in (parse_point(c) for c in sorted(item["coords"])) if p), None)
        if point is None:
            continue
        props: dict[str, object] = {"@source": "wikidata", "@id": qid}
        if item["ar"]:
            props["name:ar"] = item["ar"]
        if item["en"]:
            props["name:en"] = item["en"]
        props.update(classes_to_tags(item["types"], item["roots"]))
        props["wikidata:classes"] = "; ".join(sorted(item["types"]))
        features.append(
            {
                "type": "Feature",
                "properties": props,
                "geometry": {"type": "Point", "coordinates": [round(point[1], 7), round(point[0], 7)]},
            }
        )
    return {
        "type": "FeatureCollection",
        "name": "Egypt schools and kindergartens from Wikidata",
        "fetched_at": fetched_at,
        "source": ENDPOINT,
        "license": LICENCE,
        "features": features,
    }


def report_text(fetched_at: str, collection: dict, rows: int) -> str:
    feats = collection["features"]
    by_amenity: dict[str, int] = {}
    for f in feats:
        key = str(f["properties"].get("amenity") or ("historic" if f["properties"].get("historic") else "?"))
        by_amenity[key] = by_amenity.get(key, 0) + 1
    no_label = sum(1 for f in feats if not (f["properties"].get("name:ar") or f["properties"].get("name:en")))
    return "\n".join(
        [
            "# Wikidata schools download",
            "",
            f"- Downloaded: {fetched_at} (UTC) from {ENDPOINT}",
            f"- Result rows: {rows}; items with coordinates: {len(feats)}",
            "- As OSM-style tags: " + ", ".join(f"{k} {v}" for k, v in sorted(by_amenity.items())),
            f"- Without an Arabic or English label (the import drops them): {no_label}",
            "",
            "## Licence",
            "",
            LICENCE,
            "",
        ]
    )


def main(argv: list[str] | None = None) -> int:
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=repo / "data" / "schools" / "wikidata")
    parser.add_argument("--max-age-days", type=float, default=0, help="skip when the last download is newer (0: always)")
    args = parser.parse_args(argv)
    path = args.out / SCHOOLS_FILE
    now = dt.datetime.now(dt.timezone.utc)
    if args.max_age_days > 0:
        last = fetched_at_of(path)
        if last is not None and now - last < dt.timedelta(days=args.max_age_days):
            print(f"Wikidata schools: the download of {last:%Y-%m-%d %H:%M} UTC is recent; kept (no new download).")
            return 0
    fetched_at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    print("Wikidata schools: asking for every school and kindergarten in Egypt with coordinates...")
    try:
        answer = run_query()
    except FetchError as error:
        print(f"Wikidata schools: {error} The earlier file, if any, is kept.", file=sys.stderr)
        return 1
    rows = len(answer["results"]["bindings"])
    collection = schools_geojson(answer, fetched_at)
    if not collection["features"]:
        print("Wikidata schools: no item came back; the earlier file, if any, is kept.", file=sys.stderr)
        return 1
    write_json_atomic(path, collection)
    (args.out / REPORT_FILE).write_text(report_text(fetched_at, collection, rows), encoding="utf-8")
    print(f"  wrote {len(collection['features'])} items to {path}")
    print(f"  {LICENCE}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
