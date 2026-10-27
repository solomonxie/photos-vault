#!/bin/sh
# Archive a Release build and upload it to App Store Connect in one go.
#
# Needs: Xcode → Settings → Accounts signed in to the developer Apple ID,
# and ios/Flutter/Local.xcconfig holding LOCAL_DEVELOPMENT_TEAM + APP_BUNDLE_ID (see the
# README — that file is gitignored, the team ID is not in the repo).
#
# The build number is a timestamp so every upload is higher than the last.
# The user-visible version is `version:` in pubspec.yaml.
#
# Usage: scripts/release-ios.sh [build-number]
set -e
cd "$(dirname "$0")/.."

FLUTTER=.tools/flutter/bin/flutter
[ -x "$FLUTTER" ] || FLUTTER=flutter

# One binary for every storefront: the app reads the App Store country at
# launch. A forced `cn` (STOREFRONT=CHN, for testing) must never ship.
echo "APP_STORE_REGION = us" > ios/Flutter/Store.xcconfig

# Never any demo defines: they would put the demo bucket secret in every
# user's binary.
case "$*" in
  *dart-define*) echo "release-ios.sh: no --dart-define in a release" >&2; exit 1 ;;
esac

BUILD=${1:-$(date +%Y%m%d%H%M)}
SYMBOLS=build/symbols/$BUILD
ARCHIVE=build/ios/archive/Runner.xcarchive
APP=$ARCHIVE/Products/Applications/Runner.app
BUDGET=33

# Archive and export locally first: the secret scan and the size check
# run before anything leaves this Mac. Same options as the upload, only
# the destination differs.
LOCAL_EXPORT=build/ios/ExportOptions.local.plist
mkdir -p build/ios
cp ios/ExportOptions.plist "$LOCAL_EXPORT"
plutil -replace destination -string export "$LOCAL_EXPORT"

# Obfuscated, so these symbol files are the only way to read a crash report
# from this build.
"$FLUTTER" build ipa --release \
  --build-number="$BUILD" \
  --obfuscate --split-debug-info="$SYMBOLS" \
  --export-options-plist="$LOCAL_EXPORT"

scripts/check-no-demo-secrets.sh "$APP"
du -sh "$APP"
mb=$(du -sm "$APP" | cut -f1)
if [ "$mb" -gt "$BUDGET" ]; then
  echo "release-ios.sh: $mb MB, over the $BUDGET MB budget (CLAUDE.md). Not uploaded." >&2
  echo "Upload anyway with: make upload" >&2
  exit 1
fi

# build/ goes with `flutter clean`; the symbols must outlive it.
KEEP="$HOME/Library/Developer/Xcode/Archives/photos-vault-symbols/$BUILD"
mkdir -p "$KEEP"
cp -R "$SYMBOLS/." "$KEEP/"

# An App Store Connect API key, when set, instead of Xcode's signed-in account.
AUTH=()
if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
  AUTH=(-authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
    -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist ios/ExportOptions.plist \
  -exportPath build/ios/ipa -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"}

echo
echo "Uploaded build $BUILD. Processing in App Store Connect takes 15–60 min."
echo "Crash symbols for it: $KEEP — keep these."
echo
echo "If only the upload failed, retry it without rebuilding: make upload"
