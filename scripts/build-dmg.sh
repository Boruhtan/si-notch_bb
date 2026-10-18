#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
archive="${1:-build/si-notch.zip}"
version="$(python3 -c 'import json; print(json.load(open("release.json"))["version"])')"
output="${2:-build/si-notch-macos-arm64-$version.dmg}"
[[ ! -e "$output" ]] || { echo "Output already exists: $output" >&2; exit 1; }
scratch="$(mktemp -d "${TMPDIR:-/tmp}/si-notch-dmg.XXXXXX")"
mounted=false
cleanup() {
  if [[ "$mounted" == true ]] && ! hdiutil detach "$scratch/verify" >/dev/null; then
    echo "Unable to detach verification image; retained at $scratch" >&2
    return 1
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT
mkdir -p "$scratch/image"
ditto -x -k "$archive" "$scratch/image"
codesign --verify --deep --strict "$scratch/image/si-notch.app"

# Disposable build tools; pinned wheels do not touch the user's Python install.
python3 -m venv "$scratch/venv"
"$scratch/venv/bin/python" -m pip --disable-pip-version-check --no-cache-dir install \
  --only-binary=:all: --require-hashes -r scripts/dmg-requirements.txt
python3 - "$scratch" "$PWD" <<'PY'
import json, sys
from pathlib import Path
scratch, root = map(Path, sys.argv[1:])
app = scratch / 'image/si-notch.app'
settings = {
    'title': 'si-notch', 'format': 'UDZO', 'compression-level': 9,
    'background': str(root / 'Assets/DMGBackground.png'),
    'icon': str(app / 'Contents/Resources/AppIcon.icns'),
    'icon-size': 108, 'text-size': 13,
    'window': {'position': {'x': 180, 'y': 140}, 'size': {'width': 680, 'height': 540}},
    'contents': [
        {'x': 170, 'y': 200, 'type': 'file', 'path': str(app)},
        {'x': 510, 'y': 200, 'type': 'link', 'path': '/Applications', 'name': 'Applications'}
    ]
}
(scratch / 'settings.json').write_text(json.dumps(settings))
PY
"$scratch/venv/bin/python" -m dmgbuild -s "$scratch/settings.json" 'si-notch' "$scratch/si-notch.dmg"
hdiutil verify "$scratch/si-notch.dmg"
mkdir "$scratch/verify"
hdiutil attach -readonly -nobrowse -mountpoint "$scratch/verify" "$scratch/si-notch.dmg" >/dev/null
mounted=true
codesign --verify --deep --strict "$scratch/verify/si-notch.app"
[[ -L "$scratch/verify/Applications" && "$(readlink "$scratch/verify/Applications")" == /Applications ]]
hdiutil detach "$scratch/verify" >/dev/null
mounted=false
mv "$scratch/si-notch.dmg" "$output"
printf '%s\n' "$output"
