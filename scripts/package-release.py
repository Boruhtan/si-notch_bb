#!/usr/bin/env python3
"""Create release assets and a signed update manifest from a verified build."""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, default=Path('build/si-notch.zip'))
    parser.add_argument('--dmg', type=Path, required=True)
    parser.add_argument('--notes', type=Path, required=True)
    parser.add_argument('--private-key', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(Path('release.json').read_text())
    version = config['version']
    pub = subprocess.check_output(['openssl', 'pkey', '-in', str(args.private_key), '-pubout', '-outform', 'DER'])
    if len(pub) != 44 or base64.b64encode(pub[-32:]).decode() != config['updatePublicKey']:
        parser.error('Signing key does not match release.json')
    with zipfile.ZipFile(args.archive) as archive:
        info = plistlib.loads(archive.read('si-notch.app/Contents/Info.plist'))
    if (info.get('SIReleaseVersion'), info.get('CFBundleVersion'), info.get('SIUpdatePublicKey')) != (version, config['build'], config['updatePublicKey']):
        parser.error('Build metadata does not match release.json')
    args.output.mkdir(parents=True, exist_ok=False)
    zip_name = f'si-notch-macos-arm64-{version}.zip'
    dmg_name = f'si-notch-macos-arm64-{version}.dmg'
    shutil.copyfile(args.archive, args.output / zip_name)
    shutil.copyfile(args.dmg, args.output / dmg_name)
    shutil.copyfile('LICENSE', args.output / 'LICENSE.txt')
    data = args.archive.read_bytes()
    feed = {'feedVersion': 1, 'releases': [{
        'version': version, 'bundleVersion': info['CFBundleShortVersionString'], 'bundleBuild': config['build'],
        'channel': 'beta' if '-' in version else 'stable', 'notes': args.notes.read_text(),
        'url': f'https://github.com/{config["repository"]}/releases/download/v{version}/{zip_name}',
        'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)
    }]}
    if config.get('pluginUpdates'):
        feed['releases'][0]['pluginUpdates'] = config['pluginUpdates']
    with tempfile.TemporaryDirectory(prefix='si-notch-feed-') as directory:
        unsigned = Path(directory) / 'unsigned.json'
        unsigned.write_text(json.dumps(feed))
        subprocess.run(['python3', 'scripts/release-manifest.py', '--feed', str(unsigned),
                        '--private-key', str(args.private_key), '--output', str(args.output / 'update.json')], check=True)
    lines = [f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}' for p in sorted(args.output.iterdir()) if p.is_file()]
    (args.output / 'SHA256SUMS').write_text('\n'.join(lines) + '\n')
    print(args.output)


if __name__ == '__main__':
    main()
