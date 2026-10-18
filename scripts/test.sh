#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${RB_BUILD_DIR:-$PROJECT_DIR/.build}"
SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
mkdir -p "$BUILD_DIR/module-cache"
xcrun clang -O2 -arch "$ARCH" -mmacosx-version-min=13.0 -isysroot "$SDK" \
    -I "$PROJECT_DIR/Sources/CSystem/include" -c "$PROJECT_DIR/Sources/CSystem/SystemProbe.c" -o "$BUILD_DIR/SystemProbe-test.o"
xcrun swiftc -O -sdk "$SDK" -target "$ARCH-apple-macosx13.0" -module-cache-path "$BUILD_DIR/module-cache" \
    -I "$PROJECT_DIR/Sources/CSystem/include" "$PROJECT_DIR/Sources/ResourceBoard/Models.swift" \
    "$PROJECT_DIR/Tests/MonitorTests.swift" "$BUILD_DIR/SystemProbe-test.o" -framework IOKit -framework AppKit -o "$BUILD_DIR/MonitorTests"
"$BUILD_DIR/MonitorTests"
