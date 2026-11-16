"""Tests for the App Review settings in tool/patch_native.py
(docs/apple-review/audit.md).

    python3 -m unittest discover -s tool -p 'test_*.py' -v
"""

import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import patch_native  # noqa: E402

TOOL_IOS = Path(__file__).resolve().parent / "ios"
PBX = (
    "\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.schoolCarpool;\n"
    "\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.schoolCarpool.RunnerTests;\n"
    "\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 13.0;\n"
    '\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";\n'
)
TEMPLATE_INFO = {
    "CFBundleDisplayName": "School Carpool",
    "LSRequiresIPhoneOS": True,
    "UILaunchStoryboardName": "LaunchScreen",
    "UISupportedInterfaceOrientations": [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ],
    "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown"],
}
PURPOSE_KEYS = (
    "NSCameraUsageDescription",
    "NSPhotoLibraryUsageDescription",
    "NSLocationWhenInUseUsageDescription",
    "NSLocationAlwaysAndWhenInUseUsageDescription",
    "NSFaceIDUsageDescription",
)


class FlavorTest(unittest.TestCase):
    def test_flavor_from_bundle_id(self):
        self.assertEqual(patch_native.flavor_for("org.schoolcarpool.app.dev", None), "dev")
        self.assertEqual(patch_native.flavor_for("org.schoolcarpool.app.stg", None), "staging")
        self.assertEqual(patch_native.flavor_for("org.schoolcarpool.app", None), "prod")
        self.assertEqual(patch_native.flavor_for("org.schoolcarpool.app", "staging"), "staging")
        with self.assertRaises(SystemExit):
            patch_native.flavor_for("org.schoolcarpool.app", "beta")

    def test_prod_name_refuses_test_wording(self):
        patch_native.check_prod_name("prod", "School Carpool")
        patch_native.check_prod_name("staging", "School Carpool Stg")
        for name in ("School Carpool Stg", "School Carpool Dev", "School Carpool beta", "Test Carpool"):
            with self.assertRaises(SystemExit):
                patch_native.check_prod_name("prod", name)


class PbxTest(unittest.TestCase):
    def test_iphone_only_bundle_id_and_minimum(self):
        out = "".join(patch_native.pbx_line(line, "org.schoolcarpool.app") for line in PBX.splitlines(keepends=True))
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = org.schoolcarpool.app;", out)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = org.schoolcarpool.app.RunnerTests;", out)
        self.assertIn(f"IPHONEOS_DEPLOYMENT_TARGET = {patch_native.MIN_IOS};", out)
        self.assertIn('TARGETED_DEVICE_FAMILY = "1";', out)
        self.assertNotIn("1,2", out)
        # Idempotent.
        again = "".join(patch_native.pbx_line(line, "org.schoolcarpool.app") for line in out.splitlines(keepends=True))
        self.assertEqual(out, again)


class ReviewInfoTest(unittest.TestCase):
    def test_prod_and_staging_have_no_developer_settings(self):
        info = dict(TEMPLATE_INFO, **patch_native.PERMISSION_TEXTS)
        info["NSAppTransportSecurity"] = {"NSAllowsLocalNetworking": True, "NSAllowsArbitraryLoads": True}
        for flavor in ("prod", "staging"):
            out = patch_native.review_info(info, flavor)
            self.assertNotIn("NSLocalNetworkUsageDescription", out)
            self.assertNotIn("NSAppTransportSecurity", out)
            self.assertEqual(out["UISupportedInterfaceOrientations"], ["UIInterfaceOrientationPortrait"])
            self.assertNotIn("UISupportedInterfaceOrientations~ipad", out)
            for key in PURPOSE_KEYS:
                self.assertIn(key, out)

    def test_dev_keeps_the_emulator_access_but_no_arbitrary_loads(self):
        info = dict(TEMPLATE_INFO, **patch_native.PERMISSION_TEXTS)
        info["NSAppTransportSecurity"] = {"NSAllowsArbitraryLoads": True}
        out = patch_native.review_info(info, "dev")
        self.assertEqual(out["NSAppTransportSecurity"], {"NSAllowsLocalNetworking": True})
        self.assertIn("NSLocalNetworkUsageDescription", out)

    def test_idempotent(self):
        once = patch_native.review_info(TEMPLATE_INFO, "prod")
        self.assertEqual(patch_native.review_info(once, "prod"), once)


