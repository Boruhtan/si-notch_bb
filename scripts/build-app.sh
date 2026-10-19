#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [[ "$configuration" != release && "$configuration" != debug ]]; then
  echo 'Usage: scripts/build-app.sh [release|debug]' >&2
  exit 2
fi
scratch="$(mktemp -d "${TMPDIR:-/tmp}/si-notch-build.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
export CLANG_MODULE_CACHE_PATH="$scratch/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$scratch/modules"
build_args=(--disable-sandbox --cache-path "$scratch/cache" --scratch-path "$scratch/work" -c "$configuration")
swift build "${build_args[@]}"
bindir="$(swift build "${build_args[@]}" --show-bin-path)"
app="$scratch/si-notch.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bindir/si-notch" "$app/Contents/MacOS/si-notch"
cp "$bindir/si-notchctl" "$app/Contents/Helpers/si-notchctl"
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
mkdir -p "$app/Contents/Resources/adapters"
cp scripts/adapters/*.js scripts/adapters/package.json "$app/Contents/Resources/adapters/"
if [[ -d plugins/hermes ]]; then
  mkdir -p "$app/Contents/Resources/adapters/hermes-si-notch"
  cp plugins/hermes/__init__.py plugins/hermes/plugin.yaml plugins/hermes/relay.py plugins/hermes/configure.py "$app/Contents/Resources/adapters/hermes-si-notch/"
fi
if [[ -f scripts/adapters/codex-hook.py ]]; then cp scripts/adapters/codex-hook.py "$app/Contents/Resources/adapters/"; fi
if [[ -f scripts/adapters/harness-hook.py ]]; then cp scripts/adapters/harness-hook.py "$app/Contents/Resources/adapters/"; fi
cp scripts/remote-hermes-setup.py "$app/Contents/Resources/adapters/"
cp scripts/remote-socket-recovery.py "$app/Contents/Resources/adapters/"
if [[ -f plugins/hermes/relay.py ]]; then cp plugins/hermes/relay.py "$app/Contents/Resources/adapters/remote-relay.py"; fi
if [[ -f scripts/claude-permission.py ]]; then cp scripts/claude-permission.py "$app/Contents/Resources/adapters/claude-permission.py"; fi
iconset="$scratch/AppIcon.iconset"
mkdir -p "$iconset"
swift -module-cache-path "$scratch/icon-modules" scripts/render-icon.swift "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
for resources in "$bindir"/*SINotch.bundle; do
  [[ -d "$resources" ]] || continue
  ditto --norsrc --noextattr "$resources" "$app/Contents/Resources/$(basename "$resources")"
done
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>si-notch</string>
<key>CFBundleDisplayName</key><string>si-notch</string>
<key>CFBundleIdentifier</key><string>io.github.eugeneb1ack.si-notch</string>
<key>CFBundleExecutable</key><string>si-notch</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ru</string><string>zh-Hans</string></array>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundleVersion</key><string>24</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 dis/root · https://disroot.website/</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 - "$app/Contents/Info.plist" <<'PYCONFIG'
import json, plistlib, sys
from pathlib import Path
config = json.loads(Path('release.json').read_text())
path = Path(sys.argv[1])
info = plistlib.loads(path.read_bytes())
info.update(CFBundleShortVersionString=config['version'].split('-')[0], CFBundleVersion=config['build'],
            SIReleaseVersion=config['version'], SIUpdateRepository=config['repository'],
            SIUpdateFeedURL='https://github.com/' + config['repository'] + '/releases/latest/download/update.json',
            SIUpdatePublicKey=config['updatePublicKey'])
path.write_bytes(plistlib.dumps(info))
PYCONFIG
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
mkdir -p "$PWD/build"
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$app" "$PWD/build/si-notch.zip"
mkdir -p "$scratch/archive-check"
ditto -x -k "$PWD/build/si-notch.zip" "$scratch/archive-check"
codesign --verify --deep --strict "$scratch/archive-check/si-notch.app"
if [[ -e "$PWD/build/si-notch.app" ]]; then mv "$PWD/build/si-notch.app" "$scratch/previous-app"; fi
ditto --norsrc --noextattr --noqtn "$app" "$PWD/build/si-notch.app"
# Finder/Cloud Documents can attach presentation metadata to a newly copied
# bundle. It is our generated output; none of its signatures live in xattrs.
xattr -cr "$PWD/build/si-notch.app"
# Cloud-backed Documents may immediately reattach FinderInfo and invalidate a
# copied bundle. The archive above was independently extracted and verified.
# Never leave or advertise an invalid app copy as the distribution artifact.
if codesign --verify --deep --strict "$PWD/build/si-notch.app"; then
  printf '%s\n' "$PWD/build/si-notch.app"
else
  mv "$PWD/build/si-notch.app" "$scratch/metadata-affected-app"
  echo 'Folder metadata affected the app copy; use the verified ZIP with scripts/install-app.sh.' >&2
fi
(cd build && shasum -a 256 si-notch.zip > SHA256SUMS)
printf '%s\n' "$PWD/build/si-notch.zip"
