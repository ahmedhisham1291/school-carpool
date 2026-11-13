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

from schools_import import report_markdown, run, schools_json, summary_text  # noqa: E402


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
    args = parser.parse_args(argv)

    if not args.input.is_dir():
        print(f"No folder {args.input}. Put the HDX export there (SETUP.md, 'Schools list').", file=sys.stderr)
        return 2
    generated_at = args.generated_at or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    result = run(args.input)
    if not result.files:
        print(f"No .geojson, .csv or .zip files in {args.input}.", file=sys.stderr)
        return 2

    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "schools.json").write_text(
        json.dumps(schools_json(result, generated_at), ensure_ascii=False, indent=1) + "\n", encoding="utf-8"
    )
    (args.out / "report.md").write_text(report_markdown(result, generated_at), encoding="utf-8")
    print(summary_text(result))
    print(f"Wrote {args.out / 'schools.json'} and {args.out / 'report.md'}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
