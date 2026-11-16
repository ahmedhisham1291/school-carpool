#!/usr/bin/env python3
"""Why is a school missing from the list? (F4 diagnosis)

    python3 tools/import_schools/why_missing.py "مدرسة النيل للغات" "El Alsson School"
    python3 tools/import_schools/why_missing.py --file data/schools/check_names.txt
    python3 tools/import_schools/why_missing.py --input data/schools/sample "Nile School"

Runs the same import as import_schools.py on the downloaded files
(OpenStreetMap per governorate, Wikidata, Overture, the owner's lists) and,
for each name, lists the closest entries in those files and what happened
to each:

  kept as <id>             it is in the list
  merged into <id>         it is in the list under another entry's name
  dropped: <reason>        found in a source, but the rules dropped it
  not in any source        no downloaded file has a name like it

Names are compared the way the importer compares them, loosely: Arabic
letter forms (ة/ه, ى/ي, أ/إ/آ/ا), the article "ال", the words school /
مدرسة / مدارس, stage and boys/girls words, "language" / "لغات" spellings,
and spacing ("عبد الله" = "عبدالله") do not matter. One name per line in
the file; lines starting with # are skipped. Schools are public places, so
the output shows their positions.

Python 3.11+, standard library only.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from schools_import import (  # noqa: E402
    CATEGORIES_FILE,
    DECISIONS_FILE,
    DROP_REASONS,
    REVIEW_FOLDER,
    RawEntry,
    Result,
    doc_id,
    load_categories,
    load_decisions,
    match_tokens,
    normalize_text,
    run,
    token_similarity,
)

MIN_SCORE = 0.6
MAX_MATCHES = 5
_SOURCE_LABEL = {"osm": "OpenStreetMap", "wikidata": "Wikidata", "overture": "Overture"}


def name_keys(name: str) -> tuple[tuple[str, ...], str]:
    """(tokens, the tokens joined with no spaces) for loose comparison."""
    tokens = match_tokens(name)
    return tokens, "".join(t.lstrip("~") for t in tokens)


def score(query: str, name: str) -> float:
    """0 to 1: how well [name] matches what the owner typed."""
    if not query or not name:
        return 0.0
    qt, qj = name_keys(query)
    nt, nj = name_keys(name)
    if not qt or not nt:
        # Only generic words ("مدرسة"): compare the whole normalized text.
        return 1.0 if normalize_text(query) == normalize_text(name) else 0.0
    if qj == nj:
        return 1.0
    best = token_similarity(qt, nt)
    short, long_ = (qt, nt) if len(qt) <= len(nt) else (nt, qt)
    if token_similarity(short, long_) * len(long_) >= len(short) - 1e-9:
        best = max(best, 0.8)  # every word of one name is in the other
    if len(qj) >= 4 and len(nj) >= 4 and (qj in nj or nj in qj):
        best = max(best, 0.7)  # same letters, different spacing
    return best


@dataclass
class Match:
    entry: RawEntry
    score: float
    status: str  # kept / merged / dropped / read
    detail: str  # school id or drop reason


def source_label(source: str) -> str:
    if source.startswith("list_"):
        return f"owner list {source[5:]}"
    return _SOURCE_LABEL.get(source, source)


def entry_status(result: Result) -> dict[int, tuple[str, str]]:
    """id(entry) -> (status, detail) for every entry read."""
    dropped_by_key: dict[str, list[str]] = {}
    for d in result.dropped:
        dropped_by_key.setdefault(d.source_key, []).append(d.reason)
    school_of: dict[str, str] = {}
    for s in result.schools:
        for key in s.source_keys:
            school_of.setdefault(key, s.id)
    out: dict[int, tuple[str, str]] = {}
    placed: set[str] = set()
    for e in result.entries:
        key = f"{e.source}:{e.source_id}"
        if key in school_of and key not in placed:
            # The first entry with this key is the one in the list (a second
            # one is dropped as "same source ID twice").
            placed.add(key)
            sid = school_of[key]
            out[id(e)] = ("kept", sid) if sid == doc_id(e.source, e.source_id) else ("merged", sid)
        elif dropped_by_key.get(key):
            out[id(e)] = ("dropped", dropped_by_key[key].pop(0))
        else:
            out[id(e)] = ("read", "")
    return out


def find(result: Result, query: str, statuses: dict[int, tuple[str, str]], limit: int = MAX_MATCHES) -> list[Match]:
    matches: list[Match] = []
    for e in result.entries:
        best = max(score(query, n) for n in (e.name, e.name_ar, e.name_en))
        if best >= MIN_SCORE:
            status, detail = statuses.get(id(e), ("read", ""))
            matches.append(Match(e, best, status, detail))
    order = {"kept": 0, "merged": 1, "dropped": 2, "read": 3}
    matches.sort(key=lambda m: (-m.score, order[m.status], m.entry.source, m.entry.source_id))
    return matches[:limit]


def describe(m: Match, names_by_id: dict[str, str]) -> str:
    e = m.entry
    shown = " / ".join(dict.fromkeys(n for n in (e.name, e.name_ar, e.name_en) if n)) or "(no name)"
    where = f" at {e.lat:.5f},{e.lng:.5f}" if e.lat is not None and e.lng is not None else ""
    head = f"{source_label(e.source)} {e.source_id} \"{shown}\"{where} (match {m.score:.0%})"
    if m.status == "kept":
        return f"{head}: kept as {m.detail}"
    if m.status == "merged":
        return f"{head}: merged into {m.detail} \"{names_by_id.get(m.detail, '')}\""
    if m.status == "dropped":
        return f"{head}: dropped: {DROP_REASONS.get(m.detail, m.detail)}"
    return f"{head}: read, not in the output"


def osm_gaps(folder: Path) -> list[str]:
    """Governorates with no OpenStreetMap data in the last download."""
    try:
        doc = json.loads((folder / "osm" / "egypt_schools_osm.geojson").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    return [g["code"] for g in doc.get("governorates") or [] if isinstance(g, dict) and not g.get("fetched_at")]


def check(result: Result, queries: list[str], gaps: list[str] | None = None) -> tuple[list[str], dict[str, int]]:
    """The report lines and the count per verdict (kept, merged, dropped, not found)."""
    statuses = entry_status(result)
    names_by_id = {s.id: (s.name_ar if s.name_ar == s.name_en else f"{s.name_ar} / {s.name_en}") for s in result.schools}
    lines: list[str] = []
    verdicts: dict[str, int] = {}
    for q in queries:
        matches = find(result, q, statuses)
        if not matches:
            verdict = "not found"
            lines.append(f"{q}: not in any source (no downloaded file has a name like it)")
        else:
            best = matches[0]
            verdict = {"kept": "kept", "merged": "merged", "dropped": "dropped", "read": "dropped"}[best.status]
            if any(m.status in ("kept", "merged") for m in matches):
                verdict = "kept" if any(m.status == "kept" for m in matches) else "merged"
            lines.append(f"{q}:")
            lines += [f"  - {describe(m, names_by_id)}" for m in matches]
        verdicts[verdict] = verdicts.get(verdict, 0) + 1
    if gaps and verdicts.get("not found"):
        lines.append(f"Note: no OpenStreetMap data for {', '.join(gaps)} in the last download; a school there may be missing for that reason.")
    return lines, verdicts


def summary(verdicts: dict[str, int], total: int) -> str:
    parts = [f"{verdicts.get(k, 0)} {k}" for k in ("kept", "merged", "dropped", "not found")]
    return f"Names check: {total} names: " + ", ".join(parts) + " (kept/merged = in the list)"


def read_names(path: Path) -> list[str]:
    out = []
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(line)
    return out


def main(argv: list[str] | None = None) -> int:
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("names", nargs="*", help="school names, in Arabic or English")
    parser.add_argument("--file", type=Path, help="a file with one name per line")
    parser.add_argument("--input", type=Path, default=repo / "data" / "schools", help="folder with the downloads (as import_schools.py)")
    parser.add_argument("--categories", type=Path, help="categories.json (as import_schools.py)")
    parser.add_argument("--summary-only", action="store_true", help="print only the summary line and the names not in the list")
    args = parser.parse_args(argv)
    queries = list(args.names) + (read_names(args.file) if args.file else [])
    if not queries:
        parser.error("give names, or --file with one name per line")
    if not args.input.is_dir():
        print(f"No folder {args.input}.", file=sys.stderr)
        return 2
    categories_path = args.categories or (
        args.input / CATEGORIES_FILE if (args.input / CATEGORIES_FILE).exists() else repo / "data" / "schools" / CATEGORIES_FILE
    )
    load_categories(categories_path)
    decisions_path = args.input / REVIEW_FOLDER / DECISIONS_FILE
    if not decisions_path.exists():
        decisions_path = repo / "data" / "schools" / REVIEW_FOLDER / DECISIONS_FILE
    result = run(args.input, load_decisions(decisions_path)[0])
    lines, verdicts = check(result, queries, osm_gaps(args.input))
    if args.summary_only:
        blocks: list[list[str]] = []
        for line in lines:
            if not line.startswith("  ") and not line.startswith("Note:"):
                blocks.append([line])
            elif blocks:
                blocks[-1].append(line)
        for block in blocks:
            if not any(": kept as " in l or ": merged into " in l for l in block):
                print("\n".join(block))
    else:
        print("\n".join(lines))
    print(summary(verdicts, len(queries)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
