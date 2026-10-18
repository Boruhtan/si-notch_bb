#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination="$HOME/Applications/si-notch.app"
replace="${1:-}"
if [[ -n "$replace" && "$replace" != --replace ]]; then
  echo 'Usage: scripts/install-app.sh [--replace]' >&2
  exit 2
fi
if [[ ! -f build/si-notch.zip ]]; then
  echo 'Build first: scripts/build-app.sh release' >&2
  exit 1
fi
if pgrep -x si-notch >/dev/null; then
  echo 'Quit the running si-notch before installing. Replacing its file does not restart the old process.' >&2
  exit 1
else
  probe_status=$?
  if [[ "$probe_status" -ne 1 ]]; then
    echo 'Unable to verify whether si-notch is running; installation stopped.' >&2
    exit 1
  fi
fi
staging="$(mktemp -d "${TMPDIR:-/tmp}/si-notch-install.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto -x -k build/si-notch.zip "$staging"
codesign --verify --deep --strict "$staging/si-notch.app"
candidate_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$staging/si-notch.app/Contents/Info.plist")
if [[ "$candidate_id" != io.github.eugeneb1ack.si-notch ]]; then
  echo 'Refusing to install a different application.' >&2
  exit 1
fi
backup=""
if [[ -e "$destination" || -L "$destination" ]]; then
  if [[ "$replace" != --replace || -L "$destination" ]]; then
    echo "Already exists: $destination. Quit si-notch, then use --replace to retain a dated backup." >&2
    exit 1
  fi
  identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")
  if [[ "$identifier" != io.github.eugeneb1ack.si-notch ]]; then
    echo 'Refusing to replace a different application.' >&2
    exit 1
  fi
  # A backup must not be another launchable .app with the same bundle identifier.
  backup="$HOME/Applications/si-notch-backup-$(date +%Y%m%d-%H%M%S).backup"
  if [[ -e "$backup" ]]; then echo "Backup already exists: $backup" >&2; exit 1; fi
  mv "$destination" "$backup"
fi
mkdir -p "$HOME/Applications"
mv "$staging/si-notch.app" "$destination"
if ! codesign --verify --deep --strict "$destination"; then
  echo "Signature check failed. Previous application retained at: $backup" >&2
  exit 1
fi
registry=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -x "$registry" ]]; then "$registry" -f "$destination"; fi
printf '%s\n' "$destination"
if [[ -n "$backup" ]]; then printf 'Previous build: %s\n' "$backup"; fi
