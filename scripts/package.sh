#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${RB_BUILD_DIR:-$PROJECT_DIR/.build}"
PACKAGE_DIR="${RB_PACKAGE_DIR:-$PROJECT_DIR/installers}"
APP_PATH="${RB_APP_PATH:-}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PROJECT_DIR/Info.plist")"

if [ -z "$APP_PATH" ]; then
    APP_OUTPUT="$BUILD_DIR/package-app"
    RB_BUILD_DIR="$BUILD_DIR" RB_OUTPUT_DIR="$APP_OUTPUT" bash "$PROJECT_DIR/scripts/build-universal.sh"
    APP_PATH="$APP_OUTPUT/资源看板.app"
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
if [ "$APP_VERSION" != "$VERSION" ] || [ "$APP_IDENTIFIER" != "$BUNDLE_ID" ]; then
    echo 'The application version or identifier does not match this source tree.' >&2
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
/usr/bin/lipo "$APP_PATH/Contents/MacOS/ResourceBoard" -verify_arch x86_64 arm64
mkdir -p "$BUILD_DIR" "$PACKAGE_DIR"
STAGE_DIR="$(mktemp -d "$BUILD_DIR/installer.XXXXXX")"
STAGE_DIR="$(cd "$STAGE_DIR" && pwd)"
PACKAGE_DIR="$(cd "$PACKAGE_DIR" && pwd)"
trap 'rm -rf "$STAGE_DIR"' EXIT
mkdir -p "$STAGE_DIR/payload"
/usr/bin/ditto --norsrc --noextattr --noqtn "$APP_PATH" "$STAGE_DIR/payload/资源看板.app"
/usr/bin/codesign --verify --deep --strict "$STAGE_DIR/payload/资源看板.app"

# Disable relocation: an existing development copy must not change the installation destination.
/usr/bin/pkgbuild --analyze --root "$STAGE_DIR/payload" "$STAGE_DIR/components.plist"
python3 - "$STAGE_DIR" <<'PY'
import pathlib, plistlib, sys
stage = pathlib.Path(sys.argv[1])
path = stage / 'components.plist'
components = plistlib.loads(path.read_bytes())
assert len(components) == 1 and components[0]['RootRelativeBundlePath'] == '资源看板.app'
components[0].update(BundleIsRelocatable=False, BundleIsVersionChecked=True,
                     BundleHasStrictIdentifier=True, BundleOverwriteAction='upgrade')
path.write_bytes(plistlib.dumps(components))
(stage / 'requirements.plist').write_bytes(plistlib.dumps({'os':['13.0'], 'arch':['x86_64','arm64'], 'home':False}))
PY

/usr/bin/pkgbuild --root "$STAGE_DIR/payload" --component-plist "$STAGE_DIR/components.plist" \
    --identifier "$BUNDLE_ID.installer" --version "$VERSION" --install-location /Applications \
    --ownership recommended "$STAGE_DIR/MacMeter-component.pkg"
/usr/bin/productbuild --synthesize --product "$STAGE_DIR/requirements.plist" \
    --package "$STAGE_DIR/MacMeter-component.pkg" "$STAGE_DIR/Distribution.xml"
python3 - "$STAGE_DIR/Distribution.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()
title = root.find('title')
if title is None:
    title = ET.Element('title'); root.insert(0, title)
title.text = 'MacMeter · 资源看板'
options = root.find('options')
if options is not None:
    options.set('customize', 'never')
domains = root.find('domains')
if domains is None:
    domains = ET.SubElement(root, 'domains')
domains.attrib.update(enable_anywhere='false', enable_currentUserHome='false', enable_localSystem='true')
ET.SubElement(root, 'welcome', {'file':'Welcome.html', 'mime-type':'text/html'})
ET.SubElement(root, 'conclusion', {'file':'Conclusion.html', 'mime-type':'text/html'})
for ref in root.findall('pkg-ref'):
    if ref.text and ref.text.strip():
        ref.text = 'MacMeter-component.pkg'
tree.write(path, encoding='utf-8', xml_declaration=True)
PY

PACKAGE_NAME="MacMeter-$VERSION-universal.pkg"
/usr/bin/productbuild --distribution "$STAGE_DIR/Distribution.xml" --package-path "$STAGE_DIR" \
    --resources "$PROJECT_DIR/packaging/resources" "$STAGE_DIR/product.pkg"
# Apple packaging tools record the builder's local account in XAR file ownership metadata.
# Re-create the unsigned archive in distribution mode; payload bytes and signatures stay intact.
mkdir "$STAGE_DIR/archive"
(cd "$STAGE_DIR/archive" && /usr/bin/xar -xf "$STAGE_DIR/product.pkg" && \
    /usr/bin/xar --distribution --compression=none -cf "$PACKAGE_DIR/$PACKAGE_NAME" Distribution Resources MacMeter-component.pkg)
(cd "$PACKAGE_DIR" && LC_ALL=C /usr/bin/shasum -a 256 "$PACKAGE_NAME" > "$PACKAGE_NAME.sha256")
python3 "$PROJECT_DIR/scripts/verify-package.py" "$PACKAGE_DIR/$PACKAGE_NAME"
echo "$PACKAGE_DIR/$PACKAGE_NAME"
