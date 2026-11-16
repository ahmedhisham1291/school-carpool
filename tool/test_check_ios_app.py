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


def scene_manifest(delegate="Runner.SceneDelegate"):
    return {
        "UIApplicationSupportsMultipleScenes": False,
        "UISceneConfigurations": {
            "UIWindowSceneSessionRoleApplication": [
                {
                    "UISceneClassName": "UIWindowScene",
                    "UISceneDelegateClassName": delegate,
                    "UISceneConfigurationName": "flutter",
                    "UISceneStoryboardFile": "Main",
                }
            ]
        },
    }


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
        "UIApplicationSceneManifest": scene_manifest(),
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
            "UIScene": lambda i: i.pop("UIApplicationSceneManifest"),
            "app icon": lambda i: i.pop("CFBundleIcons"),
        }
        for expected, change in cases.items():
            info = good_info()
            change(info)
            self.assertIn(expected, " ".join(self.problems(info)), expected)

    def test_scene_app_on_sdk_27_is_fine(self):
        info = good_info()
        info.update(DTSDKName="iphoneos27.0")
        self.assertEqual(self.problems(info), [])
        info.update(UIApplicationSceneManifest=scene_manifest("FlutterSceneDelegate"))
        self.assertEqual(self.problems(info), [])

    def test_scene_manifest_must_name_a_flutter_scene_delegate(self):
        for bad in ({}, scene_manifest(""), scene_manifest("$(PRODUCT_MODULE_NAME).SceneDelegate"), scene_manifest("MyDelegate")):
            info = good_info()
            info.update(UIApplicationSceneManifest=bad)
            self.assertIn("UIScene", " ".join(self.problems(info)), bad)

    def test_what_patch_native_writes_passes(self):
        info = good_info()
        info["UIApplicationSceneManifest"] = patch_native.scene_manifest(patch_native.SCENE_DELEGATE_CLASS)
        self.assertEqual(self.problems(info), [])

    def test_missing_privacy_manifest(self):
        self.assertIn("PrivacyInfo.xcprivacy", " ".join(self.problems(good_info(), manifest=False)))

    def app_with_frameworks(self, tmp, with_manifest, without_manifest):
        app = self.app(tmp, good_info())
        for name in with_manifest:
            fw = app / "Frameworks" / f"{name}.framework"
            fw.mkdir(parents=True)
            bundle = fw / f"{name}_privacy.bundle"
            bundle.mkdir()
            (bundle / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps({"NSPrivacyTracking": False}))
        for name in without_manifest:
            (app / "Frameworks" / f"{name}.framework").mkdir(parents=True)
        return app

    def test_listed_sdk_without_manifest_fails_prod_and_warns_on_staging(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = self.app_with_frameworks(tmp, ["Flutter", "url_launcher_ios"], ["FirebaseCore", "absl"])
            problems, warnings = check_ios_app.check(app, "prod")
            text = " ".join(problems)
            self.assertIn("FirebaseCore", text)
            self.assertIn("Abseil (absl.framework)", text)
            self.assertNotIn("url_launcher_ios", text)
            self.assertNotIn("Flutter (", text)
            self.assertEqual(warnings, [])
            self.assertEqual(check_ios_app.main([str(app), "--flavor", "prod"]), 1)
            problems, warnings = check_ios_app.check(app, "staging")
            self.assertEqual(problems, [])
            self.assertEqual(len(warnings), 2)
            self.assertEqual(check_ios_app.main([str(app), "--flavor", "staging"]), 0)

    def test_manifest_in_a_bundle_at_the_app_root_counts(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = self.app_with_frameworks(tmp, [], ["GoogleUtilities"])
            bundle = app / "GoogleUtilities_Privacy.bundle"
            bundle.mkdir()
            (bundle / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps({"NSPrivacyTracking": False}))
            self.assertEqual(check_ios_app.check(app, "prod")[0], [])

    def test_repackaged_plugins_count_as_listed(self):
        # path_provider_foundation repackages path_provider; shared_preferences_foundation the _ios one.
        with tempfile.TemporaryDirectory() as tmp:
            app = self.app_with_frameworks(tmp, [], ["path_provider_foundation", "shared_preferences_foundation"])
            text = " ".join(check_ios_app.check(app, "prod")[0])
            self.assertIn("path_provider_foundation", text)
            self.assertIn("shared_preferences_foundation", text)

    def test_apple_list_is_complete_and_covers_what_we_link(self):
        self.assertEqual(len(check_ios_app.APPLE_LISTED_SDKS), 86)
        for sdk in check_ios_app.EXPECTED_LISTED_SDKS:
            self.assertIn(sdk, check_ios_app.APPLE_LISTED_SDKS)

    def test_unlisted_framework_without_manifest_is_fine(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = self.app_with_frameworks(tmp, [], ["FirebaseAppCheck", "Sentry"])
            self.assertEqual(check_ios_app.check(app, "prod"), ([], []))

    def test_tracking_sdk_is_a_problem(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = self.app(tmp, good_info())
            bundle = app / "SomeAds.bundle"
            bundle.mkdir()
            (bundle / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps({"NSPrivacyTracking": True}))
            self.assertIn("SomeAds.bundle", " ".join(check_ios_app.check(app, "prod")[0]))

    def test_main_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = self.app(tmp, good_info())
            self.assertEqual(check_ios_app.main([str(app), "--flavor", "prod"]), 0)
            (app / "PrivacyInfo.xcprivacy").unlink()
            self.assertEqual(check_ios_app.main([str(app), "--flavor", "prod"]), 1)


if __name__ == "__main__":
    unittest.main()
