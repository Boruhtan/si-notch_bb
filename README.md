https://github.com/user-attachments/assets/52cdd435-e6e2-4eb0-9136-d9001ee9d0f5

[English](README.md) · [Русский](README.ru.md) · [简体中文](README.zh-CN.md)

# si-notch

AI agent tasks in your Mac’s notch.

## Features

- Separate views for sessions and agent availability.
- Live status, messages, tools and subagents, with distinct agent colors.
- Animated companions and optional notification sounds.
- Codex, Pi, Claude Code, OpenCode, Hermes, Gemini CLI, Copilot CLI, Cursor Agent and custom agents.
- Local API and SSH connections.

## Install

Download the DMG from [Releases](https://github.com/eugeneb1ack/si-notch/releases/latest), open it and drag `si-notch.app` to Applications.
Open **Settings → Connection** to connect agents.

macOS 14+, Apple Silicon. The current build is ad hoc signed and not notarized. Intel builds have not been tested.

[Agent setup](docs/agent-integrations.md) · [API](docs/architecture.md) · [SSH](docs/remote-connections.md) · [Feature status](docs/parity.md)

Updates are checked at launch and every six hours. Open **Settings → About** to download, verify and install a new version. Stable and beta channels are available. [Release setup](docs/updates.md).

## Supported Languages

English, Russian, Simplified Chinese.

## Build

```sh
scripts/test.sh
scripts/build-app.sh release
scripts/build-dmg.sh
```

Requires Xcode 26+, Python 3 and Node.js. Output: `build/si-notch-macos-arm64-0.4.6.dmg` and `build/si-notch.zip`.

## Data and license

Session data is processed locally and kept in memory. Short task and response excerpts appear in the island.

[si-notch Source License 1.0](LICENSE) allows study, installation, building, modification and free redistribution. Selling the app or modified versions is prohibited. It is based on MIT with an added no-sale condition.

Bundled event sounds by Juhani Junkala (SubspaceAudio) are separately released under [CC0](Sources/SINotch/Resources/Sounds/SubspaceAudio-LICENSE.txt).

Contact: [dis/root](https://disroot.website/).

[Agent plugins](plugins/README.md) · [Hermes setup and installation prompt](plugins/hermes/README.md)
