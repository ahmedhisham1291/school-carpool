"""Tests for tool/links_site.py and the Associated Domains patch (Prompt 6).

    python3 -m unittest discover -s tool -p 'test_*.py' -v
"""

import json
import os
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import links_site  # noqa: E402
import patch_native  # noqa: E402


class LinksSiteTest(unittest.TestCase):
    def test_association_opens_only_invite_links(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = links_site.build("ABCDE12345", ["org.schoolcarpool.app.dev"], "", Path(tmp) / "site")
            aasa = json.loads((out / ".well-known" / "apple-app-site-association").read_text())
            detail = aasa["applinks"]["details"][0]
            self.assertEqual(detail["appIDs"], ["ABCDE12345.org.schoolcarpool.app.dev"])
            self.assertEqual([c["/"] for c in detail["components"]], ["/c/*"])
            page = (out / "invite.html").read_text()
            self.assertNotIn("__APP_STORE_URL__", page)
            self.assertIn('lang="ar"', page)

    def test_refuses_bad_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            for team, bundle, store in [
                ("abc", "org.schoolcarpool.app", ""),
                ("ABCDE12345", "not a bundle", ""),
                ("ABCDE12345", "org.schoolcarpool.app", "javascript:alert(1)"),
            ]:
                with self.assertRaises(SystemExit):
                    links_site.build(team, [bundle], store, Path(tmp) / "site")


class AssociatedDomainsTest(unittest.TestCase):
    def entitlements(self, domain):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "Runner.entitlements"
            with path.open("wb") as f:
                plistlib.dump({"aps-environment": "development"}, f)
            old = os.environ.get("INVITE_LINK_DOMAIN")
            os.environ["INVITE_LINK_DOMAIN"] = domain
            try:
                patch_native.patch_associated_domains(path)
                patch_native.patch_associated_domains(path)  # idempotent
            finally:
                if old is None:
                    os.environ.pop("INVITE_LINK_DOMAIN", None)
                else:
                    os.environ["INVITE_LINK_DOMAIN"] = old
            with path.open("rb") as f:
                return plistlib.load(f)

    def test_adds_applinks_only_when_a_domain_is_set(self):
        self.assertEqual(
            self.entitlements("school-carpool-dev-links.web.app")["com.apple.developer.associated-domains"],
            ["applinks:school-carpool-dev-links.web.app"],
        )
        self.assertNotIn("com.apple.developer.associated-domains", self.entitlements(""))

    def test_refuses_a_bad_domain(self):
        with self.assertRaises(SystemExit):
            self.entitlements("https://evil.example/x")


if __name__ == "__main__":
    unittest.main()
