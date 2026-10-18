[English](verification.md) · [Русский](ru/verification.md) · [简体中文](zh-CN/verification.md)

# Testing

Run the checks from the repository root on macOS with Xcode 26+, Python 3 and Node.js.

## Automated checks

```sh
scripts/test.sh
scripts/build-app.sh release
scripts/verify-release.sh
```

The test script runs Swift tests, localization checks, CLI smoke tests and JavaScript/Python adapter tests. Build verification checks the ZIP inventory and the extracted app's code signature. [GitHub Actions](../.github/workflows/ci.yml) also builds the DMG.

## Interface checks

Extract the ZIP into a temporary directory and run the UI exporter in a macOS GUI session:

```sh
si_notch_check_dir="$(mktemp -d /tmp/si-notch-check.XXXXXX)"
ditto -x -k build/si-notch.zip "$si_notch_check_dir"
"$si_notch_check_dir/si-notch.app/Contents/MacOS/si-notch" --qa-export "$si_notch_check_dir/qa"
```

The exporter checks window geometry, layout, session states, transparency and IPC. It saves a report, screenshots and audio samples in the output directory. Review the screenshots in all three languages and inspect companion states at both display scales.

Static captures do not measure animation smoothness or compositor frame rate. Check hover activation, dismissal, Mission Control, fullscreen apps and display changes manually. Play sound previews through the intended audio output.

## Update installation

Using the extracted app above, run:

```sh
python3 scripts/smoke-update.py "$si_notch_check_dir/si-notch.app"
```

This check requires a macOS GUI session. It creates disposable signed apps, exercises replacement, launch and rollback, and rejects an altered archive.

## Release files

```sh
scripts/build-dmg.sh
```

Open the DMG and check the app and Applications shortcut. Verify downloaded assets against the release's `SHA256SUMS`.

For integration coverage and known limitations, see [feature status](parity.md). For signed release packaging, see [updates](updates.md#publish-a-release).
