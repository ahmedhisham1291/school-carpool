#!/usr/bin/env python3
"""Builds the invite-links Hosting site (Prompt 6, F31) into build/links_site.

The site serves:
  /.well-known/apple-app-site-association  universal links for the iPhone app
  /c/<code>                                a static fallback page (no carpool
                                           data) when the app is not installed

  python3 tool/links_site.py --team-id ABCDE12345 --bundle-id org.schoolcarpool.app.dev \
      [--app-store-url https://apps.apple.com/app/id0000000000]
  firebase deploy --only hosting:links --project dev

See SETUP.md section 16. Standard library only; idempotent.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "hosting" / "links"
OUT = ROOT / "build" / "links_site"

TEAM_ID = re.compile(r"^[A-Z0-9]{10}$")
BUNDLE_ID = re.compile(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")
STORE_URL = re.compile(r"^https://(apps\.apple\.com|testflight\.apple\.com)/[A-Za-z0-9/._?=&-]*$")


def association(team_id: str, bundle_ids: list[str]) -> dict:
    """apple-app-site-association: only /c/* opens the app."""
    return {
        "applinks": {
            "details": [
                {
                    "appIDs": [f"{team_id}.{b}" for b in bundle_ids],
                    "components": [{"/": "/c/*", "comment": "Carpool invite links (F31)"}],
                }
            ]
        }
    }


def build(team_id: str, bundle_ids: list[str], app_store_url: str, out: Path = OUT) -> Path:
    if not TEAM_ID.match(team_id):
        raise SystemExit("links_site: --team-id must be the 10-character Apple Team ID")
    for b in bundle_ids:
        if not BUNDLE_ID.match(b):
            raise SystemExit(f"links_site: bad bundle id {b!r}")
    if app_store_url and not STORE_URL.match(app_store_url):
        raise SystemExit("links_site: --app-store-url must be an apps.apple.com or testflight.apple.com link")
    if out.exists():
        shutil.rmtree(out)
    (out / ".well-known").mkdir(parents=True)
    body = json.dumps(association(team_id, bundle_ids), indent=2) + "\n"
    (out / ".well-known" / "apple-app-site-association").write_text(body, encoding="utf-8")
    page = (SOURCE / "invite.html").read_text(encoding="utf-8").replace("__APP_STORE_URL__", app_store_url or "#")
    (out / "invite.html").write_text(page, encoding="utf-8")
    (out / "index.html").write_text(page, encoding="utf-8")
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--bundle-id", action="append", required=True, help="repeat for several flavors")
    parser.add_argument("--app-store-url", default="")
    args = parser.parse_args(argv)
    out = build(args.team_id, args.bundle_id, args.app_store_url)
    print(f"links_site: wrote {out.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
