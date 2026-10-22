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

Add `--qa-screens-only` to move an isolated fixture across all connected displays, export compact/expanded views and the menu icon, check menu clearance, and trace the external capsule's top-right anchor. It returns to automatic screen selection afterward. With `--qa-preview-screen DISPLAY_ID`, a successful run leaves a clickable/hoverable preview on that display for five minutes, then exits. The preview has no agent services, IPC server or global shortcut and does not persist its display preferences. Its task card is a fixture. This does not simulate physically closing the lid or replace a fullscreen/hover test on hardware.

Add `--qa-motion-only` for geometry sampling without bitmap capture. Opening uses one critically damped 280 ms response for both dimensions (240 ms closing); content opacity and the outline follow that same geometry, without a separate delayed content transition. During the transition the window display link requests the selected screen's maximum rate, capped at 120 Hz, then stops when settled. Checks cover the fixed top edge, final bounds, repeated layout and fast reversal. Each motion trace also records actual display-link callback timestamps, target timestamps and frame-setting cost. Inspect their intervals independently of the 120 Hz geometry sampler: neither callback timing nor geometry sampling establishes presented compositor FPS. Bitmap capture can perturb both.

For pointer entry, stop just below the compact island: even half a point outside its drawn contour must not arm hover. Transparent shoulders and rounded corners are excluded using the same silhouette as the view. Move onto the surface and pause for at least 180 ms, allowing 4 points of jitter; longer configured delays apply from every direction. Continuous movement and dragging a window through the notch must not open it. Motion events reset dwell between timer samples, and the timer rechecks the active contour before opening. Leaving cancels pending intent; resizing or showing the panel under a stationary pointer cannot manufacture an entry. Collapse immediately restores the compact target, with a 250 ms exit delay and the existing reentry protection. Fullscreen reveal is limited to the physical cutout, or the top 3 points directly above the right-aligned capsule on a display without a cutout. Clicks and shortcuts open immediately. Opening Settings collapses the island silently, while explicit panel closing retains its sound.

Check each remote group in Agents, both opening and closing it, then switch back to Sessions. The panel follows the visible fixed-height rows; scrolling begins only at the configured or display height limit. Expand/collapse session details and the task prompt, change filters/search, and check permission cards arriving and clearing. Card and group layout must not run a second geometry animation alongside the outer window. The open panel's shoulders and content opacity must stay stable during height-only changes: reveal progress follows width, independently of the changing content height. Dirty layout and drawing finish in the display-link turn instead of being deferred to a separate AppKit update.

For native permission routing, compare real turns with `approvals_reviewer=user` and `auto_review`. Only a correlated manual-review turn may create a native request. Automatic review, noninteractive permission modes, missing transcripts, mismatched session/turn IDs and unknown metadata must return no hook decision, without showing a request. Never infer approval from the absence of a native card.

For fullscreen, check a native fullscreen window and a fullscreen video player separately. The island should disappear even if already expanded, remain quiet for incoming requests, open after a deliberate hover at the camera or the external capsule's top-edge target, and hide after pointer exit or an outside click. Check the keyboard shortcut and restoration after leaving fullscreen. A pointer parked at the camera before entering fullscreen must leave and return before opening. Repeat on each intended display, with the menu bar visible and hidden, and with Reduce Motion enabled.

The implementation uses Apple's [system presentation options](https://developer.apple.com/documentation/appkit/nsapplication/currentsystempresentationoptions), public window bounds for players that do not set fullscreen flags, [SwiftUI Spring](https://developer.apple.com/documentation/swiftui/spring), and a [window display link](https://developer.apple.com/documentation/appkit/nswindow/displaylink(target:selector:)). Window titles and screen pixels are not read by the detector. Hover-to-open and hiding in fullscreen are also established options in [Droppy](https://getdroppy.app/docs/notch).

Static captures do not measure animation smoothness or compositor frame rate. Check hover activation, dismissal, Mission Control, fullscreen apps and display changes manually. Play sound previews through the intended audio output.

Add `--qa-interaction-only` to check native tracking below the edge, transparent shoulders, dragging, brief contact, continuous crossing, deliberate dwell, panel geometry and the Settings audio sink without posting input to the desktop. Add `--qa-service-only` to render the two observed memory-job signatures beside an ordinary task in all three languages. These controlled fixtures do not establish subjective hover feel on physical hardware.

