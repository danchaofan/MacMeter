#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${RB_BUILD_DIR:-$PROJECT_DIR/.build}"
OUTPUT_DIR="${RB_OUTPUT_DIR:-$PROJECT_DIR/dist}"
for ARCH in x86_64 arm64; do
    RB_ARCH="$ARCH" RB_BUILD_DIR="$BUILD_DIR/$ARCH" RB_OUTPUT_DIR="$BUILD_DIR/release-$ARCH" \
        bash "$PROJECT_DIR/scripts/build.sh"
done
mkdir -p "$OUTPUT_DIR"
APP="$OUTPUT_DIR/资源看板.app"
ditto "$BUILD_DIR/release-x86_64/资源看板.app" "$APP"
lipo -create "$BUILD_DIR/release-x86_64/资源看板.app/Contents/MacOS/ResourceBoard" \
    "$BUILD_DIR/release-arm64/资源看板.app/Contents/MacOS/ResourceBoard" -output "$BUILD_DIR/ResourceBoard-universal"
cp "$BUILD_DIR/ResourceBoard-universal" "$APP/Contents/MacOS/ResourceBoard"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
lipo -archs "$APP/Contents/MacOS/ResourceBoard"
echo "$APP"
