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
  Maps     (Prompt 5) Google Maps keys from the environment, never from the
           repository: MAPS_API_KEY_IOS goes to ios/Flutter/Maps.xcconfig
           (Info.plist GMSApiKey = $(MAPS_API_KEY), read by AppDelegate),
           MAPS_API_KEY_ANDROID to the manifest meta-data, and
           MAPS_API_KEY_WEB to a script tag in web/index.html. Location
           permissions for Android. Empty keys are fine: the app then shows
           no Google map (MAPS_ENABLED=false). See SETUP.md section 15.
  Links    (Prompt 6) Universal links for carpool invites: when
           INVITE_LINK_DOMAIN is set (for example
           <project>-links.web.app), the Associated Domains entitlement
           applinks:<domain> is added. Left out when empty, because signing
           fails unless the App ID has the Associated Domains capability
           (SETUP.md section 16). Flutter deep linking is switched on in
           Info.plist so go_router gets the /c/<code> path.
  Alerts   (Prompt 8) flutter_local_notifications: AppDelegate sets the
           notification center delegate (alarms show while the app is
           open); Android gets core library desugaring and the plugin's
           scheduled-notification receivers. When TIME_SENSITIVE_ALERTS=1
           the Time Sensitive Notifications entitlement is added (the App
           ID needs that capability first, SETUP.md section 18.3; without
           it critical alerts still sound but do not break through Focus).
  Wallet   (Prompt 11B) local_auth: Android MainActivity becomes a
           FlutterFragmentActivity (biometric prompt). iPhone uses
           NSFaceIDUsageDescription (Arabic and English texts above and in
           tool/ios/*.lproj).
  Location (Prompt 13) geolocator: background mode `location`, "While
           Using the App" texts; the paid plugin's keys, licence and
           background task are removed (no licence is needed).
  Review   (App Review audit, docs/apple-review/audit.md) iPhone only and
           portrait only; our app icon (tool/ios/AppIcon/icon_1024.png)
           instead of the Flutter placeholder; the app's privacy manifest
           (tool/ios/PrivacyInfo.xcprivacy); no local-network text or
           local networking outside dev; no ATS exceptions; a prod name
           with "Stg", "Dev", "test" or "beta" is refused.
  Launch   (16 Nov 2026, replaces the classic app delegate of the Prompt
           13 review) UIScene life cycle as in Flutter's "UIScene
           adoption" guide: plugins registered in
           didInitializeImplicitFlutterEngine, FlutterSceneDelegate (or the
           template's SceneDelegate subclass) in the Info.plist scene
           manifest. Required for apps built with the iOS 27 SDK; safe now
           because the app no longer relaunches in the background for
           location (no Always). docs/DECISIONS.md.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IOS_OVERRIDES = ROOT / "tool" / "ios"

MIN_IOS = "15.0"
MIN_ANDROID_SDK = 26

# English base texts (Info.plist). Arabic and English localized copies live
# in tool/ios/<lang>.lproj/InfoPlist.strings (Prompt 13 wording; same
# meaning in both). Notifications have no Info.plist text on iOS: the
# app's own screen explains them before the system prompt.
PERMISSION_TEXTS = {
    "NSCameraUsageDescription":
        "The camera takes photos of your ID and a live selfie to verify you, "
        "and photos you choose to send in chats.",
    # Prompt 9 (image_picker): choose a photo to send in a chat.
    "NSPhotoLibraryUsageDescription":
        "Choose a photo to send in a chat. Its location data is removed before it is sent.",
    # "While Using the App" is the only location permission asked.
    "NSLocationWhenInUseUsageDescription":
        "Your location sets your home on the map. When you drive a school run, it shows your car "
        "to the parents of the children in it, also with the phone locked, until the run ends.",
    # 16 Nov 2026 (owner, App Review guideline 5.1.1): the app never asks
    # for "Always", so there is no NSLocationAlwaysAndWhenInUse text; the
    # key is removed from a generated Info.plist (REMOVED_INFO_KEYS) and
    # geolocator is built without its "Always" request (geolocator_bypass).
    "NSFaceIDUsageDescription":
        "Face ID unlocks the app when you turn on App lock, and confirms money transfers.",
    "NSLocalNetworkUsageDescription":
        "Developer builds connect to test servers on your local network.",
}

# Keys and values from the paid location plugin (removed in Prompt 13),
# dropped from an Info.plist generated before.
# Only developer builds talk to the local emulators (App Review: no
# developer wording or local-network access in a staging or prod build).
DEV_ONLY_INFO_KEYS = ("NSLocalNetworkUsageDescription",)

# iPhone only, portrait only (App Review audit, guideline 4.0 / 2.4.1): the
# screens are designed for a phone held upright. Stage 2/3 may widen this.
DEVICE_FAMILY_IPHONE = "1"
ORIENTATIONS = ["UIInterfaceOrientationPortrait"]

FLAVORS = ("dev", "staging", "prod")
# Words that must never be in a prod app name (guideline 2.3: no test or
# beta wording in the shipped app).
NOT_FOR_PROD_NAME = ("stg", "dev", "test", "beta", "staging")


def flavor_for(bundle_id: str, flavor: str | None) -> str:
    """The flavor given, or the one the bundle id suffix says."""
    if flavor:
        if flavor not in FLAVORS:
            raise SystemExit(f"patch_native: unknown flavor {flavor!r}")
        return flavor
    if bundle_id.endswith(".dev"):
        return "dev"
    if bundle_id.endswith(".stg"):
        return "staging"
    return "prod"


def check_prod_name(flavor: str, display_name: str) -> None:
    if flavor != "prod":
        return
    words = re.findall(r"[a-z]+", display_name.lower())
    bad = [w for w in words if w in NOT_FOR_PROD_NAME]
    if bad:
        raise SystemExit(f"patch_native: the prod display name must not contain {bad[0]!r}")


def pbx_line(line: str, bundle_id: str) -> str:
    """One project.pbxproj line with our bundle id, iOS minimum and iPhone-only family."""
    if "PRODUCT_BUNDLE_IDENTIFIER" in line:
        target = f"{bundle_id}.RunnerTests" if "RunnerTests" in line else bundle_id
        line = re.sub(r"PRODUCT_BUNDLE_IDENTIFIER = [^;]+;", f"PRODUCT_BUNDLE_IDENTIFIER = {target};", line)
    line = re.sub(r"IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;", f"IPHONEOS_DEPLOYMENT_TARGET = {MIN_IOS};", line)
    line = re.sub(r'TARGETED_DEVICE_FAMILY = "?[0-9,]+"?;', f'TARGETED_DEVICE_FAMILY = "{DEVICE_FAMILY_IPHONE}";', line)
    return line


def review_info(info: dict, flavor: str) -> dict:
    """Info.plist settings from the App Review audit (docs/apple-review/audit.md)."""
    out = dict(info)
    ats = dict(out.get("NSAppTransportSecurity", {}))
    # Never: HTTPS everywhere (guideline 2.5 / ATS).
    for key in ("NSAllowsArbitraryLoads", "NSAllowsArbitraryLoadsInWebContent", "NSAllowsArbitraryLoadsForMedia", "NSExceptionDomains"):
        ats.pop(key, None)
    if flavor == "dev":
        ats["NSAllowsLocalNetworking"] = True  # dev builds talk to the emulators
    else:
        ats.pop("NSAllowsLocalNetworking", None)
        for key in DEV_ONLY_INFO_KEYS:
            out.pop(key, None)
    if ats:
        out["NSAppTransportSecurity"] = ats
    else:
        out.pop("NSAppTransportSecurity", None)
    out["UISupportedInterfaceOrientations"] = list(ORIENTATIONS)
    out.pop("UISupportedInterfaceOrientations~ipad", None)
    # iPhone only; on an iPad the app runs in the iPhone compatibility mode.
    out["LSRequiresIPhoneOS"] = True
    return out


def localized_strings(text: str, flavor: str) -> str:
    """InfoPlist.strings without the developer-only texts outside dev."""
    if flavor == "dev":
        return text
    for key in DEV_ONLY_INFO_KEYS:
        text = re.sub(rf'^"{key}" = "[^"]*";\n', "", text, flags=re.M)
    return text


def icon_problem(data: bytes) -> str | None:
    """Why this PNG cannot be the App Store icon, or None (1024 x 1024, no alpha)."""
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return "not a PNG file"
    width, height = int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
    if (width, height) != (1024, 1024):
        return f"{width} x {height}, must be 1024 x 1024"
    if data[25] in (4, 6) or b"tRNS" in data[:4096]:
        return "has transparency (alpha), which App Store Connect refuses"
    return None


APP_ICON_CONTENTS = """{
  "images" : [
    {
      "filename" : "icon_1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""


def patch_app_icon() -> None:
    """Our icon instead of the Flutter placeholder (single 1024 size; Xcode makes the rest)."""
    icon_set = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    if not icon_set.parent.is_dir():
        return
    source = IOS_OVERRIDES / "AppIcon" / "icon_1024.png"
    problem = icon_problem(source.read_bytes())
    if problem:
        raise SystemExit(f"patch_native: tool/ios/AppIcon/icon_1024.png: {problem}")
    icon_set.mkdir(exist_ok=True)
    for old in icon_set.glob("*.png"):
        if old.name != "icon_1024.png":
            old.unlink()
    shutil.copyfile(source, icon_set / "icon_1024.png")
    (icon_set / "Contents.json").write_text(APP_ICON_CONTENTS, encoding="utf-8")
    log("app icon: tool/ios/AppIcon/icon_1024.png")


def patch_privacy_manifest() -> None:
    """The app's privacy manifest (tool/ios/configure_xcode.rb adds it to the target)."""
    runner = ROOT / "ios" / "Runner"
    if runner.is_dir():
        shutil.copyfile(IOS_OVERRIDES / "PrivacyInfo.xcprivacy", runner / "PrivacyInfo.xcprivacy")
        log("privacy manifest: ios/Runner/PrivacyInfo.xcprivacy")


REMOVED_INFO_KEYS = (
    "NSMotionUsageDescription",
    "TSLocationManagerLicense",
    # "Always" location is never asked (16 Nov 2026).
    "NSLocationAlwaysAndWhenInUseUsageDescription",
    "NSLocationAlwaysUsageDescription",
)

# geolocator_apple's documented switch: built with this, the plugin has no
# "Always" request, so iOS never needs an "Always" purpose text. CocoaPods
# builds get it from the Podfile (geolocator_bypass); Swift Package Manager
# builds read the environment variable of the same name (codemagic.yaml).
GEOLOCATOR_BYPASS = "BYPASS_PERMISSION_LOCATION_ALWAYS=1"
GEOLOCATOR_BYPASS_BLOCK = """    # school-carpool: no "Always" location (tool/patch_native.py).
    if target.name == 'geolocator_apple'
      target.build_configurations.each do |config|
        defs = config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] || ['$(inherited)']
        defs = [defs] if defs.is_a?(String)
        defs << '""" + GEOLOCATOR_BYPASS + """' unless defs.include?('""" + GEOLOCATOR_BYPASS + """')
        config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] = defs
      end
    end
"""


def geolocator_bypass(podfile: str) -> str:
    """Adds the geolocator switch to the Podfile's post_install (idempotent).

    Flutter's Podfile calls flutter_additional_ios_build_settings(target)
    inside `installer.pods_project.targets.each do |target|`; the block
    goes right after that call. A Podfile without it is returned unchanged
    (the built-app check then reports an "Always" request, if any).
    """
    if GEOLOCATOR_BYPASS in podfile:
        return podfile
    match = re.search(r"^[ \t]*flutter_additional_ios_build_settings\(target\)[ \t]*\n", podfile, flags=re.M)
    if not match:
        return podfile
    return podfile[: match.end()] + GEOLOCATOR_BYPASS_BLOCK + podfile[match.end():]
REMOVED_BG_TASKS = ("com.transistorsoft.fetch",)


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

def patch_ios(bundle_id: str, display_name: str, flavor: str | None = None) -> None:
    flavor = flavor_for(bundle_id, flavor)
    check_prod_name(flavor, display_name)
    ios = ROOT / "ios"
    if not ios.is_dir():
        log("ios/ not found, skipping iOS")
        return

    pbxproj = ios / "Runner.xcodeproj" / "project.pbxproj"

    def pbx(text: str) -> str:
        return "".join(pbx_line(line, bundle_id) for line in text.splitlines(keepends=True))

    patch_text(pbxproj, pbx)

    podfile = ios / "Podfile"
    if podfile.exists():
        patch_text(podfile, lambda t: re.sub(r"^#?\s*platform :ios, '[0-9.]+'",
                                             f"platform :ios, '{MIN_IOS}'", t, flags=re.M))
        patch_text(podfile, geolocator_bypass)
        if GEOLOCATOR_BYPASS not in podfile.read_text(encoding="utf-8"):
            log("WARNING: Podfile has no flutter_additional_ios_build_settings(target); "
                "geolocator keeps its Always request (set BYPASS_PERMISSION_LOCATION_ALWAYS=1)")

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
    for key in REMOVED_INFO_KEYS:
        info.pop(key, None)
    info = review_info(info, flavor)
    # Firebase Cloud Messaging, and (Prompt 13) live location during a run
    # with the phone locked. fetch and processing were only for the paid
    # location plugin.
    modes = [m for m in info.get("UIBackgroundModes", []) if m not in ("fetch", "processing")]
    for mode in ("remote-notification", "location"):
        if mode not in modes:
            modes.append(mode)
    info["UIBackgroundModes"] = modes
    tasks = [t for t in info.get("BGTaskSchedulerPermittedIdentifiers", []) if t not in REMOVED_BG_TASKS]
    if tasks:
        info["BGTaskSchedulerPermittedIdentifiers"] = tasks
    else:
        info.pop("BGTaskSchedulerPermittedIdentifiers", None)
    # Prompt 5: the Maps key comes from ios/Flutter/Maps.xcconfig (patch_maps_ios).
    info["GMSApiKey"] = "$(MAPS_API_KEY)"
    # Prompt 6: universal links (invite links) reach go_router.
    info["FlutterDeepLinkingEnabled"] = True
    # Usage analytics without any advertising identifier. Collection is
    # off in the app bundle; the app switches it on only after the parent
    # said yes (opt-in since 16 Nov 2026, guideline 5.1.1(ii)), so nothing
    # is sent before that.
    info["FIREBASE_ANALYTICS_COLLECTION_ENABLED"] = False
    info["GOOGLE_ANALYTICS_ADID_COLLECTION_ENABLED"] = False
    info["GOOGLE_ANALYTICS_IDFV_COLLECTION_ENABLED"] = False
    info["GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS"] = False
    info["GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_USER_DATA"] = False

    if info != before:
        with info_path.open("wb") as f:
            plistlib.dump(info, f, sort_keys=False)
        log("updated ios/Runner/Info.plist")

    # Entitlements: push notifications and App Attest, plus Associated
    # Domains when INVITE_LINK_DOMAIN is set (Prompt 6).
    entitlements = ios / "Runner" / "Runner.entitlements"
    shutil.copyfile(IOS_OVERRIDES / "Runner.entitlements", entitlements)
    patch_associated_domains(entitlements)
    patch_time_sensitive(entitlements)

    # Localized permission texts and display name.
    for lang in ("ar", "en"):
        target = ios / "Runner" / f"{lang}.lproj"
        target.mkdir(exist_ok=True)
        shutil.copyfile(IOS_OVERRIDES / f"{lang}.lproj" / "InfoPlist.strings", target / "InfoPlist.strings")
        strings = target / "InfoPlist.strings"
        patch_text(strings, lambda t: localized_strings(t, flavor))
        patch_text(strings, lambda t: re.sub(r'"CFBundleDisplayName" = "[^"]*";',
                                             f'"CFBundleDisplayName" = "{display_name_for(lang, display_name)}";', t))


_DOMAIN = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$")


# The marker of the classic launch used before 16 Nov 2026 (no UIScene).
# Kept so a project patched by an older run is migrated, never left behind.
CLASSIC_MARKER = "school-carpool: classic app delegate"

SCENE_MARKER = "school-carpool: UIScene app delegate"

# Flutter's "UIScene adoption" guide (docs.flutter.dev/release/
# breaking-changes/uiscenedelegate, read 16 Nov 2026) and the Flutter 3.50
# `flutter create` template: plugins are registered on the implicit engine
# in didInitializeImplicitFlutterEngine; the scene delegate
# (FlutterSceneDelegate) shows the Flutter view. Apps built with the iOS 27
# SDK must use UIScene or they do not launch (guideline 2.1(a)).
SCENE_APP_DELEGATE = """import Flutter
import UIKit

// """ + SCENE_MARKER + """ (tool/patch_native.py, 16 Nov 2026).
// UIScene life cycle (required from the iOS 27 SDK). The engine starts when
// the scene connects; nothing here needs a background launch any more: the
// app never asks for Always location and never relaunches for location
// (review-risks item 2). A run closed by iOS resumes from its local marker
// when the driver opens the app (lib/features/trips/run_recovery.dart).
// Code that must run before launch ends (Maps key, notification center
// delegate) is added to didFinishLaunching by the patches below.
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

// """ + SCENE_MARKER + """: Flutter's scene delegate, unchanged.
class SceneDelegate: FlutterSceneDelegate {
}
"""

SCENE_DELEGATE_CLASS = "FlutterSceneDelegate"
OWN_SCENE_DELEGATE_CLASS = "$(PRODUCT_MODULE_NAME).SceneDelegate"


def scene_manifest(delegate_class: str) -> dict:
    """The Application Scene Manifest of Flutter's guide (one scene, storyboard Main)."""
    return {
        "UIApplicationSupportsMultipleScenes": False,
        "UISceneConfigurations": {
            "UIWindowSceneSessionRoleApplication": [
                {
                    "UISceneClassName": "UIWindowScene",
                    "UISceneDelegateClassName": delegate_class,
                    "UISceneConfigurationName": "flutter",
                    "UISceneStoryboardFile": "Main",
                }
            ]
        },
    }


def scene_app_delegate(text: str) -> str:
    """The generated AppDelegate.swift becomes ours (idempotent: later patches are kept)."""
    return text if SCENE_MARKER in text else SCENE_APP_DELEGATE


def scene_delegate_file(text: str) -> str:
    """A SceneDelegate emptied by the old classic patch gets Flutter's back; any other is kept."""
    return SCENE_DELEGATE if CLASSIC_MARKER in text or "FlutterSceneDelegate" not in text else text


def scene_info(info: dict, has_scene_delegate: bool) -> dict:
    """Scene manifest present and pointing at a scene delegate that exists; Main storyboard set."""
    out = dict(info)
    wanted = OWN_SCENE_DELEGATE_CLASS if has_scene_delegate else SCENE_DELEGATE_CLASS
    manifest = out.get("UIApplicationSceneManifest")
    try:
        current = manifest["UISceneConfigurations"]["UIWindowSceneSessionRoleApplication"][0]["UISceneDelegateClassName"]
    except (KeyError, IndexError, TypeError):
        current = None
    if current not in (SCENE_DELEGATE_CLASS, OWN_SCENE_DELEGATE_CLASS) or (current == OWN_SCENE_DELEGATE_CLASS and not has_scene_delegate):
        out["UIApplicationSceneManifest"] = scene_manifest(wanted)
    out["UIMainStoryboardFile"] = out.get("UIMainStoryboardFile") or "Main"
    return out


def patch_ios_launch() -> None:
    runner = ROOT / "ios" / "Runner"
    if not runner.is_dir():
        return
    delegate = runner / "AppDelegate.swift"
    if delegate.exists():
        patch_text(delegate, scene_app_delegate)
    scene = runner / "SceneDelegate.swift"
    if scene.exists():
        patch_text(scene, scene_delegate_file)
    info_path = runner / "Info.plist"
    if info_path.exists():
        with info_path.open("rb") as f:
            info = plistlib.load(f)
        updated = scene_info(info, scene.exists())
        if updated != info:
            with info_path.open("wb") as f:
                plistlib.dump(updated, f, sort_keys=False)
            log("updated ios/Runner/Info.plist (UIScene manifest)")


def patch_associated_domains(entitlements: Path) -> None:
    """Adds applinks:<INVITE_LINK_DOMAIN> (universal links, F31) when set."""
    domain = os.environ.get("INVITE_LINK_DOMAIN", "").strip().lower()
    with entitlements.open("rb") as f:
        data = plistlib.load(f)
    key = "com.apple.developer.associated-domains"
    if not domain:
        data.pop(key, None)
    else:
        if not _DOMAIN.match(domain):
            raise SystemExit("patch_native: INVITE_LINK_DOMAIN must be a host name like <project>-links.web.app")
        data[key] = [f"applinks:{domain}"]
    with entitlements.open("wb") as f:
        plistlib.dump(data, f, sort_keys=False)
    log("associated domains: " + (f"applinks:{domain}" if domain else "none (INVITE_LINK_DOMAIN not set)"))


def patch_time_sensitive(entitlements: Path) -> None:
    """Adds the Time Sensitive Notifications entitlement when TIME_SENSITIVE_ALERTS=1 (Prompt 8)."""
    on = os.environ.get("TIME_SENSITIVE_ALERTS", "").strip() == "1"
    with entitlements.open("rb") as f:
        data = plistlib.load(f)
    key = "com.apple.developer.usernotifications.time-sensitive"
    if on:
        data[key] = True
    else:
        data.pop(key, None)
    with entitlements.open("wb") as f:
        plistlib.dump(data, f, sort_keys=False)
    log("time sensitive notifications: " + ("on" if on else "off (TIME_SENSITIVE_ALERTS not 1)"))


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

    # Plugins written in Kotlin that rely on AGP 9 built-in Kotlin (for example
    # screen_protector) skip the Kotlin plugin, while Flutter still ships with
    # android.builtInKotlin=false. Apply the Kotlin plugin to those modules so
    # their Kotlin sources compile. Remove once the app moves to built-in Kotlin.
    root_gradle = ROOT / "android" / "build.gradle.kts"
    if root_gradle.exists():
        def root_kts(text: str) -> str:
            if KOTLIN_FIX_MARKER in text:
                return text
            # Before the template's first subprojects block, whose
            # evaluationDependsOn(":app") can evaluate plugin modules early.
            index = text.find("subprojects {")
            if index == -1:
                return text.rstrip("\n") + "\n\n" + KOTLIN_FIX_BLOCK
            return text[:index] + KOTLIN_FIX_BLOCK + "\n" + text[index:]
        patch_text(root_gradle, root_kts)


KOTLIN_FIX_MARKER = "// school-carpool: kotlin for built-in-kotlin plugins"
KOTLIN_FIX_PLUGINS = ("screen_protector",)
KOTLIN_FIX_BLOCK = (
    KOTLIN_FIX_MARKER + "\n"
    "subprojects {\n"
    "    if (name in setOf(" + ", ".join(f'"{p}"' for p in KOTLIN_FIX_PLUGINS) + ")) {\n"
    "        pluginManager.withPlugin(\"com.android.library\") {\n"
    "            if (!pluginManager.hasPlugin(\"org.jetbrains.kotlin.android\")) {\n"
    "                pluginManager.apply(\"org.jetbrains.kotlin.android\")\n"
    "            }\n"
    "            // Match the module's Java target (17), as Flutter's own\n"
    "            // Kotlin setup does for other plugins.\n"
    "            tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {\n"
    "                compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)\n"
    "            }\n"
    "        }\n"
    "    }\n"
    "}\n"
)


# --------------------------------------------------------------------------
# Maps keys (Prompt 5)
# --------------------------------------------------------------------------

MAPS_MARKER = "school-carpool: Google Maps key"
_KEY = re.compile(r"^[A-Za-z0-9_-]*$")


def maps_key(name: str) -> str:
    """A key from the environment; refuses anything that is not key-shaped."""
    value = os.environ.get(name, "").strip()
    if not _KEY.match(value):
        raise SystemExit(f"patch_native: {name} has unexpected characters")
    return value


APP_DELEGATE_KEY_BLOCK = (
    "    // " + MAPS_MARKER + " (Info.plist GMSApiKey from ios/Flutter/Maps.xcconfig).\n"
    "    if let key = Bundle.main.object(forInfoDictionaryKey: \"GMSApiKey\") as? String, !key.isEmpty,\n"
    "       !key.hasPrefix(\"$(\") {\n"
    "      GMSServices.provideAPIKey(key)\n"
    "    }\n"
)


def patch_maps_ios() -> None:
    flutter_dir = ROOT / "ios" / "Flutter"
    if not flutter_dir.is_dir():
        return
    key = maps_key("MAPS_API_KEY_IOS")
    (flutter_dir / "Maps.xcconfig").write_text(
        f"// Generated by tool/patch_native.py from MAPS_API_KEY_IOS. Not committed.\nMAPS_API_KEY={key}\n",
        encoding="utf-8",
    )
    log("wrote ios/Flutter/Maps.xcconfig" + ("" if key else " (empty key: no Google map)"))
    for name in ("Debug.xcconfig", "Release.xcconfig", "Profile.xcconfig"):
        path = flutter_dir / name
        if path.exists():
            patch_text(path, lambda t: t if "Maps.xcconfig" in t else t.rstrip("\n") + '\n#include? "Maps.xcconfig"\n')

    delegate = ROOT / "ios" / "Runner" / "AppDelegate.swift"
    if not delegate.exists():
        log("AppDelegate.swift not found; add the Maps key by hand (SETUP.md section 15)")
        return

    def swift(text: str) -> str:
        if MAPS_MARKER in text:
            return text
        if "import GoogleMaps" not in text:
            text = re.sub(r"^import UIKit$", "import UIKit\nimport GoogleMaps", text, count=1, flags=re.M)
        match = re.search(r"didFinishLaunchingWithOptions[^{]*\{\n", text)
        if not match:
            log("WARNING: could not find didFinishLaunchingWithOptions in AppDelegate.swift (SETUP.md section 15)")
            return text
        return text[: match.end()] + APP_DELEGATE_KEY_BLOCK + text[match.end():]

    patch_text(delegate, swift)


ANDROID_PERMISSIONS = (
    "android.permission.ACCESS_COARSE_LOCATION",
    "android.permission.ACCESS_FINE_LOCATION",
)


def patch_maps_android() -> None:
    manifest = ROOT / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
    if not manifest.exists():
        return
    key = maps_key("MAPS_API_KEY_ANDROID")

    def xml(text: str) -> str:
        for perm in ANDROID_PERMISSIONS:
            if perm not in text:
                text = re.sub(r"(<manifest[^>]*>\n)", rf'\1    <uses-permission android:name="{perm}" />\n', text, count=1)
        meta = f'<meta-data android:name="com.google.android.geo.API_KEY" android:value="{key}" />'
        if "com.google.android.geo.API_KEY" in text:
            text = re.sub(r'<meta-data android:name="com.google.android.geo.API_KEY"[^>]*/>', meta, text)
        else:
            text = re.sub(r"(<application[^>]*>\n)", rf"\1        <!-- {MAPS_MARKER} -->\n        {meta}\n", text, count=1)
        return text

    patch_text(manifest, xml)


def patch_maps_web() -> None:
    index = ROOT / "web" / "index.html"
    if not index.exists():
        return
    key = maps_key("MAPS_API_KEY_WEB")
    if not key:
        return  # Stage 2: the website shows "map unavailable" until then.

    def html(text: str) -> str:
        tag = f'<script src="https://maps.googleapis.com/maps/api/js?key={key}&loading=async"></script>'
        if "maps.googleapis.com/maps/api/js" in text:
            return re.sub(r'<script src="https://maps.googleapis.com/maps/api/js[^"]*"></script>', tag, text)
        return text.replace("</head>", f"  <!-- {MAPS_MARKER} -->\n  {tag}\n</head>", 1)

    patch_text(index, html)


# --------------------------------------------------------------------------
# Alerts (Prompt 8): flutter_local_notifications
# --------------------------------------------------------------------------

ALERTS_MARKER = "school-carpool: local alerts"
APP_DELEGATE_ALERTS_BLOCK = (
    "    // " + ALERTS_MARKER + " (critical-alert alarms show while the app is open).\n"
    "    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate\n"
)


def patch_alerts_ios() -> None:
    delegate = ROOT / "ios" / "Runner" / "AppDelegate.swift"
    if not delegate.exists():
        return

    def swift(text: str) -> str:
        if ALERTS_MARKER in text:
            return text
        if "import UserNotifications" not in text:
            text = re.sub(r"^import UIKit$", "import UIKit\nimport UserNotifications", text, count=1, flags=re.M)
        match = re.search(r"didFinishLaunchingWithOptions[^{]*\{\n", text)
        if not match:
            log("WARNING: could not find didFinishLaunchingWithOptions in AppDelegate.swift (SETUP.md section 18)")
            return text
        return text[: match.end()] + APP_DELEGATE_ALERTS_BLOCK + text[match.end():]

    patch_text(delegate, swift)


DESUGAR_MARKER = "// school-carpool: desugaring for flutter_local_notifications"
DESUGAR_DEPENDENCY = 'coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")'
LOCAL_NOTIFICATION_RECEIVERS = (
    '        <!-- ' + ALERTS_MARKER + ' -->\n'
    '        <receiver android:exported="false" '
    'android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />\n'
    '        <receiver android:exported="false" '
    'android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">\n'
    '            <intent-filter>\n'
    '                <action android:name="android.intent.action.BOOT_COMPLETED"/>\n'
    '                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>\n'
    '                <action android:name="android.intent.action.QUICKBOOT_POWERON" />\n'
    '                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>\n'
    '            </intent-filter>\n'
    '        </receiver>\n'
)


def patch_alerts_android() -> None:
    gradle = ROOT / "android" / "app" / "build.gradle.kts"
    if gradle.exists():
        def kts(text: str) -> str:
            if DESUGAR_MARKER in text:
                return text
            if "isCoreLibraryDesugaringEnabled" not in text:
                text = re.sub(r"(compileOptions\s*\{\n)", r"\1        isCoreLibraryDesugaringEnabled = true\n", text, count=1)
            return text.rstrip("\n") + "\n\n" + DESUGAR_MARKER + "\ndependencies {\n    " + DESUGAR_DEPENDENCY + "\n}\n"
        patch_text(gradle, kts)
    manifest = ROOT / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
    if manifest.exists():
        def xml(text: str) -> str:
            if ALERTS_MARKER in text:
                return text
            perm = "android.permission.RECEIVE_BOOT_COMPLETED"
            if perm not in text:
                text = re.sub(r"(<manifest[^>]*>\n)", rf'\1    <uses-permission android:name="{perm}" />\n', text, count=1)
            return re.sub(r"(<application[^>]*>\n)", lambda m: m.group(1) + LOCAL_NOTIFICATION_RECEIVERS, text, count=1)
        patch_text(manifest, xml)


# --------------------------------------------------------------------------
# Wallet (Prompt 11B): local_auth
# --------------------------------------------------------------------------
# Wallet (Prompt 11B): local_auth
# --------------------------------------------------------------------------

def fragment_activity(text: str) -> str:
    """MainActivity extends FlutterFragmentActivity (local_auth needs a
    FragmentActivity for the AndroidX Biometric prompt). Idempotent."""
    if "FlutterFragmentActivity" in text:
        return text
    text = text.replace("import io.flutter.embedding.android.FlutterActivity",
                        "import io.flutter.embedding.android.FlutterFragmentActivity")
    return re.sub(r":\s*FlutterActivity\(\)", ": FlutterFragmentActivity()", text)


def patch_wallet_android() -> None:
    kotlin = ROOT / "android" / "app" / "src" / "main" / "kotlin"
    if not kotlin.is_dir():
        log("android MainActivity not found, skipping the wallet patch")
        return
    for activity in kotlin.rglob("MainActivity.kt"):
        patch_text(activity, fragment_activity)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ios-bundle-id", required=True)
    parser.add_argument("--android-app-id", required=True)
    parser.add_argument("--display-name", required=True)
    parser.add_argument("--flavor", choices=FLAVORS, default=None, help="default: from the bundle id suffix")
    args = parser.parse_args()

    patch_ios(args.ios_bundle_id, args.display_name, args.flavor)
    patch_app_icon()
    patch_privacy_manifest()
    # Before the Maps and alerts patches, which add lines to this delegate.
    patch_ios_launch()
    patch_maps_ios()
    patch_android(args.android_app_id)
    patch_maps_android()
    patch_maps_web()
    patch_alerts_ios()
    patch_alerts_android()
    patch_wallet_android()
    return 0


if __name__ == "__main__":
    sys.exit(main())