For SSH reconnection, keep a saved remote connection enabled and interrupt only the SSH child owned by the installed app. Verify that Settings returns to Connected without clicking Connect, a replacement tunnel has the same app parent, and profile presence resumes within a heartbeat interval. Repeat more than three times. Separately exercise a prolonged network outage and sleep/wake on hardware; local fake-SSH regressions cover retry exhaustion and backoff reset but do not establish those physical-network results. Explicit Disconnect must cancel pending retries. Authentication, host-key and unsafe socket errors must stop rather than modifying SSH trust or socket ownership.

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

Add `--qa-history-only` to render History list, detail and settings in three languages. It uses an exclusive temporary archive before agent services start, verifies persistence after Done clearing and store reopening, and clears only that fixture archive. It never reads or clears the user’s production History folder.

## Token usage

`TokenUsageTests` covers response/legacy mirrors, repeated cumulative totals, resumed counters, copied parent history, Pi cache buckets, private numeric persistence, partial tails and replay after restart. `CodexQuotaControllerTests` covers automatic startup, cached hydration, failed refreshes and signed-out clearing. Hermes adapter tests check normalized numeric fields, stable request identity and the child-to-session link.

Use `--qa-usage-only` with `--qa-export` to render the Usage overview and a parent/child detail in English, Russian and Simplified Chinese using private fixtures. This never starts the production IPC server or changes agent configuration.

An optional read-only local scan is available with `SI_NOTCH_USAGE_LIVE_CHECK=1` and `swift test --filter TokenUsageTests.testLiveReadOnlyUsageScanWhenRequested`. It stores its temporary numeric journal outside the real application data and removes it after checking. Actual source directories are read only.

The ledger is `Application Support/si-notch/Usage/tokens.json` (private directory and file, atomic replacement). It contains numeric counters and session metadata, not transcript bodies. It persists separately from text History and completed cards. First-time indexing is bounded and progressive; warm scans resume from saved offsets. A legacy counter decrease without an owned request is marked partial rather than counted as another request. Current Codex owned records use `thread_id`, not the root execution `session_id`. Subset counters are included in input/output totals, never added again.

Local validation on 2026-10-22: the complete `scripts/test.sh`, release packaging and `scripts/verify-release.sh` passed. The installed executable matches the release package. The running app populated the quota cache without opening Usage and persisted 197 local session records, including 69 child records, with mode 0600. Six release-bundle native Usage captures passed. These capture fixtures are not user-account measurements. Interactive click verification was interrupted by the computer-use service disconnect.

After explicit approval, remote plugin 1.9 was deployed to all eight enabled profiles: only 16 observer/manifest files changed, with zero profile configuration changes. All file hashes, backup files and the setup receipt were read back. Live `plugins.list` returned version 1.9, 15 hooks and no error for all eight; presence reached the installed app. No gateway restart or agent task was submitted. Real request-token delivery remains unverified because no new Hermes model request occurred during the check.


## Task token accounting (local development, 2026-10-22)

The v2 numeric journal keeps immutable request identities separately from task grouping. Codex uses owner thread, response ID and explicit root turn; Pi follows message parent links; Hermes uses request ID and the parent turn captured before each child call. Cache reads/writes are input subsets and reasoning is an output subset. Grouping and undo do not mutate numeric facts. Unknown usage remains unknown; orphaned or legacy data remains visible and marked incomplete.

A private copy of the existing journal migrated all 205 saved sessions. 204 totals were unchanged; one active Codex session gained new source records during the scan. The original v1 bytes were retained as a private backup. Cold rebuilding 4.7 GB of source logs took 55.4 seconds in the debug audit. The resulting numeric journal was 4,886,007 bytes. No prompt/response text was copied by this audit.

An independent Python calculation read exactly the file prefixes committed by the Swift importer: 198 files, 6,335 Codex requests and 1,824 Pi requests. It compared input, output, available cache/reasoning fields and turn identity for every request, with zero differences. This includes 1,673 requests in 70 child sessions. All 6,335 Codex root-turn links matched their source records. Summing disjoint tasks and unassigned records equals the session input/output totals. These are a bounded local snapshot, not a claim about all provider versions or billing.

Regression cases cover late/reused/nested children, Pi branches across metadata nodes, model changes, duplicate and conflicting deliveries, grouping/undo/restart, v1 correction with deleted-source retention, unknown versus zero, invalid subset values, storage limits and commit-before-ACK. Hermes's private numeric outbox retries until a durable commit acknowledgement, with a bounded capacity and explicit incompleteness after overflow. Queue retry and a real local helper/socket acknowledgement contract are tested without invoking a model.

