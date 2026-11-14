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
  Launch   (Prompt 13 review, blocker 2) classic app delegate, no UIScene:
           the AppDelegate starts the Flutter engine (Dart main) and
           registers the plugins in didFinishLaunching, also when iOS
           relaunches the app in the background for location, and plugins
           get the real launch options. The scene manifest is removed and a
           generated SceneDelegate.swift is emptied. Revisit when Apple
           requires UIScene (docs/DECISIONS.md).
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
    # Prompt 13: "While Using the App" is the only location permission asked.
    "NSLocationWhenInUseUsageDescription":
        "Your location sets your home on the map. When you drive a school run, it shows your car "
        "to the parents of the children in it, also with the phone locked, until the run ends.",
    # Prompt 13 (owner request 13:44): "Always" is OPTIONAL, offered once to
    # drivers so a run resumes if iOS closes the app (run_recovery plugin).
    "NSLocationAlwaysAndWhenInUseUsageDescription":
        "Optional: with Always, a school run you drive starts sharing your location again by itself "
        "if iPhone closes the app. Used only during runs you start, with the blue indicator, "
        "for the parents of the children in your car; it stops when the run ends.",
    "NSFaceIDUsageDescription":
        "Face ID unlocks the app and confirms every wallet transfer.",
    "NSLocalNetworkUsageDescription":
        "Developer builds connect to test servers on your local network.",
}

# Keys and values from the paid location plugin (removed in Prompt 13),
# dropped from an Info.plist generated before.
REMOVED_INFO_KEYS = ("NSMotionUsageDescription", "TSLocationManagerLicense")
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
    for key in REMOVED_INFO_KEYS:
        info.pop(key, None)
    ats = dict(info.get("NSAppTransportSecurity", {}))
    ats["NSAllowsLocalNetworking"] = True  # dev builds talk to the emulators
    info["NSAppTransportSecurity"] = ats
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
    # Prompt 12: usage analytics without any advertising identifier. The
    # app switches collection on after reading the parent's choice (on by
    # default, off in Settings), so nothing is sent before that.
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
        patch_text(strings, lambda t: re.sub(r'"CFBundleDisplayName" = "[^"]*";',
                                             f'"CFBundleDisplayName" = "{display_name_for(lang, display_name)}";', t))


_DOMAIN = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$")


CLASSIC_MARKER = "school-carpool: classic app delegate"

CLASSIC_APP_DELEGATE = """import Flutter
import UIKit

// """ + CLASSIC_MARKER + """ (tool/patch_native.py, Prompt 13 review).
// No UIScene: when iOS relaunches the app in the background for a
// significant location change during a run, no scene connects, so the
// engine must start here for Dart main() (run recovery) to run, and plugins
// must be registered here to receive the real launch options.
@main
@objc class AppDelegate: FlutterAppDelegate {
  private lazy var flutterEngine = FlutterEngine(name: "school_carpool")

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Dart main() starts now, with or without a screen.
    flutterEngine.run()
    GeneratedPluginRegistrant.register(with: flutterEngine)
    let controller = FlutterViewController(engine: flutterEngine, nibName: nil, bundle: nil)
    window = UIWindow(frame: UIScreen.main.bounds)
    window?.rootViewController = controller
    window?.makeKeyAndVisible()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
"""

EMPTY_SCENE_DELEGATE = (
    "// " + CLASSIC_MARKER + ": not used (no UIScene; tool/patch_native.py).\n"
)


def classic_app_delegate(text: str) -> str:
    """The generated AppDelegate.swift becomes the classic one (idempotent)."""
    return text if CLASSIC_MARKER in text else CLASSIC_APP_DELEGATE


def classic_info(info: dict) -> dict:
    """No scene manifest and no main storyboard (the AppDelegate builds the window)."""
    out = dict(info)
    out.pop("UIApplicationSceneManifest", None)
    out.pop("UIMainStoryboardFile", None)
    return out


def patch_ios_launch() -> None:
    runner = ROOT / "ios" / "Runner"
    if not runner.is_dir():
        return
    delegate = runner / "AppDelegate.swift"
    if delegate.exists():
        patch_text(delegate, classic_app_delegate)
    scene = runner / "SceneDelegate.swift"
    if scene.exists():
        # Emptied, not deleted: the Xcode project still lists the file.
        patch_text(scene, lambda t: t if CLASSIC_MARKER in t else EMPTY_SCENE_DELEGATE)
    info_path = runner / "Info.plist"
    if info_path.exists():
        with info_path.open("rb") as f:
            info = plistlib.load(f)
        updated = classic_info(info)
        if updated != info:
            with info_path.open("wb") as f:
                plistlib.dump(updated, f, sort_keys=False)
            log("updated ios/Runner/Info.plist (classic launch, no scene manifest)")


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
    args = parser.parse_args()

    patch_ios(args.ios_bundle_id, args.display_name)
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
