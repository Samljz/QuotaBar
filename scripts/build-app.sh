#!/bin/bash
# Build QuotaBar as a proper macOS .app bundle so the menu bar item works and
# no Dock icon appears (LSUIElement).
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="QuotaBar"
BUILD_DIR=".build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build (release)"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# A stable identity lets the login keychain remember this app. Ad-hoc signing
# changes every rebuild, so macOS asks for the login password on every launch.
echo "==> codesign (QuotaBar Local)"
"$(dirname "$0")/ensure-codesign-identity.sh"
codesign --force --sign "QuotaBar Local" --identifier com.lijunze.quotabar "$APP_DIR"

echo ""
echo "Built: $APP_DIR"
echo "Run:   open $APP_DIR"
