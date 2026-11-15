#!/usr/bin/env python3
"""One Overpass query per governorate instead of one for all of Egypt.

The broad schools query timed out on every public server when it covered
the whole country (overpass-api.de: "Query timed out in 'query' at line 21
after 548 seconds", the others 502/504; owner's step-12 run, 16 Nov 2026).
The name regexes have to look at every named object in the search area;
27 small areas with a modest [timeout:180] each finish where one big one
does not, and a busy server costs one governorate, not the whole list.

How it works (used by fetch_osm_schools.py and fetch_osm_places.py):

- governorate_areas(): the 27 governorates (ISO 3166-2:EG). The search
  area is the governorate's boundary relation (Overpass area id =
  3600000000 + relation id) when the governorate download knows it, else
  the area tagged ISO3166-2=EG-xx at admin_level 4.
- fetch_parts(): asks for each part in turn (servers in failover order,
  the one that last answered first). Each part is written to its own file
  (<folder>/<code>.geojson, with its own "fetched_at"). A part whose file
  is newer than --max-age-days (and made by the same query) is not asked
  again. After a first pass, the parts that failed get a second pass
  after a pause. A part that still fails keeps its older file, if any
  (its date is reported); with no older file it is "missing". A time
  budget stops new requests; the rest keep their older files.
- merge_features(): all parts' features in one list, each OpenStreetMap
  object once (a school on a governorate border is in two parts).

Python 3.11+, standard library only.
"""

from __future__ import annotations

import datetime as dt
import json
import time
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable

from egypt_places import ISO_3166_2

# Per-governorate server limit. The largest governorate (Cairo) has a few
# hundred thousand named objects; the broad query there is well inside
# this on a server that is not overloaded.
PART_TIMEOUT_S = 180
# Overpass area ids for relations: 3600000000 + relation id (Overpass QL
# documentation, "Area" / map_to_area).
AREA_ID_OFFSET = 3_600_000_000
# Pause before the second pass over the parts that failed (busy servers
# usually recover within a minute or two).
SECOND_PASS_PAUSE_S = 90.0
DEFAULT_BUDGET_MIN = 75.0

STATUS_NEW = "new"  # downloaded now
STATUS_RECENT = "recent"  # the file is newer than --max-age-days; not asked again
STATUS_OLD = "old"  # the download failed; the older file is used
STATUS_MISSING = "missing"  # the download failed and there is no older file
STATUS_SKIPPED = "skipped"  # the time budget ran out; older file used if any


@dataclass(frozen=True)
class Part:
    """One search area: a governorate (code "EG-C", ...) or all of Egypt."""

    code: str
    governorate: str  # internal key ("cairo"); "" for all of Egypt
    area: str  # Overpass statement that sets the named set (".g")
    label: str


@dataclass
class PartStatus:
    code: str
    status: str
    fetched_at: str = ""  # of the file in use ("" when missing)
    features: int = 0
    server: str = ""
    error: str = ""


@dataclass
class SplitResult:
    collections: dict[str, dict] = field(default_factory=dict)  # code -> FeatureCollection in use
    statuses: list[PartStatus] = field(default_factory=list)
    last_server: str | None = None

    @property
    def complete(self) -> bool:
        return all(s.status in (STATUS_NEW, STATUS_RECENT) for s in self.statuses)

    @property
    def usable(self) -> int:
        return sum(1 for s in self.statuses if s.status != STATUS_MISSING and not (s.status == STATUS_SKIPPED and not s.fetched_at))

    def oldest(self) -> str:
        dates = [s.fetched_at for s in self.statuses if s.fetched_at]
        return min(dates) if dates else ""


