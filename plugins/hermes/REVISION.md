# Current revision

Plugin **1.12**, bundled with app **0.4.29**, corrects unsuccessful turn status, bounds the complete relay exchange by one deadline, preserves a buffered acknowledgement after a peer closes, and refuses stale-socket recovery when the holder check is incomplete.

Immutable runtime source: [`70fa311597d68a4f19de23e4c26eb39af7e6af46`](https://github.com/eugeneb1ack/si-notch/tree/70fa311597d68a4f19de23e4c26eb39af7e6af46/plugins/hermes). The native installer requires a full commit SHA, not a tag.

```sh
hermes plugins install eugeneb1ack/si-notch/plugins/hermes --ref 70fa311597d68a4f19de23e4c26eb39af7e6af46 --no-enable
```

Lifecycle, configuration preservation, deadlines and socket acknowledgement cases have isolated regression tests.

On 2026-10-23, app-managed setup updated eight already-enabled remote profiles and the shared relay from plugin 1.10 to 1.12. All 17 installed file hashes match the release sources; all 17 backups and the setup receipt were verified. Profile configurations and plugin settings remained byte-for-byte unchanged. The running gateway's `plugins.list` reported version 1.12, 15 hooks, enabled and no load error for every profile. All eight resumed presence in installed app 0.4.29. Plugin handlers were reloaded without restarting the gateway. No new model turn was submitted in this deployment check, so it does not add live turn or token-accounting coverage for 1.12.

A subsequent real API task on the same day completed two terminal calls with the expected markers and exit code 0. The installed app was observed showing Working, then Done, the final reply and a History row with a checkmark. Four unique model requests belonged to one completed task, without incomplete-data status. The saved usage matched the native per-model ledger: 74,232 input tokens (including 52,736 cached), 221 output tokens, 74,453 total. This includes 619 tokens for title generation in addition to the main run's 73,834. The task total was visible as 74.45K in both its card and History. Native automation disconnected while opening the separate Usage window, so its detailed screen was not visually verified. This check covers one real API turn in one profile, not every entry point or model.

Update the installed plugin separately; an app update does not replace a running remote plugin. The observer does not submit answers or approve tools.

| File | SHA-256 |
| --- | --- |
| `__init__.py` | `2094332e3b2b4c67434947296d86cbb95d1fc3aa522571c84d57aa90a86ca241` |
| `plugin.yaml` | `282b89089ffede7175c53389b0bb1f8d2de7a3ceca41979125cdde46f83cbe01` |
| `relay.py` | `b387d9f5b6d22bd3a76cf51f4b44a845c3bb67d5b2e13cf2866123f173a24728` |
| `configure.py` | `b003dd06592b7949887ac584fb39a9dd9ea8a60c059432a05ccbb0ccd484cc18` |

# Previous plugin 1.11 verification

Plugin **1.11**, bundled with app **0.4.27**, adds an opaque identity to human-input notifications. The app can distinguish a new question from an ordinary waiting status and show instructions for responding in the original chat or terminal. The observer does not approve actions or submit answers.

Immutable runtime source: [`38e50861b6601aaf0c5acffa839c38c2be525a3e`](https://github.com/eugeneb1ack/si-notch/tree/38e50861b6601aaf0c5acffa839c38c2be525a3e/plugins/hermes).

```sh
hermes plugins install eugeneb1ack/si-notch/plugins/hermes --ref 38e50861b6601aaf0c5acffa839c38c2be525a3e --no-enable
```

Lifecycle/privacy fixtures and the local application suite passed. Remote deployment and a live human-input roundtrip for this plugin revision have not been verified. Existing profile configuration and approval policies are unchanged; update the plugin separately through the existing installation flow.

| File | SHA-256 |
| --- | --- |
| `__init__.py` | `0ed6b838535a3b396ef1a60ed93f3c8676e6800daec156448007349f4bdfd883` |
| `plugin.yaml` | `95a543cbb7fa2fe353930a5461bea42fd1f6e21bb5ecae734a7481e01a809b40` |
| `relay.py` | `81a5abb7088c6c1ff9ca9b25f6cb4aa4e71ef19206b20092ae2dac994fb90d91` |
| `configure.py` | `eed5b0c81a73a8aefa33c2e7fb226539b6d98ac0ffeeb9db971e6bc273ce06f8` |

# Previous plugin 1.10 verification

Plugin **1.10** adds task attribution and a bounded private numeric outbox. Requests retain stable identity and the parent turn captured before a child call. The application acknowledges usage only after saving its journal; retries do not increase totals.

On 2026-10-22, app-managed setup updated all eight already-enabled remote profiles and the shared relay (17 files, zero profile configuration changes). All 17 backups and the setup receipt were verified; installed SHA-256 values match the bundled sources. Live `plugins.list` reports version 1.10, 15 hooks, enabled and no load error in every profile. All eight resumed presence in the installed application. No gateway restart was required. A subsequent real API task and one native child produced five requests whose token fields match the native per-model ledger, including title generation (89,816 tokens). Replaying each request three times through the remote relay left all counts unchanged. The queue/retry behavior, parent-turn isolation and durable acknowledgement were tested locally, including a real helper and Unix socket.

App release: **0.4.26**. Immutable runtime source: [`856b403c633c248ae14b0e80abd9339f637996cb`](https://github.com/eugeneb1ack/si-notch/tree/856b403c633c248ae14b0e80abd9339f637996cb/plugins/hermes).

```sh
hermes plugins install eugeneb1ack/si-notch/plugins/hermes --ref 856b403c633c248ae14b0e80abd9339f637996cb --no-enable
```

| File | SHA-256 |
| --- | --- |
| `__init__.py` | `8b932802293303b10488afc6a2248751fcceb23476483290916f6de1cc5ca9d6` |
| `plugin.yaml` | `2faa06d7b674f3a69c11fc9e0115b98c06e7b1d13de2df77d8e19b3ab05ef99d` |
| `relay.py` | `81a5abb7088c6c1ff9ca9b25f6cb4aa4e71ef19206b20092ae2dac994fb90d91` |
| `configure.py` | `eed5b0c81a73a8aefa33c2e7fb226539b6d98ac0ffeeb9db971e6bc273ce06f8` |

## Previous plugin 1.8 verification

Plugin version: **1.8**. App release: **0.4.15**.

Immutable runtime source: [`29ccd66be43adad63abff82a2112d5cc083fbed4`](https://github.com/eugeneb1ack/si-notch/commit/29ccd66be43adad63abff82a2112d5cc083fbed4).

```sh
hermes plugins install eugeneb1ack/si-notch/plugins/hermes --ref 29ccd66be43adad63abff82a2112d5cc083fbed4 --no-enable
```

The application bundles these runtime files. Plugin 1.8 adds profile heartbeats every 30 seconds, bound to Hermes native plugin unload. App-managed setup deploys it without changing profile identity, text sharing or configuration. Adapter lifecycle/privacy tests, the full app suite and a real Lane API task passed. Live presence recovered after restarting si-notch, remained separate from active work, and was delivered from all eight enabled profiles.

A finite live check observed fresh receipts from every enabled profile for more than three minutes. Interrupting only the application-owned SSH child changed transport to retrying and profile/task display to Last seen/unknown; it reconnected automatically in 2.65 seconds and a new Lane heartbeat arrived 15.73 seconds after interruption. The test API run returned SI_NOTCH_AGENT_OK, with the installed Agents view showing Lane working and then idle while still online. No gateway restart or profile configuration changes were required.

## Previous plugin 1.7 verification

Plugin version: **1.7**. App release: **0.4.11**.

Immutable runtime source: [`abb6ae74296be712cdba2d25ec7d623137746e5c`](https://github.com/eugeneb1ack/si-notch/tree/abb6ae74296be712cdba2d25ec7d623137746e5c/plugins/hermes).

```sh
hermes plugins install eugeneb1ack/si-notch/plugins/hermes --ref abb6ae74296be712cdba2d25ec7d623137746e5c --no-enable
```

This published revision bundles the runtime files listed below. On the tested remote macOS host, the previous 1.2-second plugin process deadline failed five of seven presence delivery probes with the running gateway's PATH. Plugin 1.7 runs the app-managed Python relay with Hermes' current interpreter and allows 2.5 seconds for startup and bounded delivery. The same seven probes all succeeded in 0.82–1.02 seconds after the fix. Disconnection still fails open with a five-second retry backoff.

The app setup protocol updated only the observer source and manifest in eight already-enabled profiles. The remote receipt verified that unrelated configuration remained unchanged. Some reload acknowledgements exceeded the native timeout; a subsequent read of the running gateway's `plugins.list` confirmed version 1.7, 13 hooks and no load error in every selected profile. Profile discovery and identity handling also have regression cases for a single default profile and three profiles with arbitrary names.

| File | SHA-256 |
| --- | --- |
| `__init__.py` | `3986d2bfce069e041cbae033639799c1cb57478e53b6ae338dba8424fe097cd6` |
| `plugin.yaml` | `04600584c52f108d5958b008ae7866ccbd407fa37f873b7de1ba463a5f16527e` |
| `relay.py` | `96939a4aca0e194207fdbd9fc6a24e99c9a0222fbd1a223a5cfc71958da5e3f2` |
| `configure.py` | `eed5b0c81a73a8aefa33c2e7fb226539b6d98ac0ffeeb9db971e6bc273ce06f8` |

Real API sessions on Hermes 0.22.2 were checked in the installed application: the parent displayed `gpt-6.1-sol` and `medium`, two task titles and progress, its actual session project and tool history. Its native child displayed `gpt-6-luna` and `medium`; the persisted terminal result had exit code 0 and the requested marker, and the child returned 323. A live run exposed premature child termination when the parent finished a turn; reducer regression coverage now preserves background activity until the child's own completion, with explicit session termination, stale expiry and retention checks.

All six Display detail switches have native bitmap checks, alongside reducer, helper/socket and adapter regression coverage. Request bodies, reasoning text, child goals/summaries and unrelated tool content are excluded. Task titles follow the profile text-sharing preference.

The native Hermes installer handler was previously verified with the same package layout in an empty temporary profile, including update-in-place and settings preservation. The full CLI bootstrap in a fresh data root timed out while preparing its Python environment; that limitation is not an installation success claim.

Other Hermes versions, platforms and entry points require their own live verification. Actual metadata is shown only when supplied by the runtime.
