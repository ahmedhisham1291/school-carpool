#!/usr/bin/env python3
"""Applies our settings to the native folders that `flutter create` generates.

Called by tool/bootstrap.sh. Idempotent: safe to run on every build. Uses only
the Python standard library so it runs on Codemagic macOS and Linux machines
and on the owner's Mac.

What it changes
  iOS      bundle id, minimum iOS 15.0, Info.plist (display name, languages,
           permission texts, export compliance, local network for the
           emulators, push background mode), entitlements file, localized
           InfoPlist.strings copied next to Info.plist.
  Android  applicationId and minSdk 26 (Android 8; Sentry 10 needs 26).
"""

from __future__ import annotations

import argparse
import plistlib
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IOS_OVERRIDES = ROOT / "tool" / "ios"

MIN_IOS = "15.0"
MIN_ANDROID_SDK = 26

# English base texts. Arabic and English localized copies live in
# tool/ios/<lang>.lproj/InfoPlist.strings. PLACEHOLDERS: final wording comes
# with Prompt 13 (permission texts) and the lawyer's review.
PERMISSION_TEXTS = {
    "NSCameraUsageDescription":
        "The camera is used to photograph your ID and take a live selfie for verification.",
    "NSLocationWhenInUseUsageDescription":
        "Your location sets your home on the map and shows your car to parents during a run.",
    "NSLocationAlwaysAndWhenInUseUsageDescription":
        "While you drive a run, your location keeps updating for the parents of the children "
        "in your car, even when the phone is locked. It stops when the run ends.",
    "NSFaceIDUsageDescription":
        "Face ID locks the app and confirms every wallet transfer.",
    "NSLocalNetworkUsageDescription":
        "Developer builds connect to test servers on your local network.",
}


def log(message: str) -> None:
    print(f"patch_native: {message}")


def patch_text(path: Path, transform) -> None:
    original = path.read_text(encoding="utf-8")
    updated = transform(original)
    if updated != original:
        path.write_text(updated, encoding="utf-8")
        log(f"updated {path.relative_to(ROOT)}")


# --------------------------------------------------------------------------
# iOS
# --------------------------------------------------------------------------

def patch_ios(bundle_id: str, display_name: str) -> None:
    ios = ROOT / "ios"
    if not ios.is_dir():
        log("ios/ not found, skipping iOS")
        return

    pbxproj = ios / "Runner.xcodeproj" / "project.pbxproj"

    def pbx(text: str) -> str:
        lines = []
        for line in text.splitlines(keepends=True):
            if "PRODUCT_BUNDLE_IDENTIFIER" in line:
                if "RunnerTests" in line:
                    line = re.sub(r"PRODUCT_BUNDLE_IDENTIFIER = [^;]+;",
                                  f"PRODUCT_BUNDLE_IDENTIFIER = {bundle_id}.RunnerTests;", line)
                else:
                    line = re.sub(r"PRODUCT_BUNDLE_IDENTIFIER = [^;]+;",
                                  f"PRODUCT_BUNDLE_IDENTIFIER = {bundle_id};", line)
            line = re.sub(r"IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;",
                          f"IPHONEOS_DEPLOYMENT_TARGET = {MIN_IOS};", line)
            lines.append(line)
        return "".join(lines)

    patch_text(pbxproj, pbx)

    podfile = ios / "Podfile"
    if podfile.exists():
        patch_text(podfile, lambda t: re.sub(r"^#?\s*platform :ios, '[0-9.]+'",
                                             f"platform :ios, '{MIN_IOS}'", t, flags=re.M))

    info_path = ios / "Runner" / "Info.plist"
    with info_path.open("rb") as f:
        info = plistlib.load(f)
    before = dict(info)

    info["CFBundleDisplayName"] = display_name
    info["CFBundleLocalizations"] = ["ar", "en"]
    info["CFBundleDevelopmentRegion"] = "ar"
    # Only standard HTTPS/TLS: exempt from export documentation.
    info["ITSAppUsesNonExemptEncryption"] = False
    info.update(PERMISSION_TEXTS)
    ats = dict(info.get("NSAppTransportSecurity", {}))
    ats["NSAllowsLocalNetworking"] = True  # dev builds talk to the emulators
    info["NSAppTransportSecurity"] = ats
    modes = list(info.get("UIBackgroundModes", []))
    if "remote-notification" not in modes:
        modes.append("remote-notification")  # Firebase Cloud Messaging
    info["UIBackgroundModes"] = modes

    if info != before:
        with info_path.open("wb") as f:
            plistlib.dump(info, f, sort_keys=False)
        log("updated ios/Runner/Info.plist")

    # Entitlements: push notifications and App Attest.
    shutil.copyfile(IOS_OVERRIDES / "Runner.entitlements", ios / "Runner" / "Runner.entitlements")

    # Localized permission texts and display name.
    for lang in ("ar", "en"):
        target = ios / "Runner" / f"{lang}.lproj"
        target.mkdir(exist_ok=True)
        shutil.copyfile(IOS_OVERRIDES / f"{lang}.lproj" / "InfoPlist.strings", target / "InfoPlist.strings")
        strings = target / "InfoPlist.strings"
        patch_text(strings, lambda t: re.sub(r'"CFBundleDisplayName" = "[^"]*";',
                                             f'"CFBundleDisplayName" = "{display_name_for(lang, display_name)}";', t))


def display_name_for(lang: str, english_name: str) -> str:
    """Arabic display name keeps the flavor suffix of the English one."""
    if lang == "en":
        return english_name
    suffix = english_name.replace("School Carpool", "").strip()
    return f"مشوار المدرسة {suffix}".strip()


# --------------------------------------------------------------------------
# Android
# --------------------------------------------------------------------------

def patch_android(application_id: str) -> None:
    gradle = ROOT / "android" / "app" / "build.gradle.kts"
    if not gradle.exists():
        log("android/app/build.gradle.kts not found, skipping Android")
        return

    def kts(text: str) -> str:
        text = re.sub(r'applicationId = "[^"]+"', f'applicationId = "{application_id}"', text)
        text = re.sub(r"minSdk = [^\n]+", f"minSdk = {MIN_ANDROID_SDK}", text)
        return text

    patch_text(gradle, kts)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ios-bundle-id", required=True)
    parser.add_argument("--android-app-id", required=True)
    parser.add_argument("--display-name", required=True)
    args = parser.parse_args()

    patch_ios(args.ios_bundle_id, args.display_name)
    patch_android(args.android_app_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
