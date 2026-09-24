#!/bin/sh
# Archive a Release build and upload it to App Store Connect in one go.
#
# Needs: Xcode → Settings → Accounts signed in to the developer Apple ID,
# and ios/Flutter/Signing.xcconfig holding LOCAL_DEVELOPMENT_TEAM (see the
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

BUILD=${1:-$(date +%Y%m%d%H%M)}
SYMBOLS=build/symbols/$BUILD

# Obfuscated, so these symbol files are the only way to read a crash report
# from this build. ExportOptions.plist carries destination=upload, so the
# export step at the end of this is the upload.
"$FLUTTER" build ipa --release \
  --build-number="$BUILD" \
  --obfuscate --split-debug-info="$SYMBOLS" \
  --export-options-plist=ios/ExportOptions.plist

du -sh build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app 2>/dev/null || true
echo
echo "Uploaded build $BUILD. Processing in App Store Connect takes 15–60 min."
echo "Crash symbols for it: $SYMBOLS — keep these."
echo
echo "If only the upload failed, retry it without rebuilding:"
echo "  xcodebuild -exportArchive \\"
echo "    -archivePath build/ios/archive/Runner.xcarchive \\"
echo "    -exportOptionsPlist ios/ExportOptions.plist \\"
echo "    -exportPath build/ios/ipa -allowProvisioningUpdates"
