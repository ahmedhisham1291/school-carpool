"""Tests for tool/ios/configure_xcode.rb (16 Nov 2026): idempotent, never
adds PrivacyInfo.xcprivacy twice, safe with Xcode synchronized folders.

Runs the real Ruby script against a stand-in for the `xcodeproj` gem
(tool/ios/xcodeproj_stub), because the gem is not installed here. CI and
the Mac run the script against the real project.

    python3 -m unittest discover -s tool -p 'test_*.py' -v
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parent
SCRIPT = TOOL / "ios" / "configure_xcode.rb"
STUB = TOOL / "ios" / "xcodeproj_stub"
ENTITLEMENTS = "Runner/Runner.entitlements"


@unittest.skipUnless(shutil.which("ruby"), "ruby is not installed")
class ConfigureXcodeTest(unittest.TestCase):
    def run_script(self, state):
        """Runs the script on [state]; returns (saved state or None, stdout)."""
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "in.json"
            out = Path(tmp) / "out.json"
            src.write_text(json.dumps(state), encoding="utf-8")
            env = dict(os.environ, XCODEPROJ_STUB_IN=str(src), XCODEPROJ_STUB_OUT=str(out))
            result = subprocess.run(
                ["ruby", "-I", str(STUB), str(SCRIPT)], env=env, capture_output=True, text=True, check=False
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            saved = json.loads(out.read_text(encoding="utf-8")) if out.exists() else None
            return saved, result.stdout

    @staticmethod
    def as_input(saved, synchronized=False):
        """The saved project as the next run's input (a second run of the build)."""
        files = [c for c in saved["runnerChildren"] if c != "InfoPlist.strings"]
        return {
            "synchronized": synchronized,
            "entitlements": saved["entitlements"],
            "regions": saved["regions"],
            "runnerFiles": files,
            "variants": ["InfoPlist.strings"] if "InfoPlist.strings" in saved["runnerChildren"] else [],
            "phase": saved["phase"],
            "exceptions": saved["exceptions"],
        }

    def test_classic_project_gets_everything_once(self):
        saved, out = self.run_script({"runnerFiles": ["AppDelegate.swift"], "phase": []})
        self.assertEqual(saved["phase"].count("PrivacyInfo.xcprivacy"), 1)
        self.assertEqual(saved["phase"].count("InfoPlist.strings"), 1)
        self.assertEqual(saved["runnerChildren"].count("PrivacyInfo.xcprivacy"), 1)
        self.assertEqual(set(saved["entitlements"].values()), {ENTITLEMENTS})
        self.assertTrue({"ar", "en", "Base"} <= set(saved["regions"]))
        self.assertIn("configure_xcode: set", out)

    def test_second_run_changes_nothing(self):
        first, _ = self.run_script({"runnerFiles": ["AppDelegate.swift"], "phase": []})
        again, out = self.run_script(self.as_input(first))
        self.assertIsNone(again, "no save when nothing changed")
        self.assertIn("nothing changed", out)

    def test_privacy_manifest_already_in_the_template_is_not_added_again(self):
        saved, _ = self.run_script(
            {"runnerFiles": ["PrivacyInfo.xcprivacy"], "phase": ["PrivacyInfo.xcprivacy"], "variants": ["InfoPlist.strings"]}
        )
        self.assertEqual(saved["phase"].count("PrivacyInfo.xcprivacy"), 1)
        self.assertEqual(saved["runnerChildren"].count("PrivacyInfo.xcprivacy"), 1)
        self.assertEqual(saved["phase"].count("InfoPlist.strings"), 1)

    def test_reference_without_build_phase_entry_is_added_to_the_phase_once(self):
        saved, _ = self.run_script({"runnerFiles": ["PrivacyInfo.xcprivacy"], "phase": []})
        self.assertEqual(saved["phase"].count("PrivacyInfo.xcprivacy"), 1)
        self.assertEqual(saved["runnerChildren"].count("PrivacyInfo.xcprivacy"), 1)

    def test_synchronized_folder_adds_no_file(self):
        saved, out = self.run_script(
            {"synchronized": True, "entitlements": {"Debug": ENTITLEMENTS, "Release": ENTITLEMENTS, "Profile": ENTITLEMENTS},
             "regions": ["en", "Base", "ar"]}
        )
        self.assertIsNone(saved, "the folder already holds the files: nothing to add")
        self.assertIn("nothing changed", out)

    def test_synchronized_folder_puts_excluded_files_back_and_drops_old_duplicates(self):
        saved, _ = self.run_script(
            {
                "synchronized": True,
                "exceptions": [["PrivacyInfo.xcprivacy", "Notes.txt"]],
                # Left by an older run of the script before the folder was synchronized.
                "runnerFiles": ["PrivacyInfo.xcprivacy"],
                "phase": ["PrivacyInfo.xcprivacy"],
            }
        )
        self.assertEqual(saved["exceptions"], [["Notes.txt"]])
        self.assertNotIn("PrivacyInfo.xcprivacy", saved["phase"])
        self.assertNotIn("InfoPlist.strings", saved["phase"])
        self.assertIn("PrivacyInfo.xcprivacy", saved["removed"])
        again, out = self.run_script(self.as_input(saved, synchronized=True))
        self.assertIsNone(again)
        self.assertIn("nothing changed", out)


if __name__ == "__main__":
    unittest.main()
