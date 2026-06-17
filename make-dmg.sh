#!/bin/bash
# Package .build/TBTransfer.app into a drag-to-Applications DMG.
# Usage: ./make-dmg.sh   (run ./build.sh release first)
set -euo pipefail

APP_NAME="TBTransfer"
VOL_NAME="TBTransfer"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${ROOT}/.build/${APP_NAME}.app"
DMG="${ROOT}/.build/${APP_NAME}.dmg"

cd "$ROOT"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run ./build.sh release first" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"

echo "==> staging"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# Copy the app (preserves the ad-hoc signature) and add an /Applications alias
# so the user can drag the app straight onto it.
cp -R "$APP" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"

# Drop a short README so the window isn't bare.
cat > "$STAGE/Install — drag TBTransfer to Applications.txt" <<EOF
TBTransfer ${VERSION}

To install: drag "TBTransfer.app" onto the "Applications" folder in this window.

First launch (ad-hoc signed build): right-click TBTransfer in Applications →
Open → Open, to bypass Gatekeeper's unidentified-developer prompt. You only
need to do this once.
EOF

echo "==> creating compressed DMG"
rm -f "$DMG"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG" >/dev/null

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "==> done: $DMG  (${SIZE}, v${VERSION})"
