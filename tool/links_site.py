#!/usr/bin/env python3
"""Builds the invite-links Hosting site (Prompt 6, F31) into build/links_site.

The site serves:
  /.well-known/apple-app-site-association  universal links for the iPhone app
  /c/<code>                                a static fallback page (no carpool
                                           data) when the app is not installed
  /privacy /terms /support /delete-account the public legal and support pages
                                           App Store Connect needs (Arabic and
                                           English), built when --support-email
                                           and --operator-name are given
  /                                        a short page about the app (the
                                           marketing URL)

  python3 tool/links_site.py --team-id ABCDE12345 --bundle-id org.schoolcarpool.app.dev \
      [--app-store-url https://apps.apple.com/app/id0000000000] \
      [--support-email help@your-domain --operator-name "Your legal name"] \
      [--dpo-email privacy@your-domain --dpo-name "Data protection officer's name"] [--require-legal]
      [--operator-address "Registered address"] [--require-address]
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
EMAIL = re.compile(r"^[A-Za-z0-9._+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")
# Addresses that would be a placeholder on a public page (guideline 2.1).
PLACEHOLDER_EMAIL = re.compile(r"(example\.(com|org|net)|\.test|\.invalid|localhost)$", re.I)
OPERATOR = re.compile(r"^[^<>&\"\n\r]{2,80}$")
# The operator's registered address (Law 175/2018 Art. 2 Second; consumer law): R8.
ADDRESS = re.compile(r"^[^<>&\"\n\r_]{5,200}$")
LEGAL_PAGES = ("privacy", "terms", "support", "delete-account")
LEGAL_DOCUMENTS = ROOT / "lib" / "features" / "auth" / "legal_documents.dart"
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


def document_versions() -> dict[str, str]:
    """The versions parents accept in the app (lib/features/auth/legal_documents.dart)."""
    text = LEGAL_DOCUMENTS.read_text(encoding="utf-8")
    found = dict(re.findall(r"static const String (terms|privacy|conduct) = '(\d{4}-\d{2}-\d{2})';", text))
    if set(found) != {"terms", "privacy", "conduct"}:
        raise SystemExit("links_site: could not read the document versions from legal_documents.dart")
    return found


def escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def build_legal(
    out: Path, support_email: str, operator_name: str, app_store_url: str, dpo_email: str = "", dpo_name: str = "", operator_address: str = ""
) -> None:
    """Privacy policy, terms, support, account deletion and home pages.

    The privacy policy names a data protection contact (Law 151 of 2020,
    Arts. 8-9: the data protection officer registered with the PDPC):
    --dpo-email / --dpo-name, or the support address and "Data protection
    officer" until one is appointed (docs/legal/owner-actions.md).
    """
    if not EMAIL.match(support_email) or PLACEHOLDER_EMAIL.search(support_email):
        raise SystemExit("links_site: --support-email must be a real address you read (not an example address)")
    if not OPERATOR.match(operator_name.strip()):
        raise SystemExit("links_site: --operator-name must be the legal name of who runs the app")
    dpo_email = dpo_email or support_email
    if not EMAIL.match(dpo_email) or PLACEHOLDER_EMAIL.search(dpo_email):
        raise SystemExit("links_site: --dpo-email must be a real address you read (not an example address)")
    operator_address = operator_address.strip()
    if operator_address and not ADDRESS.match(operator_address):
        raise SystemExit("links_site: --operator-address must be the registered address, plain text")
    dpo_name = dpo_name.strip() or "Data protection officer / مسؤول حماية البيانات"
    if not OPERATOR.match(dpo_name):
        raise SystemExit("links_site: --dpo-name must be a plain name")
    versions = document_versions()
    values = {
        "__SUPPORT_EMAIL__": support_email,
        "__DPO_EMAIL__": dpo_email,
        "__DPO_NAME__": escape(dpo_name),
        # R8: the address follows the name ("Name, address") when given.
        "__ADDRESS_AR__": f"، {escape(operator_address)}" if operator_address else "",
        "__ADDRESS_EN__": f", {escape(operator_address)}" if operator_address else "",
        "__OPERATOR__": escape(operator_name.strip()),
        "__UPDATED__": max(versions["privacy"], versions["terms"]),
        "__PRIVACY_VERSION__": versions["privacy"],
        "__TERMS_VERSION__": versions["terms"],
        "__APP_STORE_URL__": app_store_url or "#",
    }
    for name in (*LEGAL_PAGES, "home"):
        page = (SOURCE / f"{name}.html").read_text(encoding="utf-8")
        for key, value in values.items():
            page = page.replace(key, value)
        if "__" in re.sub(r"https?://\S+", "", page):
            raise SystemExit(f"links_site: {name}.html still has a placeholder")
        (out / ("index.html" if name == "home" else f"{name}.html")).write_text(page, encoding="utf-8")


def build(
    team_id: str,
    bundle_ids: list[str],
    app_store_url: str,
    out: Path = OUT,
    support_email: str = "",
    operator_name: str = "",
    require_legal: bool = False,
    dpo_email: str = "",
    dpo_name: str = "",
    operator_address: str = "",
    require_address: bool = False,
) -> Path:
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
    if require_address and not operator_address.strip():
        raise SystemExit("links_site: --require-address needs --operator-address (the registered address, R8)")
    if support_email or operator_name:
        build_legal(out, support_email, operator_name, app_store_url, dpo_email, dpo_name, operator_address)
    elif require_legal:
        raise SystemExit("links_site: --require-legal needs --support-email and --operator-name")
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--bundle-id", action="append", required=True, help="repeat for several flavors")
    parser.add_argument("--app-store-url", default="")
    parser.add_argument("--support-email", default="", help="public support address shown on the pages")
    parser.add_argument("--operator-name", default="", help="legal name of who runs the app")
    parser.add_argument("--dpo-email", default="", help="data protection officer's address on the privacy policy (default: the support address)")
    parser.add_argument("--dpo-name", default="", help="data protection officer's name (Law 151 of 2020; default: the role)")
    parser.add_argument("--require-legal", action="store_true", help="fail when the legal pages are not built (staging, prod)")
    parser.add_argument("--operator-address", default="", help="registered address of the operator, shown after its name (R8)")
    parser.add_argument("--require-address", action="store_true", help="fail without --operator-address (prod)")
    args = parser.parse_args(argv)
    out = build(
        args.team_id,
        args.bundle_id,
        args.app_store_url,
        OUT,
        args.support_email,
        args.operator_name,
        args.require_legal,
        args.dpo_email,
        args.dpo_name,
        args.operator_address,
        args.require_address,
    )
    legal = "with" if (out / "privacy.html").exists() else "WITHOUT"
    print(f"links_site: wrote {out.relative_to(ROOT)} ({legal} the privacy, terms, support and delete-account pages)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
