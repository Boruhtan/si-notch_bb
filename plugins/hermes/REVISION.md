# Tested revision

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