class PurposeStringsTest(unittest.TestCase):
    """Guideline 5.1.1: every purpose string exists, is specific, in Arabic and English."""

    def strings(self, lang):
        text = (TOOL_IOS / f"{lang}.lproj" / "InfoPlist.strings").read_text(encoding="utf-8")
        return dict(line.strip().rstrip(";").split('" = "', 1) for line in text.splitlines() if line.startswith('"')), text

    def test_every_key_in_both_languages(self):
        for lang in ("ar", "en"):
            pairs, _ = self.strings(lang)
            keys = {k.strip('"') for k in pairs}
            for key in PURPOSE_KEYS:
                self.assertIn(key, keys, f"{lang}: {key}")
                value = pairs[f'"{key}'] if f'"{key}' in pairs else pairs[key]
                self.assertGreater(len(value), 30, f"{lang}: {key} is too short to be specific")

    def test_no_permission_we_do_not_use(self):
        for key in ("NSContactsUsageDescription", "NSMicrophoneUsageDescription", "NSUserTrackingUsageDescription",
                    "NSMotionUsageDescription", "NSBluetoothAlwaysUsageDescription", "NSCalendarsUsageDescription"):
            self.assertNotIn(key, patch_native.PERMISSION_TEXTS)
            for lang in ("ar", "en"):
                self.assertNotIn(key, self.strings(lang)[1])

    def test_developer_text_removed_outside_dev(self):
        for lang in ("ar", "en"):
            _, text = self.strings(lang)
            self.assertIn("NSLocalNetworkUsageDescription", text)
            self.assertEqual(patch_native.localized_strings(text, "dev"), text)
            for flavor in ("staging", "prod"):
                out = patch_native.localized_strings(text, flavor)
                self.assertNotIn("NSLocalNetworkUsageDescription", out)
                for key in PURPOSE_KEYS:
                    self.assertIn(key, out)

    def test_base_texts_match_the_english_file(self):
        pairs, _ = self.strings("en")
        for key in PURPOSE_KEYS:
            self.assertEqual(pairs[f'"{key}'].rstrip('"'), patch_native.PERMISSION_TEXTS[key])


class IconTest(unittest.TestCase):
    def png(self, width, height, color_type):
        ihdr = width.to_bytes(4, "big") + height.to_bytes(4, "big") + bytes([8, color_type, 0, 0, 0])
        return b"\x89PNG\r\n\x1a\n" + (13).to_bytes(4, "big") + b"IHDR" + ihdr + b"\x00" * 4

    def test_committed_icon_is_accepted(self):
        self.assertIsNone(patch_native.icon_problem((TOOL_IOS / "AppIcon" / "icon_1024.png").read_bytes()))

    def test_bad_icons_are_refused(self):
        self.assertIsNone(patch_native.icon_problem(self.png(1024, 1024, 2)))
        self.assertIn("1024", patch_native.icon_problem(self.png(512, 512, 2)))
        self.assertIn("transparency", patch_native.icon_problem(self.png(1024, 1024, 6)))
        self.assertIn("not a PNG", patch_native.icon_problem(b"GIF89a" + b"\x00" * 40))

    def test_icon_replaces_the_placeholder_set(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            icon_set = root / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
            icon_set.mkdir(parents=True)
            (icon_set / "Icon-App-60x60@2x.png").write_bytes(b"flutter placeholder")
            (icon_set / "Contents.json").write_text("{}", encoding="utf-8")
            with mock.patch.object(patch_native, "ROOT", root):
                patch_native.patch_app_icon()
                patch_native.patch_app_icon()
            self.assertEqual(sorted(p.name for p in icon_set.iterdir()), ["Contents.json", "icon_1024.png"])
            self.assertIn('"icon_1024.png"', (icon_set / "Contents.json").read_text(encoding="utf-8"))


class PrivacyManifestTest(unittest.TestCase):
    """Privacy manifest: required-reason APIs, no tracking, data types as in docs/app-store-privacy.md."""

    def manifest(self, path):
        with path.open("rb") as f:
            return plistlib.load(f)

    def test_app_manifest(self):
        m = self.manifest(TOOL_IOS / "PrivacyInfo.xcprivacy")
        self.assertIs(m["NSPrivacyTracking"], False)
        self.assertEqual(m["NSPrivacyTrackingDomains"], [])
        apis = {a["NSPrivacyAccessedAPIType"]: a["NSPrivacyAccessedAPITypeReasons"] for a in m["NSPrivacyAccessedAPITypes"]}
        self.assertEqual(apis, {
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
            "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"],
        })
        types = {}
        for d in m["NSPrivacyCollectedDataTypes"]:
            self.assertIs(d["NSPrivacyCollectedDataTypeTracking"], False)
            self.assertTrue(d["NSPrivacyCollectedDataTypePurposes"])
            types[d["NSPrivacyCollectedDataType"].replace("NSPrivacyCollectedDataType", "")] = d["NSPrivacyCollectedDataTypeLinked"]
        # Same rows as docs/app-store-privacy.md section 2 (linked or not).
        self.assertEqual(types, {
            "Name": True, "EmailAddress": True, "PhoneNumber": True, "PhysicalAddress": True,
            "OtherFinancialInfo": True, "PreciseLocation": True, "CoarseLocation": False, "SensitiveInfo": True,
            "PhotosorVideos": True, "OtherUserContent": True, "CustomerSupport": True, "SearchHistory": False,
            "UserID": True, "DeviceID": True, "ProductInteraction": False, "CrashData": True,
            "OtherDiagnosticData": True, "OtherDataTypes": True,
        })
        for never in ("Contacts", "Health", "Fitness", "BrowsingHistory", "AdvertisingData", "PurchaseHistory"):
            self.assertNotIn(never, types)

    def test_plugin_manifest_and_podspec(self):
        plugin = TOOL_IOS.parent.parent / "packages" / "run_recovery" / "ios"
        m = self.manifest(plugin / "Resources" / "PrivacyInfo.xcprivacy")
        self.assertIs(m["NSPrivacyTracking"], False)
        self.assertEqual(m["NSPrivacyAccessedAPITypes"][0]["NSPrivacyAccessedAPITypeReasons"], ["CA92.1"])
        self.assertIn("Resources/PrivacyInfo.xcprivacy", (plugin / "run_recovery.podspec").read_text(encoding="utf-8"))

    def test_manifest_is_copied_into_the_runner(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "ios" / "Runner").mkdir(parents=True)
            with mock.patch.object(patch_native, "ROOT", root):
                patch_native.patch_privacy_manifest()
            self.assertEqual(
                (root / "ios" / "Runner" / "PrivacyInfo.xcprivacy").read_bytes(),
                (TOOL_IOS / "PrivacyInfo.xcprivacy").read_bytes(),
            )


