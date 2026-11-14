"""Tests for the iOS launch patch in tool/patch_native.py (Prompt 13 review).

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

# What `flutter create` generated before (already classic).
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

    def test_scene_template_becomes_classic(self):
        with tempfile.TemporaryDirectory() as tmp:
            info = {"UIApplicationSceneManifest": SCENE_MANIFEST, "UILaunchStoryboardName": "LaunchScreen", "UIMainStoryboardFile": "Main"}
            root, runner = self.runner(tmp, SCENE_APP_DELEGATE, SCENE_DELEGATE, info)
            self.patch(root)
            delegate = (runner / "AppDelegate.swift").read_text(encoding="utf-8")
            self.assertIn(patch_native.CLASSIC_MARKER, delegate)
            self.assertNotIn("FlutterImplicitEngineDelegate", delegate)
            self.assertIn("flutterEngine.run()", delegate)
            self.assertIn("GeneratedPluginRegistrant.register(with: flutterEngine)", delegate)
            # The engine starts before super, so plugins get the launch options.
            self.assertLess(delegate.index("GeneratedPluginRegistrant"), delegate.index("super.application"))
            scene = (runner / "SceneDelegate.swift").read_text(encoding="utf-8")
            self.assertNotIn("FlutterSceneDelegate", scene)
            patched = self.read_info(runner)
            self.assertNotIn("UIApplicationSceneManifest", patched)
            self.assertNotIn("UIMainStoryboardFile", patched)
            self.assertEqual(patched["UILaunchStoryboardName"], "LaunchScreen")

    def test_idempotent_and_keeps_later_patches(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, runner = self.runner(tmp, SCENE_APP_DELEGATE, SCENE_DELEGATE, {"UIApplicationSceneManifest": SCENE_MANIFEST})
            self.patch(root)
            # The Maps and alerts patches add lines after this one.
            delegate = runner / "AppDelegate.swift"
            with_alerts = delegate.read_text(encoding="utf-8").replace(
                "    // Dart main() starts now", "    // alerts line\n    // Dart main() starts now"
            )
            delegate.write_text(with_alerts, encoding="utf-8")
            info_before = (runner / "Info.plist").read_bytes()
            self.patch(root)
            self.assertEqual(delegate.read_text(encoding="utf-8"), with_alerts)
            self.assertEqual((runner / "Info.plist").read_bytes(), info_before)

    def test_old_classic_template_gets_the_explicit_engine(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, runner = self.runner(tmp, OLD_CLASSIC_DELEGATE, None, {"UIMainStoryboardFile": "Main"})
            self.patch(root)
            delegate = (runner / "AppDelegate.swift").read_text(encoding="utf-8")
            self.assertIn(patch_native.CLASSIC_MARKER, delegate)
            self.assertFalse((runner / "SceneDelegate.swift").exists())
            self.assertNotIn("UIMainStoryboardFile", self.read_info(runner))

    def test_already_patched_is_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, runner = self.runner(
                tmp,
                patch_native.CLASSIC_APP_DELEGATE,
                patch_native.EMPTY_SCENE_DELEGATE,
                {"UILaunchStoryboardName": "LaunchScreen"},
            )
            before = {p.name: p.read_bytes() for p in runner.iterdir()}
            self.patch(root)
            after = {p.name: p.read_bytes() for p in runner.iterdir()}
            self.assertEqual(before, after)

    def test_maps_and_alerts_patches_still_find_did_finish_launching(self):
        import re

        match = re.search(r"didFinishLaunchingWithOptions[^{]*\{\n", patch_native.CLASSIC_APP_DELEGATE)
        self.assertIsNotNone(match)
        self.assertIn("import UIKit\n", patch_native.CLASSIC_APP_DELEGATE)


if __name__ == "__main__":
    unittest.main()
