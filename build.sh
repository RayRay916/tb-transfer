#!/bin/bash
# Build TBTransfer.app from a SwiftPM executable target.
# Usage: ./build.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
APP_NAME="TBTransfer"
BUILD_DIR=".build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
ROOT="$(cd "$(dirname "$0")" && pwd)"

cd "$ROOT"

echo "==> swift build (${CONFIG})"
if [ "$CONFIG" = "release" ]; then
    swift build -c release --arch arm64
    BIN_PATH=".build/release/${APP_NAME}"
else
    swift build
    BIN_PATH=".build/debug/${APP_NAME}"
fi

if [ ! -f "$BIN_PATH" ]; then
    echo "build failed: binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> bundling ${APP_NAME}.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/${APP_NAME}"
cp "Sources/${APP_NAME}/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "==> generating AppIcon.icns"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
# Standard macOS iconset: each size has a 1x and a @2x variant. We render
# every variant at its native pixel size so the rendered glyph stays crisp.
# name           1x px   @2x px
# 16x16          16      32
# 32x32          32      64
# 128x128        128     256
# 256x256        256     512
# 512x512        512     1024
"$BIN_PATH" --generate-icon "$ICONSET/icon_16x16.png"        --icon-size 16
"$BIN_PATH" --generate-icon "$ICONSET/icon_16x16@2x.png"     --icon-size 32
"$BIN_PATH" --generate-icon "$ICONSET/icon_32x32.png"        --icon-size 32
"$BIN_PATH" --generate-icon "$ICONSET/icon_32x32@2x.png"     --icon-size 64
"$BIN_PATH" --generate-icon "$ICONSET/icon_128x128.png"      --icon-size 128
"$BIN_PATH" --generate-icon "$ICONSET/icon_128x128@2x.png"   --icon-size 256
"$BIN_PATH" --generate-icon "$ICONSET/icon_256x256.png"      --icon-size 256
"$BIN_PATH" --generate-icon "$ICONSET/icon_256x256@2x.png"   --icon-size 512
"$BIN_PATH" --generate-icon "$ICONSET/icon_512x512.png"      --icon-size 512
"$BIN_PATH" --generate-icon "$ICONSET/icon_512x512@2x.png"   --icon-size 1024
iconutil --convert icns "$ICONSET" --output "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc code signing"
codesign --force --deep --sign - "$APP_DIR" 2>&1 | grep -v "replacing existing signature" || true

echo "==> done: $APP_DIR"
echo "    run:  open $APP_DIR"
echo "    or:   $APP_DIR/Contents/MacOS/${APP_NAME}"
