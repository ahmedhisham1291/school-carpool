#!/usr/bin/env bash
# Prepares a fresh checkout for building: generates the native folders,
# applies our iOS/Android settings, fetches packages and generates the
# localizations. Run it on a Mac or in CI before any flutter command.
#
#   FLAVOR=dev tool/bootstrap.sh          # default flavor: dev
#   FLAVOR=staging tool/bootstrap.sh
#
# Environment (all optional):
#   FLAVOR            dev | staging | prod. Picks bundle id and display name.
#   BUNDLE_ID_BASE    Reverse-domain base id. OPEN QUESTION for the owner;
#                     placeholder below. Must match the App IDs in the Apple
#                     Developer account and the apps in Firebase.
#   FLUTTER           Path to the flutter binary (default: flutter).
#   MAPS_API_KEY_IOS      Google Maps key for this flavor's iPhone app
#   MAPS_API_KEY_ANDROID  (restricted to the bundle id / package name),
#   MAPS_API_KEY_WEB      written into the generated native folders only,
#                         never into the repository (SETUP.md section 15).
#                         Build with --dart-define=MAPS_ENABLED=true when set.
#
# Native folders (ios/, android/, web/) are NOT committed: this script
# recreates them, so every change we need in them lives in tool/ and is
# applied here. Steps that need Xcode by hand are listed in SETUP.md.
set -euo pipefail

cd "$(dirname "$0")/.."

FLAVOR="${FLAVOR:-dev}"
BUNDLE_ID_BASE="${BUNDLE_ID_BASE:-org.schoolcarpool.app}"
FLUTTER="${FLUTTER:-flutter}"
ORG="${BUNDLE_ID_BASE%.*}"

case "$FLAVOR" in
  dev)     SUFFIX=".dev"; DISPLAY_NAME="School Carpool Dev" ;;
  staging) SUFFIX=".stg"; DISPLAY_NAME="School Carpool Stg" ;;
  prod)    SUFFIX="";     DISPLAY_NAME="School Carpool" ;;
  *) echo "bootstrap: unknown FLAVOR '$FLAVOR' (use dev, staging or prod)" >&2; exit 1 ;;
esac
APP_ID="${BUNDLE_ID_BASE}${SUFFIX}"

echo "bootstrap: flavor=$FLAVOR app id=$APP_ID"
"$FLUTTER" --version

# 1. Native folders --------------------------------------------------------
if [[ ! -d ios || ! -d android || ! -d web ]]; then
  echo "bootstrap: generating native folders with flutter create"
  # Existing files (lib/, pubspec.yaml, README.md, ...) are never overwritten.
  "$FLUTTER" create \
    --platforms=ios,android,web \
    --org "$ORG" \
    --project-name school_carpool \
    --empty \
    .
fi

# flutter create may add a sample test that does not match our app.
if [[ -f test/widget_test.dart ]] && grep -q "MyApp" test/widget_test.dart; then
  rm test/widget_test.dart
  echo "bootstrap: removed generated test/widget_test.dart"
fi

# 2. Our native settings ---------------------------------------------------
python3 tool/patch_native.py \
  --ios-bundle-id "$APP_ID" \
  --android-app-id "$APP_ID" \
  --display-name "$DISPLAY_NAME"

if [[ "$(uname)" == "Darwin" && -d ios ]]; then
  if ruby -e "require 'xcodeproj'" 2>/dev/null; then
    ruby tool/ios/configure_xcode.rb
  else
    cat <<'EOF'
bootstrap: WARNING the xcodeproj Ruby gem is missing (install CocoaPods, or
`gem install xcodeproj`). Do these steps by hand in Xcode (SETUP.md, "Xcode
by hand"): set Runner > Signing & Capabilities > Code Signing Entitlements to
Runner/Runner.entitlements, and add ios/Runner/ar.lproj and en.lproj
InfoPlist.strings to the Runner target as localized resources.
EOF
  fi
fi

# 3. Packages and generated code -------------------------------------------
"$FLUTTER" pub get
"$FLUTTER" gen-l10n

echo "bootstrap: done. Next: flutter run -t lib/main_${FLAVOR}.dart"
