#!/usr/bin/env python3
"""Schools import (F4): reads data/schools, writes build/schools/schools.json and report.md.

    python3 tools/import_schools/import_schools.py                       # real files in data/schools
    python3 tools/import_schools/import_schools.py --input data/schools/sample

Then load the result into Firestore (see SETUP.md, "Schools list"):

    npm --prefix functions run schools:load:emulator
    npm --prefix functions run schools:load:cloud -- --project <dev|staging|prod> --yes

Python 3.11 or newer, standard library only. Never prints or writes anything
about parents: the inputs are public school lists.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import places_import  # noqa: E402
from schools_import import (  # noqa: E402
    CATEGORIES_FILE,
    DECISIONS_FILE,
    REVIEW_FOLDER,
    dedupe_lines,
    dropped_by_source_lines,
    load_categories,
    load_decisions,
    report_markdown,
    review_lines,
    run,
    schools_json,
    summary_text,
    write_dropped_csvs,
    write_merged_csv,
    write_review_input,
)


def main(argv: list[str] | None = None) -> int:
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", type=Path, default=repo / "data" / "schools", help="folder with the input files")
    parser.add_argument("--out", type=Path, default=repo / "build" / "schools", help="folder for schools.json and report.md")
    parser.add_argument(
        "--generated-at",
        default=None,
        help="timestamp written into the output (default: now, UTC); fix it to compare two runs byte for byte",
    )
    parser.add_argument(
        "--decisions",
        type=Path,
        default=None,
        help="review decisions (default: review/decisions.csv in --input, else data/schools/review/decisions.csv)",
    )
    parser.add_argument(
        "--categories",
        type=Path,
        default=None,
        help="which categories count (default: categories.json in --input, else data/schools/categories.json)",
    )
    args = parser.parse_args(argv)

    if not args.input.is_dir():
        print(f"No folder {args.input}. Put the HDX export there (SETUP.md, 'Schools list').", file=sys.stderr)
        return 2
    categories_path = args.categories or (
        args.input / CATEGORIES_FILE if (args.input / CATEGORIES_FILE).exists() else repo / "data" / "schools" / CATEGORIES_FILE
    )
    categories = load_categories(categories_path)
    print("Categories: " + ", ".join(f"{k} {'on' if v else 'off'}" for k, v in categories.items()))
    generated_at = args.generated_at or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    decisions_path = args.decisions or (
        args.input / REVIEW_FOLDER / DECISIONS_FILE
        if (args.input / REVIEW_FOLDER / DECISIONS_FILE).exists()
        else repo / "data" / "schools" / REVIEW_FOLDER / DECISIONS_FILE
    )
    decisions, decision_problems = load_decisions(decisions_path)
    result = run(args.input, decisions)
    if result.review is not None:
        result.review.problems = decision_problems + result.review.problems
    if not result.files:
        print(f"No .geojson, .csv or .zip files in {args.input}.", file=sys.stderr)
        return 2

    args.out.mkdir(parents=True, exist_ok=True)
    # City -> Area -> District from data/schools/places (fetch_osm_places.py).
    places = None
    places_dir = args.input / places_import.PLACES_FOLDER
    if places_dir.is_dir():
        shapes, points = places_import.load(places_dir)
        adm2, adm2_note = places_import.load_adm2(places_dir)
        if shapes or points or adm2:
            places = places_import.build(shapes, points, result.schools, result.boundaries, adm2, adm2_note)
            places_import.assign(places, result.schools)
            (args.out / "places.json").write_text(
                json.dumps(places_import.to_json(places, generated_at), ensure_ascii=False) + "\n", encoding="utf-8"
            )
    (args.out / "schools.json").write_text(
        json.dumps(schools_json(result, generated_at), ensure_ascii=False, indent=1) + "\n", encoding="utf-8"
    )
    report = report_markdown(result, generated_at)
    if places is not None:
        report += "\n" + "\n".join(places_import.report_lines(places) + places_import.summary_lines(places, result.schools, top=50)) + "\n"
    (args.out / "report.md").write_text(report, encoding="utf-8")
    print(summary_text(result))
    for line in dropped_by_source_lines(result):
        print(line)
    for line in dedupe_lines(result) + review_lines(result):
        print(line)
    rows = write_review_input(result, args.out / "review_input.csv")
    print(f"Review input, one row per entry read ({rows}): {args.out / 'review_input.csv'}")
    members = {m.id: m for group in result.merged_groups for m in group}
    write_merged_csv(result, members, args.out / "merged.csv")
    print(f"Merged entries, one row each: {args.out / 'merged.csv'}")
    dropped_files = write_dropped_csvs(result, args.out)
    if dropped_files:
        print(f"Dropped names per reason: {args.out}/dropped_<reason>.csv (" + ", ".join(f"{r} {n}" for r, n, _ in dropped_files) + ")")
    if places is not None:
        print("\n".join(places_import.summary_lines(places, result.schools)))
        print(f"Wrote {args.out / 'places.json'}.")
    else:
        print("Places: no data/schools/places download; schools get no area (run fetch_osm_places.py).")
    print(f"Wrote {args.out / 'schools.json'} and {args.out / 'report.md'}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
