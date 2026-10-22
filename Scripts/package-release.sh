#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
UPDATE_KEY="${CLIPDOCK_UPDATE_KEY_FILE:-$HOME/Library/Application Support/ClipDock Release Signing/ed25519-private-key}"
if [[ ! -f "$UPDATE_KEY" ]]; then
  echo "Update signing key missing. Set CLIPDOCK_UPDATE_KEY_FILE to your private Ed25519 key file (see CONTRIBUTING.md)." >&2
  exit 1
fi
CLIPDOCK_REQUIRE_STABLE_SIGNING=1 ./Scripts/build.sh
APP_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' Resources/Info.plist)
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
ARCH=$(uname -m)
ARCHIVE_NAME="$APP_NAME-$VERSION-macos-$ARCH.zip"
ARCHIVE="build/$ARCHIVE_NAME"
ditto -c -k --sequesterRsrc --keepParent "build/$APP_NAME.app" "$ARCHIVE"
REPOSITORY=$(/usr/libexec/PlistBuddy -c 'Print :GitHubRepository' Resources/Info.plist)
CAST_DIR=$(mktemp -d "$ROOT/build/appcast.XXXXXX")
trap 'rm -rf "$CAST_DIR"' EXIT
cp "$ARCHIVE" "$CAST_DIR/"
python3 - "$VERSION" "$CAST_DIR/${ARCHIVE_NAME%.zip}.txt" <<'PY'
from pathlib import Path
import sys
version, destination = sys.argv[1:]
text = Path('CHANGELOG.md').read_text()
heading = '## ' + version + '\n'
if heading not in text:
    raise SystemExit('Missing CHANGELOG entry for ' + version)
Path(destination).write_text(text.split(heading, 1)[1].split('\n## ', 1)[0].strip() + '\n')
PY
"$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  --ed-key-file "$UPDATE_KEY" --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" \
  -o "$ROOT/build/appcast.xml" "$CAST_DIR"
"$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update" --ed-key-file "$UPDATE_KEY" --verify "$ROOT/build/appcast.xml"
cd "$ROOT/build"
shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
echo "$ARCHIVE"