def governorate_areas(boundaries_path: Path | None, set_name: str = "g") -> list[Part]:
    """The 27 governorates, sorted by code. Uses the relation ids in the
    governorates download (fetch_osm_schools.py) when it has them."""
    relation_of: dict[str, int] = {}
    if boundaries_path is not None:
        try:
            doc = json.loads(boundaries_path.read_text(encoding="utf-8"))
            for feature in doc.get("features") or []:
                props = feature.get("properties") or {}
                code, rid = str(props.get("ISO3166-2") or ""), props.get("osm_id")
                if code in ISO_3166_2 and isinstance(rid, int) and rid > 0:
                    relation_of[code] = rid
        except (OSError, ValueError, AttributeError):
            relation_of = {}
    parts: list[Part] = []
    for code in sorted(ISO_3166_2):
        rid = relation_of.get(code)
        if rid:
            area = f"area(id:{AREA_ID_OFFSET + rid})->.{set_name};"
        else:
            area = f'area["ISO3166-2"="{code}"]["admin_level"="4"]->.{set_name};'
        parts.append(Part(code, ISO_3166_2[code], area, f"{code} {ISO_3166_2[code]}"))
    return parts


def part_path(folder: Path, code: str) -> Path:
    return folder / f"{code}.geojson"


def read_part(path: Path) -> dict | None:
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(doc, dict) or not isinstance(doc.get("features"), list):
        return None
    return doc


def _parse_time(value: str) -> dt.datetime | None:
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except (TypeError, ValueError):
        return None


Fetch = Callable[[str, list[str], str | None], tuple[dict, str]]  # (query, endpoints, prefer) -> (answer, server)
Convert = Callable[[dict, str, str], dict]  # (answer, fetched_at, server) -> FeatureCollection


def fetch_parts(
    parts: Iterable[Part],
    make_query: Callable[[Part], str],
    convert: Convert,
    folder: Path,
    *,
    query_id: str,
    fetch: Fetch,
    endpoints: Iterable[str],
    prefer: str | None = None,
    max_age_days: float = 0,
    budget_s: float = DEFAULT_BUDGET_MIN * 60,
    now: dt.datetime | None = None,
    clock: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
    log: Callable[[str], None] = print,
    write: Callable[[Path, dict], None] | None = None,
    min_features: Callable[[Part], int] = lambda _p: 1,
) -> SplitResult:
    """Downloads each part (see the module docstring). [fetch] asks the
    servers once each (overpass(..., rounds=1)); the second pass here is
    the retry. A part answering with fewer than min_features(part)
    features counts as failed (an empty area means the area lookup or the
    server went wrong, not that a governorate has no school)."""
    from fetch_osm_schools import FetchError, write_json_atomic  # local: no import cycle

    write = write or write_json_atomic
    now = now or dt.datetime.now(dt.timezone.utc)
    stamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    endpoint_list = list(dict.fromkeys(endpoints))
    started = clock()
    result = SplitResult(last_server=prefer)
    parts = list(parts)
    status_of: dict[str, PartStatus] = {}
    pending: list[Part] = []

    for part in parts:
        old = read_part(part_path(folder, part.code))
        old_time = _parse_time(str(old.get("fetched_at"))) if old else None
        if (
            old is not None
            and old_time is not None
            and max_age_days > 0
            and now - old_time < dt.timedelta(days=max_age_days)
            and old.get("query") == query_id
        ):
            result.collections[part.code] = old
            status_of[part.code] = PartStatus(part.code, STATUS_RECENT, str(old["fetched_at"]), len(old["features"]), str(old.get("source") or ""))
        else:
            pending.append(part)

    for pass_no in (1, 2):
        if not pending:
            break
        if pass_no == 2:
            if clock() - started + SECOND_PASS_PAUSE_S >= budget_s:
                break
            log(f"  {len(pending)} part(s) failed; second try in {SECOND_PASS_PAUSE_S:.0f} s ...")
            sleep(SECOND_PASS_PAUSE_S)
        failed: list[Part] = []
        for part in pending:
            if clock() - started >= budget_s:
                failed.append(part)
                status_of.setdefault(part.code, PartStatus(part.code, STATUS_SKIPPED, error="time budget used up"))
                continue
            log(f"  {part.label} (pass {pass_no}) ...")
            try:
                answer, server = fetch(make_query(part), endpoint_list, result.last_server)
                collection = convert(answer, stamp, server)
                n = len(collection["features"])
                if n < min_features(part):
                    raise FetchError(f"only {n} features came back (the area lookup or the server went wrong)")
            except FetchError as error:
                failed.append(part)
                status_of[part.code] = PartStatus(part.code, STATUS_MISSING, error=str(error).splitlines()[0][:200])
                continue
            collection["query"] = query_id
            collection["part"] = part.code
            write(part_path(folder, part.code), collection)
            result.collections[part.code] = collection
            result.last_server = server
            status_of[part.code] = PartStatus(part.code, STATUS_NEW, stamp, n, server)
            log(f"    {n} features from {urllib.parse.urlparse(server).netloc}")
        pending = failed

    for part in pending:  # still failed: older file, if any
        status = status_of.get(part.code) or PartStatus(part.code, STATUS_SKIPPED, error="time budget used up")
        old = read_part(part_path(folder, part.code))
        if old is not None and old.get("fetched_at"):
            result.collections[part.code] = old
            status.fetched_at = str(old["fetched_at"])
            status.features = len(old["features"])
            status.server = str(old.get("source") or "")
            if status.status != STATUS_SKIPPED:
                status.status = STATUS_OLD
        status_of[part.code] = status
    result.statuses = [status_of[p.code] for p in parts]
    return result


