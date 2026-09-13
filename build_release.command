#!/bin/bash
# Builds NFLBar.app, signs with Developer ID, notarizes, staples, and zips.
# Run from anywhere: ~/Projects/NFLBar/build_release.command
set -e
cd "$(dirname "$0")"

APP=NFLBar
VERSION="${1:-1.0.0}"
BUNDLE_ID=com.vishalmehta.nflbar
TEAM_ID=8V78C4992R
NOTARY_PROFILE=plexpull-notary
SIGN_ID="Developer ID Application"

echo "==> Building release binary"
swift build -c release --arch arm64 --arch x86_64 2>/dev/null || swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP"

echo "==> Assembling $APP.app"
rm -rf dist && mkdir -p dist/$APP.app/Contents/MacOS dist/$APP.app/Contents/Resources
cp "$BIN" dist/$APP.app/Contents/MacOS/$APP
[ -f AppIcon.icns ] && cp AppIcon.icns dist/$APP.app/Contents/Resources/

cat > dist/$APP.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>NFLBar</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Not affiliated with the NFL or ESPN.</string>
</dict></plist>
PLIST

cat > dist/entitlements.plist <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.network.client</key><true/>
</dict></plist>
ENT

echo "==> Signing"
codesign --force --deep --options runtime --timestamp \
  --entitlements dist/entitlements.plist \
  --sign "$SIGN_ID" dist/$APP.app
codesign --verify --strict --verbose=2 dist/$APP.app

echo "==> Notarizing (this takes 1-5 minutes)"
ditto -c -k --keepParent dist/$APP.app dist/$APP-notarize.zip
xcrun notarytool submit dist/$APP-notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple dist/$APP.app
rm dist/$APP-notarize.zip dist/entitlements.plist

echo "==> Packaging"
ditto -c -k --keepParent dist/$APP.app dist/$APP-$VERSION.zip
spctl -a -vv dist/$APP.app

echo
echo "Done: dist/$APP-$VERSION.zip"
