# Agent plugins

| Integration | What it provides | Setup |
| --- | --- | --- |
| [Hermes](hermes/README.md) | Local/SSH session and tool lifecycle, optional public text, profile presence, request usage and attention notifications | [English](hermes/README.md) · [Русский](hermes/README.ru.md) · [简体中文](hermes/README.zh-CN.md) |

The Hermes package is independently installable. Its observer does not approve tools or submit answers; respond in the originating Hermes session. Capabilities depend on the hooks provided by the installed Hermes version. [Revision and verification scope](hermes/REVISION.md).

For other bundled adapters, follow [agent setup](../docs/agent-integrations.md). To build an integration, use the [custom-agent protocol](../docs/custom-agents.md) or [Hermes plugin developer guide](../docs/hermes-plugin-development.md); both have Russian versions. Each plugin directory contains its distributable sources and license. User settings, credentials and session data do not belong in this repository.
