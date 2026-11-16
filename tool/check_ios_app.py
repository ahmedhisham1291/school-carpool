#!/usr/bin/env python3
"""Checks a built iPhone app (Runner.app) for what App Review and App Store
Connect refuse (docs/apple-review/audit.md). Run after `flutter build ipa`:

    python3 tool/check_ios_app.py build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app --flavor prod

Exit code 1 with one line per problem; warnings do not fail the build.
Standard library only.
"""

from __future__ import annotations

import argparse
import plistlib
import re
import sys
from pathlib import Path

PURPOSE_KEYS = (
    "NSCameraUsageDescription",
    "NSPhotoLibraryUsageDescription",
    "NSLocationWhenInUseUsageDescription",
    "NSFaceIDUsageDescription",
)
# Permissions the app never asks for: a key here means a plugin or a
# template added something we would have to justify to App Review.
UNUSED_KEYS = (
    "NSUserTrackingUsageDescription",
    # "Always" location is never asked (16 Nov 2026, guideline 5.1.1).
    "NSLocationAlwaysAndWhenInUseUsageDescription",
    "NSLocationAlwaysUsageDescription",
    "NSContactsUsageDescription",
    "NSMicrophoneUsageDescription",
    "NSMotionUsageDescription",
    "NSBluetoothAlwaysUsageDescription",
    "NSCalendarsUsageDescription",
    "NSHealthShareUsageDescription",
)
BACKGROUND_MODES = {"location", "remote-notification"}
NOT_IN_STORE_NAME = ("stg", "dev", "test", "beta", "staging")
REQUIRED_API_TYPES = {
    "NSPrivacyAccessedAPICategoryUserDefaults",
    "NSPrivacyAccessedAPICategoryFileTimestamp",
    "NSPrivacyAccessedAPICategorySystemBootTime",
    "NSPrivacyAccessedAPICategoryDiskSpace",
}
# Frameworks on Apple's "commonly used SDKs" list that this app links
# (https://developer.apple.com/support/third-party-SDK-requirements):
# each must carry its own privacy manifest.
LISTED_SDKS = (
    "Flutter", "FirebaseCore", "FirebaseAuth", "FirebaseFirestore", "FirebaseMessaging", "FirebaseInstallations",
    "FirebaseCoreInternal", "FirebaseCoreExtension", "GoogleUtilities", "GoogleDataTransport", "nanopb", "FBLPromises",
    "GTMSessionFetcher", "abseil", "grpcpp", "BoringSSL-GRPC", "leveldb", "geolocator_apple", "image_picker_ios",
    "path_provider_foundation", "shared_preferences_foundation", "url_launcher_ios", "flutter_local_notifications",
    "connectivity_plus", "device_info_plus", "package_info_plus",
)


def load(path: Path) -> dict:
    with path.open("rb") as f:
        return plistlib.load(f)


def scene_life_cycle_problem(info: dict) -> str | None:
    """None when the scene manifest names Flutter's scene delegate (or the app's subclass)."""
    sdk = str(info.get("DTSDKName", "")) or "an unknown SDK"
    manifest = info.get("UIApplicationSceneManifest")
    if not isinstance(manifest, dict):
        return f"no UIScene life cycle (UIApplicationSceneManifest missing, built with {sdk}): run tool/patch_native.py"
    try:
        delegate = manifest["UISceneConfigurations"]["UIWindowSceneSessionRoleApplication"][0]["UISceneDelegateClassName"]
    except (KeyError, IndexError, TypeError):
        delegate = ""
    if delegate != "FlutterSceneDelegate" and not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*\.SceneDelegate", str(delegate)):
        return f"UIScene manifest names {delegate!r}, not FlutterSceneDelegate or <module>.SceneDelegate"
    return None