class FullIosPatchTest(unittest.TestCase):
    """patch_ios end to end on a small copy of the generated project."""

    def project(self, tmp):
        root = Path(tmp)
        runner = root / "ios" / "Runner"
        (root / "ios" / "Runner.xcodeproj").mkdir(parents=True)
        runner.mkdir()
        (root / "ios" / "Runner.xcodeproj" / "project.pbxproj").write_text(PBX, encoding="utf-8")
        with (runner / "Info.plist").open("wb") as f:
            plistlib.dump(TEMPLATE_INFO, f)
        return root, runner

    def run_patch(self, root, bundle_id, name, flavor):
        with mock.patch.object(patch_native, "ROOT", root), mock.patch.dict("os.environ", {}, clear=False):
            patch_native.patch_ios(bundle_id, name, flavor)

    def test_prod(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, runner = self.project(tmp)
            self.run_patch(root, "org.schoolcarpool.app", "School Carpool", "prod")
            with (runner / "Info.plist").open("rb") as f:
                info = plistlib.load(f)
            self.assertEqual(info["CFBundleDisplayName"], "School Carpool")
            self.assertIs(info["ITSAppUsesNonExemptEncryption"], False)
            self.assertEqual(sorted(info["UIBackgroundModes"]), ["location", "remote-notification"])
            self.assertNotIn("NSLocalNetworkUsageDescription", info)
            self.assertNotIn("NSAppTransportSecurity", info)
            self.assertNotIn("NSUserTrackingUsageDescription", info)
            self.assertIs(info["GOOGLE_ANALYTICS_ADID_COLLECTION_ENABLED"], False)
            for lang, name in (("en", "School Carpool"), ("ar", "مشوار المدرسة")):
                text = (runner / f"{lang}.lproj" / "InfoPlist.strings").read_text(encoding="utf-8")
                self.assertIn(f'"CFBundleDisplayName" = "{name}";', text)
                self.assertNotIn("NSLocalNetworkUsageDescription", text)
            self.assertIn('TARGETED_DEVICE_FAMILY = "1";', (root / "ios" / "Runner.xcodeproj" / "project.pbxproj").read_text())

    def test_prod_refuses_a_staging_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, _ = self.project(tmp)
            with self.assertRaises(SystemExit):
                self.run_patch(root, "org.schoolcarpool.app", "School Carpool Stg", "prod")

    def test_dev_keeps_local_network(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, runner = self.project(tmp)
            self.run_patch(root, "org.schoolcarpool.app.dev", "School Carpool Dev", None)
            with (runner / "Info.plist").open("rb") as f:
                info = plistlib.load(f)
            self.assertIn("NSLocalNetworkUsageDescription", info)
            self.assertEqual(info["NSAppTransportSecurity"], {"NSAllowsLocalNetworking": True})


if __name__ == "__main__":
    unittest.main()
