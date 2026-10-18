#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${RB_BUILD_DIR:-$PROJECT_DIR/.build}"
SDK="$(xcrun --show-sdk-path)"
mkdir -p "$BUILD_DIR/module-cache"
FIXTURE="$BUILD_DIR/TestFixture.app"
RUNNER="$BUILD_DIR/IntegrationTests.app"
for bundle in "$FIXTURE" "$RUNNER"; do mkdir -p "$bundle/Contents/MacOS"; done
cat > "$FIXTURE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.resourceboard.fixture</string>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
cat > "$RUNNER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.resourceboard.integration</string>
<key>CFBundleExecutable</key><string>IntegrationTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -O -sdk "$SDK" -module-cache-path "$BUILD_DIR/module-cache" \
    "$PROJECT_DIR/Tests/TerminationFixture.swift" -framework IOKit -framework AppKit -o "$FIXTURE/Contents/MacOS/Fixture"
xcrun clang -O2 -isysroot "$SDK" -mmacosx-version-min=13.0 -I "$PROJECT_DIR/Sources/CSystem/include" \
    -c "$PROJECT_DIR/Sources/CSystem/SystemProbe.c" -o "$BUILD_DIR/SystemProbe-integration.o"
xcrun swiftc -parse-as-library -O -sdk "$SDK" -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path "$BUILD_DIR/module-cache" -I "$PROJECT_DIR/Sources/CSystem/include" \
    "$PROJECT_DIR/Sources/ResourceBoard/Models.swift" "$PROJECT_DIR/Sources/ResourceBoard/MonitorStore.swift" \
    "$PROJECT_DIR/Tests/TerminationTests.swift" "$BUILD_DIR/SystemProbe-integration.o" \
    -framework IOKit -framework AppKit -framework ServiceManagement -framework UserNotifications -o "$RUNNER/Contents/MacOS/IntegrationTests"
codesign --force --sign - "$FIXTURE"
codesign --force --sign - "$RUNNER"
if [ "${RB_BUILD_ONLY:-0}" != "1" ]; then
    "$RUNNER/Contents/MacOS/IntegrationTests" "$FIXTURE/Contents/MacOS/Fixture"
fi
