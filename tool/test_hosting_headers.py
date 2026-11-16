"""Security headers of the two Hosting sites (security review, 16 Nov 2026).

Run: python3 -m unittest discover -s tool -p 'test_*.py' (CI, backend job).
The admin panel shows children's data and ID photos; the links site serves
invite links and the public pages. Both must refuse framing, sniffing,
referrers and powerful browser features, and send HSTS.
"""

import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


def site_headers(target: str) -> dict:
    config = json.loads((ROOT / "firebase.json").read_text(encoding="utf-8"))
    site = next(h for h in config["hosting"] if h["target"] == target)
    block = next(h for h in site["headers"] if h["source"] == "**")
    return {h["key"]: h["value"] for h in block["headers"]}


def directives(policy: str) -> dict:
    out = {}
    for part in policy.split(";"):
        words = part.split()
        if words:
            out[words[0]] = words[1:]
    return out


class CommonHeaders(unittest.TestCase):
    def test_both_sites(self):
        for target in ("admin", "links"):
            with self.subTest(site=target):
                h = site_headers(target)
                self.assertEqual(h["X-Frame-Options"], "DENY")
                self.assertEqual(h["X-Content-Type-Options"], "nosniff")
                self.assertEqual(h["Referrer-Policy"], "no-referrer")
                self.assertIn("max-age=31536000", h["Strict-Transport-Security"])
                self.assertIn("includeSubDomains", h["Strict-Transport-Security"])
                self.assertEqual(h["Cross-Origin-Opener-Policy"], "same-origin")
                for feature in ("camera=()", "microphone=()", "geolocation=()", "payment=()"):
                    self.assertIn(feature, h["Permissions-Policy"])
                self.assertIn("noindex", h["X-Robots-Tag"])
                csp = directives(h["Content-Security-Policy"])
                self.assertEqual(csp["frame-ancestors"], ["'none'"])
                self.assertIn("base-uri", csp)
                # Admin: no forms at all. Links: only same-origin posts (the
                # emergency contact's confirm/stop buttons, /ec/**, R6).
                self.assertEqual(csp["form-action"], ["'none'"] if target == "admin" else ["'self'"])


class AdminPanel(unittest.TestCase):
    def test_enforced_policy_cannot_break_the_flutter_app(self):
        # Enforced: only directives that a Flutter web app never needs.
        csp = directives(site_headers("admin")["Content-Security-Policy"])
        self.assertEqual(set(csp), {"frame-ancestors", "base-uri", "object-src", "form-action"})
        self.assertEqual(csp["object-src"], ["'none'"])

    def test_full_policy_is_reported_first(self):
        # The full policy runs in report-only mode until the owner checked
        # the browser console on staging (docs/security/owner-actions.md).
        h = site_headers("admin")
        report = directives(h["Content-Security-Policy-Report-Only"])
        self.assertEqual(report["default-src"], ["'self'"])
        self.assertNotIn("'unsafe-eval'", report["script-src"])
        self.assertNotIn("'unsafe-inline'", report["script-src"])
        self.assertNotIn("*", report["connect-src"])
        self.assertEqual(report["frame-ancestors"], ["'none'"])
        self.assertEqual(report["object-src"], ["'none'"])

    def test_no_caching_of_the_panel(self):
        self.assertEqual(site_headers("admin")["Cache-Control"], "no-cache")


class LinksSite(unittest.TestCase):
    def test_nothing_loads_from_elsewhere(self):
        csp = directives(site_headers("links")["Content-Security-Policy"])
        self.assertEqual(csp["default-src"], ["'none'"])
        self.assertEqual(csp["base-uri"], ["'none'"])


if __name__ == "__main__":
    unittest.main()