Task list, task detail and narrow content layouts are rendered in English, Russian and Simplified Chinese using isolated fixtures. Cache explanations, zero/unknown values and partial data have native bitmap fixtures. These captures do not establish physical VoiceOver behavior or actual pointer navigation in the installed application. Remote model-generated token delivery is not established by local fixture tests.


The final local build passed `scripts/test.sh` (438 Swift tests across three bundles, two opt-in checks skipped in the default run; nine Node and 73 Python tests), `scripts/build-app.sh release` and `scripts/verify-release.sh`. The opt-in migration audit was run separately. Fifteen native bitmap captures were rendered from the packaged app; representative list, detail, narrow and zero/unknown states were inspected across all three locales. The final small UI additions compiled in the release and were exercised by those captures.

The release was installed at `~/Applications/si-notch.app`; its executable matches the packaged binary. Before replacement, History and Usage were copied to a private dated Application Support backup with SHA-256 manifests. All 107 original History files remain: 105 are byte-identical; the active entry only appended new items, and its index was refreshed. Migration reached schema 2 with no legacy fallback files left. Hermes 1.10 was installed and loaded in all eight existing profiles, with 17 file backups verified and zero configuration changes; all profiles report online. Actual UI pointer/VoiceOver testing was blocked by the computer-use service (`cgWindowNotFound`, then native pipe closed). This is not a successful interactive UI check.


A second read-only audit copied the installed v2 journal after migration: 206 session records, 395 task records and 8,201 requests. Task/session input-output conservation passed; replaying the source tails took 0.52 seconds in the debug audit. The independent source-prefix comparison again found zero differences. An eight-second sample after migration measured 3.0% of one CPU core while a Codex task remained active; this is not a whole-Mac or idle benchmark.


The independent check is reproducible without altering the journal or sources:

```sh
python3 scripts/audit-token-usage.py /private/path/to/tokens.json
```

Use a private snapshot from the current v2 journal; the script verifies source inode/size and reads only committed prefixes. Source rotation after the snapshot is an explicit error, not a zero total.

### Real remote parent/child usage (2026-10-22)

One native API task dispatched exactly one real background child. The child finished the sum-of-squares task with 2,870; its transcript contains one arithmetic-only `execute_code` call, despite the requested no-tools constraint. No file, network, configuration or messaging action appears in the bounded test trace. The API parent returned the background-dispatch status; this check does not claim the API delivered a subsequent final parent response.

Independent read-only native `session_model_usage` rows match all five local immutable request records: parent 50,251 input / 299 output (including 493 / 73 for title generation), child 39,168 / 98. Combined total: 89,816, with 51,456 cache-read tokens already included in input, zero cache writes, and 85 reasoning tokens already included in output. Native session aggregates omit auxiliary calls; the per-model ledger includes them. Parent/child IDs and the original parent turn also match. All records are complete and the remote numeric outbox is empty.

Every request was replayed three times through the installed remote relay and existing SSH forward. All 15 responses were `usage_committed`; the five records, both session totals and completeness flags were unchanged. The same numeric trace is a regression fixture for task grouping, auxiliary usage, replay and journal reopening. This establishes the tested Hermes build and entry point; other provider versions and remote historical usage remain outside this check.

### Stable 0.4.26 validation

Local gates passed: 442 Swift tests (two private-data opt-in skips), 76 Python tests, nine Node adapter tests, and 670 matching localization keys. The release ZIP, bundle seal, version/build and DMG integrity were verified. Native backing-view captures of plugin announcements were inspected in English, Russian and Simplified Chinese. Signed-feed tests cover legacy compatibility, invalid installation links, duplicate plugin IDs, channel isolation and links retained after updating the app.

The installed 0.4.26/build 53 executable matches the packaged build. Before replacement, all 110 History files and the numeric journal were backed up. After restart, 108 History files are byte-identical; the active conversation appended items and the index refreshed without losing previous entries. All five real Hermes requests and both session totals remain unchanged. IPC reports a connected SSH transport and all eight existing Hermes profiles online. Interactive computer-use testing reached the native app menu, then failed with `Sky Computer Use native pipe closed before response`; it does not establish successful pointer navigation or VoiceOver behavior.
