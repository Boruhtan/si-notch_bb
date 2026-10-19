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

Add `--qa-display-only` to check session-only visibility through the native panel and export the Display settings in all three languages, including the full scroll content. This mode does not start agent services.

Add `--qa-motion-only` for geometry sampling without bitmap capture. Opening uses one critically damped 280 ms response for both dimensions (240 ms closing); content opacity and the outline follow that same geometry, without a separate delayed content transition. During the transition the window display link requests the selected screen's maximum rate, capped at 120 Hz, then stops when settled. Checks cover the fixed top edge, final bounds, repeated layout and fast reversal. Each motion trace also records actual display-link callback timestamps, target timestamps and frame-setting cost. Inspect their intervals independently of the 120 Hz geometry sampler: neither callback timing nor geometry sampling establishes presented compositor FPS. Bitmap capture can perturb both.

For pointer entry, approach the compact island from below and pause with the cursor still visible below its edge. The click-through approach strip extends 20 points below the visible panel (and the physical camera while hidden in fullscreen). The default dwell is 60 ms; a user-configured delay is preserved. Neither the approach strip nor the fullscreen reveal region creates an extra window or intercepts content clicks.

Check each remote group in Agents, both opening and closing it, then switch back to Sessions. The panel follows the visible fixed-height rows; scrolling begins only at the configured or display height limit. Expand/collapse session details and the task prompt, change filters/search, and check permission cards arriving and clearing. Card and group layout must not run a second geometry animation alongside the outer window.

For native permission routing, compare real turns with `approvals_reviewer=user` and `auto_review`. Only a correlated manual-review turn may create a native request. Automatic review, noninteractive permission modes, missing transcripts, mismatched session/turn IDs and unknown metadata must return no hook decision, without showing a request. Never infer approval from the absence of a native card.

For fullscreen, check a native fullscreen window and a fullscreen video player separately. The island should disappear even if already expanded, remain quiet for incoming requests, open after a deliberate hover at the camera/top center, and hide after pointer exit or an outside click. Check the keyboard shortcut and restoration after leaving fullscreen. A pointer parked at the camera before entering fullscreen must leave and return before opening. Repeat on each intended display, with the menu bar visible and hidden, and with Reduce Motion enabled.

The implementation uses Apple's [system presentation options](https://developer.apple.com/documentation/appkit/nsapplication/currentsystempresentationoptions), public window bounds for players that do not set fullscreen flags, [SwiftUI Spring](https://developer.apple.com/documentation/swiftui/spring), and a [window display link](https://developer.apple.com/documentation/appkit/nswindow/displaylink(target:selector:)). Window titles and screen pixels are not read by the detector. Hover-to-open and hiding in fullscreen are also established options in [Droppy](https://getdroppy.app/docs/notch).

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
