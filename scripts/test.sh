#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="$(mktemp -d "${TMPDIR:-/tmp}/si-notch-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
export CLANG_MODULE_CACHE_PATH="$scratch/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$scratch/modules"
swift test --disable-sandbox --cache-path "$scratch/cache" --scratch-path "$scratch/work"
python3 scripts/integrations.py --help >/dev/null
python3 -m py_compile scripts/integrations.py scripts/smoke-ipc.py scripts/smoke-cli.py

python3 scripts/check-localizations.py

bindir="$(swift build --disable-sandbox --cache-path "$scratch/cache" --scratch-path "$scratch/work" --show-bin-path)"
python3 scripts/smoke-cli.py --helper "$bindir/si-notchctl"

node --test Tests/adapters/adapters.test.mjs
if [[ -f Tests/adapters/test_claude_permission.py ]]; then SI_NOTCH_HELPER="$bindir/si-notchctl" python3 -m unittest discover -s Tests/adapters -p "test_*.py"; fi
python3 -m unittest discover -s docs/examples/custom-agent -p "test_*.py"
