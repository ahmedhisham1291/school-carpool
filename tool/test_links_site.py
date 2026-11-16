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


class LegalPagesTest(unittest.TestCase):
    """Public privacy policy, terms, support and account-deletion pages (guidelines 5.1.1(i), 1.2, 5.1.1(v))."""

    def build(self, tmp, **kwargs):
        return links_site.build("ABCDE12345", ["org.schoolcarpool.app"], "https://apps.apple.com/app/id1234567890", Path(tmp) / "site", **kwargs)

    def test_pages_are_complete_and_bilingual(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = self.build(tmp, support_email="help@schoolcarpool.org", operator_name="School Carpool Foundation")
            for name in ("privacy", "terms", "support", "delete-account", "index"):
                page = (out / f"{name}.html").read_text(encoding="utf-8")
                self.assertNotIn("__", page.replace("https://", ""), name)
                self.assertIn('lang="ar" dir="rtl"', page)
                self.assertIn('dir="ltr" lang="en"', page)
                for word in ("lorem", "TODO", "coming soon", "draft", "Android", "Google Play", "beta"):
                    self.assertNotIn(word.lower(), page.lower(), f"{name}: {word}")
            for name in ("privacy", "terms", "support", "delete-account"):
                page = (out / f"{name}.html").read_text(encoding="utf-8")
                self.assertIn("mailto:help@schoolcarpool.org", page)
            privacy = (out / "privacy.html").read_text(encoding="utf-8")
            versions = links_site.document_versions()
            self.assertIn(versions["privacy"], privacy)
            self.assertIn("School Carpool Foundation", privacy)
            # What guideline 5.1.1(i) asks a policy to say.
            for must in ("Data we collect", "Why we use it", "Companies that process data for us", "How long we keep it",
                         "withdraw any consent", "Deleting your account", "Belgium", "WhatsApp", "Stream", "Algolia",
                         "Sentry", "Google Maps", "never sell", "Personal Data Protection Centre"):
                self.assertIn(must, privacy)
            # Legal review (16 Nov 2026, docs/legal/egypt-legal-review.md).
            for must in ("6 working days", "6 أيام عمل", "72 hours", "Storage abroad", "Articles 14 to 16", "Data protection officer",
                         "mailto:help@schoolcarpool.org", "180 days", "explicit consent", "parent or guardian"):
                self.assertIn(must, privacy)
            self.assertNotIn("30 days", privacy.replace("up to 30 days", ""))
            # R1 (owner, 16 Nov 2026): proof of consent 3 years after closure.
            self.assertIn("then 3 years after it closes, as proof of consent", privacy)
            self.assertIn("ثم 3 سنوات بعد إغلاقه", privacy)
            deletion = (out / "delete-account.html").read_text(encoding="utf-8")
            self.assertIn("as proof of consent: 3 years after deletion", deletion)
            self.assertNotIn("as proof of consent: 1 year", deletion)
            # R3: written consent (typed name + Face ID / passcode) and a copy on the Privacy screen.
            self.assertIn("your full name typed (it must match your ID)", privacy)
            self.assertIn("open and download a copy on the Privacy screen", privacy)
            # R6: emergency contact opt-in.
            self.assertIn("send them, from your phone, a link to confirm or say no", privacy)
            # R4: children 15 to 18.
            self.assertIn("the child was told what is shared and agrees", privacy)
            # R2 (owner, 16 Nov 2026): the legal sign-in log survives deletion, 180 days from each sign-in.
            self.assertIn("also after you delete your account", privacy)
            self.assertIn("disclosed only on an order of a competent judicial authority", privacy)
            self.assertNotIn("deleted with the account if you delete it sooner", privacy)
            self.assertIn("180 days from each sign-in", deletion)
            terms = (out / "terms.html").read_text(encoding="utf-8")
            for must in ("Arabic text prevails", "النص العربي", "Law No. 87 of 2018", "gross negligence", "compulsory insurance"):
                self.assertIn(must, terms)
            for must in ("no tolerance for objectionable content", "within 24 hours", "122", "123", "does not replace", "no commission",
                         "free volunteer turns", "No parent pays another parent for a ride"):
                self.assertIn(must, terms)
            # No money in the app (owner, 16 Nov 2026): no payment wording on the public pages.
            for name in ("privacy", "terms", "delete-account", "support"):
                page = (out / f"{name}.html").read_text(encoding="utf-8")
                for word in ("InstaPay", "إنستاباي", "Settle up", "تسوية الحساب", "wallet", "المحفظة"):
                    self.assertNotIn(word, page, f"{name}: {word}")
            # The invite page is still there for /c/<code>.
            self.assertIn("carpool invite", (out / "invite.html").read_text(encoding="utf-8"))
            self.assertIn("https://apps.apple.com/app/id1234567890", (out / "index.html").read_text(encoding="utf-8"))

    def test_data_protection_officer(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = self.build(tmp, support_email="help@schoolcarpool.org", operator_name="School Carpool Foundation",
                             dpo_email="privacy@schoolcarpool.org", dpo_name="Mona Adel")
            privacy = (out / "privacy.html").read_text(encoding="utf-8")
            self.assertIn("mailto:privacy@schoolcarpool.org", privacy)
            self.assertIn("Mona Adel", privacy)
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit):
                self.build(tmp, support_email="help@schoolcarpool.org", operator_name="School Carpool Foundation", dpo_email="dpo@example.com")

    def test_without_contact_details_no_legal_pages(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = self.build(tmp)
            self.assertFalse((out / "privacy.html").exists())
            self.assertTrue((out / "index.html").exists())
            with self.assertRaises(SystemExit):
                self.build(tmp, require_legal=True)

    def test_refuses_placeholder_contact_details(self):
        with tempfile.TemporaryDirectory() as tmp:
            for email, name in [
                ("dev@example.com", "School Carpool"),
                ("not-an-email", "School Carpool"),
                ("help@schoolcarpool.org", ""),
                ("help@schoolcarpool.org", "<script>"),
            ]:
                with self.assertRaises(SystemExit):
                    self.build(tmp, support_email=email, operator_name=name)

    def test_hosting_serves_clean_urls(self):
        config = json.loads((links_site.ROOT / "firebase.json").read_text(encoding="utf-8"))
        links = next(h for h in config["hosting"] if h["target"] == "links")
        self.assertIs(links["cleanUrls"], True)


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
