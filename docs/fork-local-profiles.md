# Local Hermes profiles in si-notch_bb

The fork keeps configured local Hermes profiles visible even when they are not running.
The inventory reads only `plugins/si-notch/si-notch.json` in the default Hermes home and
its `profiles/*` directories. It refreshes at startup and every five seconds.

Each profile must have its own stable `instanceId` and `displayName`. The connection ID
uses the same SHA-256 derivation as the Hermes observer. Symlinked, oversized, malformed,
wrong-socket and duplicate-identity settings do not establish a local profile identity.

An inventory entry starts as **Installed**, with unknown activity and no tasks. Only fresh
events received from the native local helper establish online presence. A profile's
heartbeat cannot refresh another profile. Named tasks and subagents retain their profile
identity. Saved SSH ownership takes precedence over an accidentally cloned local ID.
Independent unscoped work remains a separate row.

## Configure existing profiles

Run with the Python environment already used by Hermes:

```sh
~/.hermes/hermes-agent/venv/bin/python scripts/install-local-hermes-profiles.py
~/.hermes/hermes-agent/venv/bin/python scripts/install-local-hermes-profiles.py --apply
```

The first command previews the profile list. Apply copies the bundled observer, retains
existing observer settings and identities, assigns distinct IDs to new profiles, and
uses `hermes [-p PROFILE] plugins enable si-notch` to enable each copy. Existing profile
configuration and observer directories are backed up under `~/.local/share/si-notch/backups`.
Pending usage prevents changing a cloned identity. Credentials and history are not copied.
Restart an existing Hermes session to load updated plugin code; new sessions load it normally.

## Fork updates and builds

`release.json` sets `updatesDisabled: true`. Packaging embeds `SIUpdatesDisabled`, the
source repository and Git commit in Info.plist. This disables background checks, manual
feed checks/downloads and the updater install entry point. The settings page explains
that fork builds are installed manually. Changing a user preference cannot bypass the
bundle policy.

Build normally with `scripts/build-app.sh release`. With Command Line Tools, an explicit
`SI_NOTCH_BUILD_SYSTEM=native` override is supported. If icon rendering is unavailable,
`SI_NOTCH_ICON_SOURCE=/absolute/path/AppIcon.icns` uses an explicitly selected existing
icon; executables and resources are still rebuilt. These overrides do not alter dependencies.

Run `scripts/test.sh` with Xcode for the complete XCTest suite. Regression tests cover
inventory, profile freshness/tasks, local/remote collisions, installer backups and updater
policy. Local fallback contract runs must be reported separately from full XCTest results.
