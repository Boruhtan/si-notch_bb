# Tested revision

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
