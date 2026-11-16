"""Tests for tool/check_ios_app.py (App Review audit).

    python3 -m unittest discover -s tool -p 'test_*.py' -v
"""

import plistlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_ios_app  # noqa: E402
import patch_native  # noqa: E402

TOOL_IOS = Path(__file__).resolve().parent / "ios"


def good_info(name="School Carpool", bundle="org.schoolcarpool.app"):
    info = {
        "CFBundleDisplayName": name,
        "CFBundleIdentifier": bundle,
        "UIBackgroundModes": ["remote-notification", "location"],
        "ITSAppUsesNonExemptEncryption": False,
        "UIDeviceFamily": [1],
        "GOOGLE_ANALYTICS_ADID_COLLECTION_ENABLED": False,
        "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}},
        "DTSDKName": "iphoneos26.4",
    }
    info.update({k: v for k, v in patch_native.PERMISSION_TEXTS.items() if k != "NSLocalNetworkUsageDescription"})
    return info


class CheckIosAppTest(unittest.TestCase):
    def app(self, tmp, info, manifest=True):
        app = Path(tmp) / "Runner.app"
        app.mkdir()
        with (app / "Info.plist").open("wb") as f:
            plistlib.dump(info, f, fmt=plistlib.FMT_BINARY)
        (app / "Assets.car").write_bytes(b"car")
        for lang in ("ar", "en"):
            (app / f"{lang}.lproj").mkdir()
            shutil.copyfile(TOOL_IOS / f"{lang}.lproj" / "InfoPlist.strings", app / f"{lang}.lproj" / "InfoPlist.strings")
        if manifest:
            shutil.copyfile(TOOL_IOS / "PrivacyInfo.xcprivacy", app / "PrivacyInfo.xcprivacy")
        return app

    def problems(self, info, flavor="prod", **kwargs):
        with tempfile.TemporaryDirectory() as tmp:
            return check_ios_app.check(self.app(tmp, info, **kwargs), flavor)[0]

    def test_good_prod_app_passes(self):
        self.assertEqual(self.problems(good_info()), [])

    def test_staging_name_fails_only_in_prod(self):
        info = good_info("School Carpool Stg", "org.schoolcarpool.app.stg")
        self.assertEqual(self.problems(info, "staging"), [])
        text = " ".join(self.problems(info, "prod"))
        self.assertIn("store name", text)
        self.assertIn("staging or dev id", text)

    def test_each_rejection_cause_is_reported(self):
        cases = {
            "NSCameraUsageDescription": lambda i: i.pop("NSCameraUsageDescription"),
            "NSUserTrackingUsageDescription": lambda i: i.update(NSUserTrackingUsageDescription="x"),
            "NSLocalNetworkUsageDescription": lambda i: i.update(NSLocalNetworkUsageDescription="dev"),
            "NSAppTransportSecurity": lambda i: i.update(NSAppTransportSecurity={"NSAllowsArbitraryLoads": True}),
            "UIBackgroundModes": lambda i: i.update(UIBackgroundModes=["location", "fetch", "remote-notification"]),
            "ITSAppUsesNonExemptEncryption": lambda i: i.pop("ITSAppUsesNonExemptEncryption"),
            "UIDeviceFamily": lambda i: i.update(UIDeviceFamily=[1, 2]),
            "ADID": lambda i: i.pop("GOOGLE_ANALYTICS_ADID_COLLECTION_ENABLED"),
            "UIScene": lambda i: i.update(DTSDKName="iphoneos27.0"),
            "app icon": lambda i: i.pop("CFBundleIcons"),
        }
        for expected, change in cases.items():
            info = good_info()
            change(info)
            self.assertIn(expected, " ".join(self.problems(info)), expected)

    def test_scene_app_on_sdk_27_is_fine(self):
        info = good_info()
        info.update(DTSDKName="iphoneos27.0", UIApplicationSceneManifest={})
        self.assertEqual(self.problems(info), [])

    def test_missing_privacy_manifest(self):
        self.assertIn("PrivacyInfo.xcprivacy", " ".join(self.problems(good_info(), manifest=False)))

    def test_sdk_without_manifest_is_a_warning_and_tracking_a_problem(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = self.app(tmp, good_info())
            (app / "Frameworks" / "FirebaseCore.framework").mkdir(parents=True)
            ok = app / "Frameworks" / "Flutter.framework"
            ok.mkdir()
            (ok / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps({"NSPrivacyTracking": False}))
            bundle = app / "SomeAds.bundle"
            bundle.mkdir()
            (bundle / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps({"NSPrivacyTracking": True}))
            problems, warnings = check_ios_app.check(app, "prod")
            self.assertEqual(len(warnings), 1)
            self.assertIn("FirebaseCore", warnings[0])
            self.assertIn("SomeAds.bundle", " ".join(problems))

    def test_main_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = self.app(tmp, good_info())
            self.assertEqual(check_ios_app.main([str(app), "--flavor", "prod"]), 0)
            (app / "PrivacyInfo.xcprivacy").unlink()
            self.assertEqual(check_ios_app.main([str(app), "--flavor", "prod"]), 1)


if __name__ == "__main__":
    unittest.main()
