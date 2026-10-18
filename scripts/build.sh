#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${RB_BUILD_DIR:-$PROJECT_DIR/.build}"
OUTPUT_DIR="${RB_OUTPUT_DIR:-$PROJECT_DIR/dist}"
ARCH="${RB_ARCH:-$(uname -m)}"
SDK="$(xcrun --show-sdk-path)"
mkdir -p "$BUILD_DIR/module-cache" "$OUTPUT_DIR"
APP="$OUTPUT_DIR/资源看板.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun clang -O2 -Wall -Wextra -arch "$ARCH" -mmacosx-version-min=13.0 -isysroot "$SDK" \
    -I "$PROJECT_DIR/Sources/CSystem/include" -c "$PROJECT_DIR/Sources/CSystem/SystemProbe.c" -o "$BUILD_DIR/SystemProbe-$ARCH.o"
xcrun swiftc -O -target "$ARCH-apple-macosx13.0" -sdk "$SDK" \
    -module-cache-path "$BUILD_DIR/module-cache" -I "$PROJECT_DIR/Sources/CSystem/include" \
    "$PROJECT_DIR"/Sources/ResourceBoard/*.swift "$BUILD_DIR/SystemProbe-$ARCH.o" \
    -framework IOKit -framework AppKit -framework SwiftUI -framework ServiceManagement -framework UserNotifications \
    -o "$APP/Contents/MacOS/ResourceBoard"
cp "$PROJECT_DIR/Info.plist" "$APP/Contents/Info.plist"
xcrun swiftc -O -sdk "$SDK" -module-cache-path "$BUILD_DIR/module-cache" \
    "$PROJECT_DIR/scripts/MakeIcon.swift" -framework IOKit -framework AppKit -o "$BUILD_DIR/MakeIcon"
"$BUILD_DIR/MakeIcon" "$BUILD_DIR/AppIcon.iconset" "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
echo "$APP"
