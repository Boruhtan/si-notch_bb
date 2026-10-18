#!/usr/bin/env python3
"""Exercise the updater against disposable signed apps; requires a macOS GUI session."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time


def run(*args):
    return subprocess.run(args, check=True, capture_output=True)


def make_app(path, info, marker, text):
    executable = path / 'Contents/MacOS/fixture'
    executable.parent.mkdir(parents=True)
    (path / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    source = path.parent / (text + '.c')
    source.write_text('#include <stdio.h>\nint main(void) {'
                      f'FILE *f=fopen({json.dumps(str(marker))},"w");'
                      f'if(!f)return 1;fputs({json.dumps(text)},f);fclose(f);return 0;}}\n')
    run('xcrun', 'clang', str(source), '-o', str(executable))
    run('codesign', '--force', '--sign', '-', str(path))


def scenario(helper, config, corrupt):
    with tempfile.TemporaryDirectory(prefix='si-notch-update-smoke-') as temporary:
        root = Path(temporary).resolve()
        root.chmod(0o700)
        request_directory = root / 'si-notch-update-request'
        request_directory.mkdir(mode=0o700)
        destination = root / 'installed/si-notch.app'
        candidate = root / 'candidate/si-notch.app'
        marker = root / 'launched.txt'
        info = {'CFBundleIdentifier': 'io.github.eugeneb1ack.si-notch',
                'CFBundleExecutable': 'fixture', 'CFBundlePackageType': 'APPL',
                'CFBundleShortVersionString': '0.0.1', 'CFBundleVersion': '1',
                'SIReleaseVersion': '0.0.1', 'LSUIElement': True,
                'SIUpdateFeedURL': 'https://github.com/' + config['repository'] + '/releases/latest/download/update.json',
                'SIUpdatePublicKey': config['updatePublicKey'], 'SIUpdateRepository': config['repository']}
        make_app(destination, info, marker, 'old')
        updated = dict(info, CFBundleShortVersionString='0.0.2', CFBundleVersion='2', SIReleaseVersion='0.0.2')
        make_app(candidate, updated, marker, 'new')
        archive = request_directory / 'si-notch.zip'
        run('ditto', '-c', '-k', '--keepParent', '--norsrc', '--noextattr', str(candidate), str(archive))
        data = archive.read_bytes()
        release = {'version': '0.0.2', 'bundleVersion': '0.0.2', 'bundleBuild': '2',
                   'channel': 'stable', 'notes': '', 'url': 'https://example.invalid/si-notch.zip',
                   'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
        parent = subprocess.Popen(['/usr/bin/true'])
        parent.wait()
        receipt = {'destination': destination.as_uri(), 'archive': archive.as_uri(), 'release': release,
                   'originalVersion': '0.0.1', 'originalBuild': '1', 'parentPID': parent.pid,
                   'createdAt': time.time() - 978307200}
        request = request_directory / 'install.json'
        request.write_text(json.dumps(receipt))
        if corrupt:
            archive.write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
        result = subprocess.run([str(helper), '--install-update', str(request)], capture_output=True, timeout=40)
        assert result.returncode == (1 if corrupt else 0), result.stderr.decode()
        deadline = time.monotonic() + 10
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert marker.read_text() == ('old' if corrupt else 'new'), 'The expected app did not launch'
        assert plistlib.loads((destination / 'Contents/Info.plist').read_bytes())['CFBundleVersion'] == ('1' if corrupt else '2')
        assert (request_directory / 'install-error.txt').is_file() if corrupt else not request_directory.exists()
        assert not list(destination.parent.glob('.si-notch-install-*'))
        run('codesign', '--verify', '--deep', '--strict', str(destination))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    helper = args.app.resolve() / 'Contents/MacOS/si-notch'
    config = json.loads(Path('release.json').read_text())
    for corrupt in (False, True):
        scenario(helper, config, corrupt)
    print('Updater smoke: installed and launched the new app; rejected altered archive and relaunched the original app.')


if __name__ == '__main__':
    main()
