#!/usr/bin/env python3
"""Verify the public installer without installing or running its contents."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


def check(condition, description):
    if not condition:
        raise SystemExit('Installer verification failed: ' + description)


package = Path(sys.argv[1]).resolve()
project = Path(__file__).resolve().parent.parent
expected = plistlib.loads((project / 'Info.plist').read_bytes())
digest = hashlib.sha256(package.read_bytes()).hexdigest()
check(package.with_suffix('.pkg.sha256').read_text().split()[0] == digest, 'SHA-256 mismatch')

with tempfile.TemporaryDirectory(prefix='macmeter-audit-', dir=os.environ.get('RB_BUILD_DIR')) as directory:
    temporary = Path(directory)
    toc_path = temporary / 'toc.xml'
    subprocess.run(['/usr/bin/xar', '-f', str(package), '--dump-toc=' + str(toc_path)], check=True)
    toc = ET.parse(toc_path)
    check(all(not list(toc.iter(tag)) for tag in ['user', 'group', 'uid', 'gid']), 'local ownership metadata')
    expanded = temporary / 'expanded'
    subprocess.run(['/usr/sbin/pkgutil', '--expand-full', str(package), str(expanded)], check=True,
                   stdout=subprocess.DEVNULL)
    distribution = ET.parse(expanded / 'Distribution')
    check(distribution.find('.//os-version').get('min') == '13.0', 'minimum macOS version')
    architectures = set(distribution.find('options').get('hostArchitectures').split(','))
    check(architectures == {'arm64', 'x86_64'}, 'installer architectures')
    component = expanded / 'MacMeter-component.pkg'
    check(set(p.name for p in component.iterdir()) == {'Bom', 'PackageInfo', 'Payload'}, 'unexpected installer content')
    info = ET.parse(component / 'PackageInfo').getroot()
    check(info.get('install-location') == '/Applications' and info.get('relocatable') == 'false', 'installation destination')
    check(info.get('version') == expected['CFBundleShortVersionString'], 'package version')
    check(info.find('scripts') is None and not list(expanded.rglob('Scripts')), 'installer scripts')
    payload = component / 'Payload'
    check(set(p.name for p in payload.iterdir()) == {'资源看板.app'}, 'unexpected payload')
    app = payload / '资源看板.app'
    expected_files = {'Contents/Info.plist', 'Contents/MacOS/ResourceBoard',
                      'Contents/Resources/AppIcon.icns', 'Contents/_CodeSignature/CodeResources'}
    check({str(p.relative_to(app)) for p in app.rglob('*') if p.is_file()} == expected_files, 'unexpected application files')
    app_info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    check(app_info['CFBundleIdentifier'] == expected['CFBundleIdentifier'], 'bundle identifier')
    check(app_info['CFBundleShortVersionString'] == expected['CFBundleShortVersionString'], 'bundle version')
    executable = app / 'Contents/MacOS/ResourceBoard'
    subprocess.run(['/usr/bin/lipo', str(executable), '-verify_arch', 'x86_64', 'arm64'], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    owners = subprocess.check_output(['/usr/bin/lsbom', '-pug', str(component / 'Bom')], text=True)
    check(all(part == '0' for part in owners.split()), 'non-system payload ownership')
    private = re.compile(rb'/Users/|/home/|-----BEGIN [A-Z ]*PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}')
    for path in expanded.rglob('*'):
        if path.is_file():
            check(private.search(path.read_bytes()) is None, 'personal paths or secrets in ' + path.name)

print(json.dumps({'package': package.name, 'version': expected['CFBundleShortVersionString'],
                  'architectures': ['arm64', 'x86_64'], 'application_files': len(expected_files),
                  'installer_scripts': 0, 'local_ownership_metadata': False, 'sha256': digest}, ensure_ascii=False))
