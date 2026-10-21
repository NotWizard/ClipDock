#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
./Scripts/build.sh
APP_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' Resources/Info.plist)
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
ARCH=$(uname -m)
ARCHIVE_NAME="$APP_NAME-$VERSION-macos-$ARCH.zip"
ARCHIVE="build/$ARCHIVE_NAME"
ditto -c -k --sequesterRsrc --keepParent "build/$APP_NAME.app" "$ARCHIVE"
cd "$ROOT/build"
shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
echo "$ARCHIVE"
