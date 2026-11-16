"""Tests for the iOS launch patch in tool/patch_native.py (UIScene, 16 Nov 2026).

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

# What `flutter create` generates now (UIScene + implicit engine).
SCENE_APP_DELEGATE = """import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
"""

SCENE_DELEGATE = """import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
}
"""

SCENE_MANIFEST = {
    "UIApplicationSupportsMultipleScenes": False,
    "UISceneConfigurations": {
        "UIWindowSceneSessionRoleApplication": [
            {
                "UISceneClassName": "UIWindowScene",
                "UISceneConfigurationName": "flutter",
                "UISceneDelegateClassName": "$(PRODUCT_MODULE_NAME).SceneDelegate",
                "UISceneStoryboardFile": "Main",
            }
        ]
    },
}

# What `flutter create` generated before UIScene (classic app delegate).
OLD_CLASSIC_DELEGATE = """import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
"""


class IosLaunchPatchTest(unittest.TestCase):
    """UIScene life cycle (16 Nov 2026; Flutter's "UIScene adoption" guide)."""

    def runner(self, tmp, delegate, scene, info):
        root = Path(tmp)
        runner = root / "ios" / "Runner"
        runner.mkdir(parents=True)
        (runner / "AppDelegate.swift").write_text(delegate, encoding="utf-8")
        if scene is not None:
            (runner / "SceneDelegate.swift").write_text(scene, encoding="utf-8")
        with (runner / "Info.plist").open("wb") as f:
            plistlib.dump(info, f)
        return root, runner

    def patch(self, root):
        with mock.patch.object(patch_native, "ROOT", root):
            patch_native.patch_ios_launch()

    def read_info(self, runner):
        with (runner / "Info.plist").open("rb") as f:
            return plistlib.load(f)

    def scene_config(self, info):
        return info["UIApplicationSceneManifest"]["UISceneConfigurations"]["UIWindowSceneSessionRoleApplication"][0]

    def assert_scene_delegate(self, delegate):
        self.assertIn(patch_native.SCENE_MARKER, delegate)
        self.assertIn("FlutterImplicitEngineDelegate", delegate)
        self.assertIn("GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)", delegate)
        # No explicit engine, no window built by hand (crashes with UIScene).
        self.assertNotIn("FlutterEngine(name", delegate)
        self.assertNotIn("rootViewController", delegate)
        self.assertNotIn("UIScreen.main", delegate)
        self.assertNotIn("register(with: self)", delegate)

    def test_scene_template_keeps_the_scene_and_gets_our_delegate(self):
        with tempfile.TemporaryDirectory() as tmp:
            info = {"UIApplicationSceneManifest": SCENE_MANIFEST, "UILaunchStoryboardName": "LaunchScreen", "UIMainStoryboardFile": "Main"}
            root, runner = self.runner(tmp, SCENE_APP_DELEGATE, SCENE_DELEGATE, info)
            self.patch(root)
            self.assert_scene_delegate((runner / "AppDelegate.swift").read_text(encoding="utf-8"))
            # The template's SceneDelegate (a FlutterSceneDelegate) is kept.
            self.assertEqual((runner / "SceneDelegate.swift").read_text(encoding="utf-8"), SCENE_DELEGATE)
            patched = self.read_info(runner)
            self.assertEqual(patched["UIApplicationSceneManifest"], SCENE_MANIFEST)
            self.assertEqual(patched["UIMainStoryboardFile"], "Main")
            self.assertEqual(patched["UILaunchStoryboardName"], "LaunchScreen")

    def test_old_classic_template_is_migrated_to_uiscene(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, runner = self.runner(tmp, OLD_CLASSIC_DELEGATE, None, {"UIMainStoryboardFile": "Main"})
            self.patch(root)
            self.assert_scene_delegate((runner / "AppDelegate.swift").read_text(encoding="utf-8"))
            self.assertFalse((runner / "SceneDelegate.swift").exists())
            config = self.scene_config(self.read_info(runner))
            # No SceneDelegate file: Flutter's own class.
            self.assertEqual(config["UISceneDelegateClassName"], "FlutterSceneDelegate")
            self.assertEqual(config["UISceneClassName"], "UIWindowScene")
            self.assertEqual(config["UISceneConfigurationName"], "flutter")
            self.assertEqual(config["UISceneStoryboardFile"], "Main")
            self.assertIs(self.read_info(runner)["UIApplicationSceneManifest"]["UIApplicationSupportsMultipleScenes"], False)

    def test_a_project_patched_by_the_old_classic_patch_is_migrated(self):
        old_classic = (
            "import Flutter\nimport UIKit\n\n// " + patch_native.CLASSIC_MARKER + " (tool/patch_native.py).\n"
            "@main\n@objc class AppDelegate: FlutterAppDelegate {\n"
            "  private lazy var flutterEngine = FlutterEngine(name: \"school_carpool\")\n}\n"
        )
        emptied = "// " + patch_native.CLASSIC_MARKER + ": not used (no UIScene; tool/patch_native.py).\n"
        with tempfile.TemporaryDirectory() as tmp:
            root, runner = self.runner(tmp, old_classic, emptied, {"UILaunchStoryboardName": "LaunchScreen"})
            self.patch(root)
            self.assert_scene_delegate((runner / "AppDelegate.swift").read_text(encoding="utf-8"))
            self.assertIn("class SceneDelegate: FlutterSceneDelegate", (runner / "SceneDelegate.swift").read_text(encoding="utf-8"))
            info = self.read_info(runner)
            self.assertEqual(self.scene_config(info)["UISceneDelegateClassName"], "$(PRODUCT_MODULE_NAME).SceneDelegate")
            self.assertEqual(info["UIMainStoryboardFile"], "Main")

    def test_manifest_pointing_at_a_missing_scene_delegate_is_fixed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, runner = self.runner(tmp, SCENE_APP_DELEGATE, None, {"UIApplicationSceneManifest": SCENE_MANIFEST})
            self.patch(root)
            self.assertEqual(self.scene_config(self.read_info(runner))["UISceneDelegateClassName"], "FlutterSceneDelegate")

    def test_idempotent_and_keeps_later_patches(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, runner = self.runner(tmp, SCENE_APP_DELEGATE, SCENE_DELEGATE, {"UIApplicationSceneManifest": SCENE_MANIFEST})
            self.patch(root)
            # The Maps and alerts patches add lines after this one.
            delegate = runner / "AppDelegate.swift"
            with_alerts = delegate.read_text(encoding="utf-8").replace(
                "    return super.application", "    // alerts line\n    return super.application"
            )
            delegate.write_text(with_alerts, encoding="utf-8")
            before = {p.name: p.read_bytes() for p in runner.iterdir()}
            self.patch(root)
            self.assertEqual(delegate.read_text(encoding="utf-8"), with_alerts)
            after = {p.name: p.read_bytes() for p in runner.iterdir()}
            self.assertEqual(before, after)

    def test_maps_and_alerts_patches_still_go_into_did_finish_launching(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, runner = self.runner(tmp, SCENE_APP_DELEGATE, SCENE_DELEGATE, {"UIApplicationSceneManifest": SCENE_MANIFEST})
            self.patch(root)
            with mock.patch.object(patch_native, "ROOT", root), mock.patch.dict("os.environ", {"MAPS_API_KEY_IOS": ""}):
                (root / "ios" / "Flutter").mkdir()
                patch_native.patch_maps_ios()
                patch_native.patch_alerts_ios()
            delegate = (runner / "AppDelegate.swift").read_text(encoding="utf-8")
            launch = delegate.index("didFinishLaunchingWithOptions")
            engine = delegate.index("didInitializeImplicitFlutterEngine")
            # Both run before launch ends (the notification delegate must),
            # not in the engine callback.
            for marker in (patch_native.MAPS_MARKER, patch_native.ALERTS_MARKER):
                self.assertTrue(launch < delegate.index(marker) < engine, marker)
            self.assertIn("import UserNotifications", delegate)

if __name__ == "__main__":
    unittest.main()
