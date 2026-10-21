#!/bin/bash
# Builds Trove.app — a self-contained, ad-hoc signed macOS bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
APP_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$ROOT/Resources/Info.plist")
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"

echo "▸ Rendering icon…"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
swift Scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$ROOT/.build/$CONFIG/Trove" "$APP/Contents/MacOS/Trove"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BUILD_DIR/StatusIcon.pdf" "$BUILD_DIR/StatusIconPaused.pdf" "$APP/Contents/Resources/"
ditto "$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null 2>&1 || {
  echo "  codesign failed"; exit 1;
}

echo "✓ $APP"
du -sh "$APP" | awk '{print "  size: "$1}'