def check(app: Path, flavor: str) -> tuple[list[str], list[str]]:
    problems: list[str] = []
    warnings: list[str] = []
    info_path = app / "Info.plist"
    if not info_path.is_file():
        return [f"{app}: no Info.plist (not an app bundle)"], warnings
    info = load(info_path)

    name = str(info.get("CFBundleDisplayName", ""))
    if flavor == "prod":
        bad = [w for w in re.findall(r"[a-z]+", name.lower()) if w in NOT_IN_STORE_NAME]
        if bad or not name:
            problems.append(f"display name {name!r} is not a store name (guideline 2.3)")
        if str(info.get("CFBundleIdentifier", "")).endswith((".stg", ".dev")):
            problems.append("bundle id is a staging or dev id")
    for key in PURPOSE_KEYS:
        if len(str(info.get(key, ""))) < 30:
            problems.append(f"{key} is missing or too short (guideline 5.1.1)")
    for key in UNUSED_KEYS:
        if key in info:
            problems.append(f"{key} is set but the app does not use that permission")
    if flavor != "dev":
        if "NSLocalNetworkUsageDescription" in info:
            problems.append("NSLocalNetworkUsageDescription (developer text) is in a store build")
        if info.get("NSAppTransportSecurity"):
            problems.append("NSAppTransportSecurity has exceptions (HTTPS only, guideline 2.5)")
    modes = set(info.get("UIBackgroundModes", []))
    if modes != BACKGROUND_MODES:
        problems.append(f"UIBackgroundModes is {sorted(modes)}, expected {sorted(BACKGROUND_MODES)} (guideline 2.5.4)")
    if info.get("ITSAppUsesNonExemptEncryption") is not False:
        problems.append("ITSAppUsesNonExemptEncryption must be false (export compliance)")
    if list(info.get("UIDeviceFamily", [])) != [1]:
        problems.append(f"UIDeviceFamily is {info.get('UIDeviceFamily')}, expected [1] (iPhone only)")
    if info.get("GOOGLE_ANALYTICS_ADID_COLLECTION_ENABLED") is not False:
        problems.append("GOOGLE_ANALYTICS_ADID_COLLECTION_ENABLED must be false (no IDFA, no tracking prompt)")
    # UIScene life cycle (16 Nov 2026, tool/patch_native.py): required by
    # the iOS 27 SDK (an app without it does not launch: guideline 2.1(a)),
    # and what we ship on every SDK.
    scene_problem = scene_life_cycle_problem(info)
    if scene_problem:
        problems.append(scene_problem)
    if not (info.get("CFBundleIcons") or info.get("CFBundleIconFiles")) or not (app / "Assets.car").is_file():
        problems.append("no app icon in the bundle")
    for lang in ("ar", "en"):
        if not (app / f"{lang}.lproj" / "InfoPlist.strings").is_file():
            problems.append(f"{lang}.lproj/InfoPlist.strings is missing (localized permission texts)")

    manifest_path = app / "PrivacyInfo.xcprivacy"
    if not manifest_path.is_file():
        problems.append("PrivacyInfo.xcprivacy is not in the app bundle (privacy manifest)")
    else:
        manifest = load(manifest_path)
        if manifest.get("NSPrivacyTracking") is not False or manifest.get("NSPrivacyTrackingDomains"):
            problems.append("the privacy manifest declares tracking")
        declared = {a.get("NSPrivacyAccessedAPIType") for a in manifest.get("NSPrivacyAccessedAPITypes", [])}
        for missing in sorted(REQUIRED_API_TYPES - declared):
            problems.append(f"the privacy manifest does not declare {missing}")

    frameworks = app / "Frameworks"
    if frameworks.is_dir():
        present = {p.name[: -len(".framework")]: p for p in frameworks.glob("*.framework")}
        for sdk in LISTED_SDKS:
            path = present.get(sdk)
            if path is not None and not list(path.rglob("PrivacyInfo.xcprivacy")):
                warnings.append(f"{sdk}.framework has no privacy manifest inside it (check its resource bundle in the app, or update the package)")
    for bundle in app.glob("*.bundle"):
        inner = bundle / "PrivacyInfo.xcprivacy"
        if inner.is_file() and load(inner).get("NSPrivacyTracking") is True:
            problems.append(f"{bundle.name} declares tracking (an SDK tracks: App Tracking Transparency would be required)")
    return problems, warnings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--flavor", choices=("dev", "staging", "prod"), required=True)
    args = parser.parse_args(argv)
    problems, warnings = check(args.app, args.flavor)
    for w in warnings:
        print(f"check_ios_app: WARNING {w}")
    for p in problems:
        print(f"check_ios_app: PROBLEM {p}")
    if problems:
        return 1
    print(f"check_ios_app: {args.app.name} ({args.flavor}) passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
