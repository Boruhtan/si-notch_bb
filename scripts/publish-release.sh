#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 2 ]] || { echo 'Usage: scripts/publish-release.sh ASSETS_DIRECTORY NOTES_FILE' >&2; exit 2; }
assets="$1"
notes="$2"
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit source changes before publishing.' >&2; exit 1; }
version="$(python3 -c 'import json; print(json.load(open("release.json"))["version"])')"
repository="$(python3 -c 'import json; print(json.load(open("release.json"))["repository"])')"
commit="$(git rev-parse HEAD)"
for name in "si-notch-macos-arm64-$version.dmg" "si-notch-macos-arm64-$version.zip" update.json LICENSE.txt SHA256SUMS; do
  [[ -f "$assets/$name" ]] || { echo "Missing asset: $name" >&2; exit 1; }
done
(cd "$assets" && shasum -a 256 -c SHA256SUMS)
flags=(--latest)
[[ "$version" != *-* ]] || flags=(--prerelease --latest=false)
gh release create "v$version" \
  "$assets/si-notch-macos-arm64-$version.dmg" \
  "$assets/si-notch-macos-arm64-$version.zip" \
  "$assets/update.json" "$assets/LICENSE.txt" "$assets/SHA256SUMS" \
  --repo "$repository" --target "$commit" --title "si-notch $version" \
  --notes-file "$notes" "${flags[@]}"
