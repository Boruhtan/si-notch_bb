#!/bin/bash
set -euo pipefail
archive="${1:-build/si-notch.zip}"
python3 - "$archive" <<'PY'
import sys, zipfile
from pathlib import PurePosixPath
with zipfile.ZipFile(sys.argv[1]) as z:
    names = z.namelist()
    assert names, 'Empty archive'
    for name in names:
        p=PurePosixPath(name)
        assert not p.is_absolute() and '..' not in p.parts, f'Unsafe path: {name}'
        assert p.parts[0]=='si-notch.app', f'Unexpected root: {name}'
        assert not any(part.endswith('.app') for part in p.parts[1:]), f'Unexpected nested app: {name}'
        assert '.codex' not in p.parts and '.git' not in p.parts, f'Unexpected contents: {name}'
    print(f'Archive inventory: {len(names)} entries, one app bundle')
PY
scratch="$(mktemp -d "${TMPDIR:-/tmp}/si-notch-release-check.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
ditto -x -k "$archive" "$scratch"
app="$scratch/si-notch.app"
codesign --verify --deep --strict "$app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist"
file "$app/Contents/MacOS/si-notch" "$app/Contents/Helpers/si-notchctl"
python3 - "$app/Contents/Resources" <<'PY'
import subprocess, sys
from pathlib import Path
catalogs = list(Path(sys.argv[1]).rglob('Localizable.strings'))
for locale in ('en', 'ru', 'zh-Hans'):
    matches = [p for p in catalogs if p.parent.name.casefold() == locale.casefold() + '.lproj']
    assert len(matches) == 1, f'Missing or ambiguous locale: {locale}'
    subprocess.run(['plutil', '-lint', str(matches[0])], check=True)
PY
shasum -a 256 "$archive"
printf '%s\n' 'Archive and ad-hoc signature verified. Not notarized. Runtime/UI checks are separate.'
