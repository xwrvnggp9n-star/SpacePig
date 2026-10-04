#!/bin/zsh
# Builds a Release, Developer ID signed SystemDataLens.app, verifies signatures,
# packages a DMG and notarizes it when the notarytool profile exists.
#   scripts/build.sh            build + DMG
#   scripts/build.sh --install  also copy to /Applications
set -euo pipefail
cd "${0:A:h}/.."
NOTARY_PROFILE=${NOTARY_PROFILE:-dymo-notary}

xcodegen generate --quiet
rm -rf build
# A unique build number per build lets the app detect a stale helper still running.
BUILD_NUMBER=${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}
xcodebuild -project SystemDataLens.xcodeproj -scheme SystemDataLens -configuration Release \
  -derivedDataPath build/dd -quiet CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build
APP=build/dd/Build/Products/Release/SystemDataLens.app

echo "==> verifying signatures"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP/Contents/MacOS/SystemDataLensHelper" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority=Developer ID Application|flags"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow && { echo "get-task-allow present; refusing"; exit 1; }
test -f "$APP/Contents/Library/LaunchDaemons/app.sklar.SystemDataLens.helper.plist"
plutil -lint "$APP/Contents/Library/LaunchDaemons/app.sklar.SystemDataLens.helper.plist"

VERSION=$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)
mkdir -p dist
DMG=dist/SystemDataLens-$VERSION.dmg
rm -f "$DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "SystemDataLens $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --sign "Developer ID Application" --timestamp "$DMG"

if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "==> notarizing"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
else
  echo "==> skipping notarization: profile $NOTARY_PROFILE unavailable (check the Apple Developer agreement)"
fi
echo "==> $DMG"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/SystemDataLens.app
  cp -R "$APP" /Applications/
  echo "==> installed /Applications/SystemDataLens.app"
fi