def feature_key(feature: dict) -> str:
    """"node/123" (+ the geometry type: a relation can be both a boundary
    polygon and a named place point in the places download)."""
    props = feature.get("properties") or {}
    if props.get("osm_type") and props.get("osm_id") is not None:
        return f"{props['osm_type']}/{props['osm_id']}/{(feature.get('geometry') or {}).get('type', '')}"
    return json.dumps(feature, sort_keys=True, ensure_ascii=False)


def merge_features(collections: Iterable[dict]) -> list[dict]:
    """Every part's features, each OpenStreetMap object once (the first
    copy wins), sorted by type and id."""
    seen: dict[str, dict] = {}
    for collection in collections:
        for feature in collection.get("features") or []:
            seen.setdefault(feature_key(feature), feature)
    return sorted(seen.values(), key=lambda f: ((f.get("properties") or {}).get("osm_type", ""), (f.get("properties") or {}).get("osm_id", 0)))


def status_lines(result: SplitResult) -> list[str]:
    """One Markdown line per part, for fetch_report.md and the step-12 summary."""
    words = {
        STATUS_NEW: "downloaded",
        STATUS_RECENT: "recent file kept",
        STATUS_OLD: "download failed, older file used",
        STATUS_MISSING: "download failed, NO data",
        STATUS_SKIPPED: "not asked (time budget), older file used",
    }
    lines = []
    for s in result.statuses:
        word = words[s.status]
        if s.status == STATUS_SKIPPED and not s.fetched_at:
            word = "not asked (time budget), NO data"
        date = f" {s.fetched_at[:10]}" if s.fetched_at else ""
        why = f" ({s.error})" if s.error and s.status in (STATUS_OLD, STATUS_MISSING) else ""
        lines.append(f"- {s.code} {ISO_3166_2.get(s.code, 'Egypt')}: {word}{date}, {s.features} features{why}")
    return lines


def summary_line(result: SplitResult) -> str:
    """"27 governorates: 25 downloaded, 1 recent, 1 older file (2026-11-09), 0 missing"."""
    count = {k: 0 for k in (STATUS_NEW, STATUS_RECENT, STATUS_OLD, STATUS_MISSING, STATUS_SKIPPED)}
    for s in result.statuses:
        count[s.status] += 1
    stale = [s for s in result.statuses if s.status in (STATUS_OLD, STATUS_SKIPPED) and s.fetched_at]
    oldest = f" (oldest {min(s.fetched_at for s in stale)[:10]})" if stale else ""
    missing = sum(1 for s in result.statuses if not s.fetched_at)
    return (
        f"{len(result.statuses)} governorates: {count[STATUS_NEW]} downloaded, {count[STATUS_RECENT]} recent,"
        f" {len(stale)} older file{oldest}, {missing} with no data"
    )
