[English](agent-integrations.md) · [Русский](ru/agent-integrations.md) · [简体中文](zh-CN/agent-integrations.md)

# Connect agents

Open **Settings → Connection → Rescan**, choose an agent and review its setup. Scanning checks application bundles, executable paths and common version-manager directories. It does not launch or install agents.

**Adapter configured** means the files are ready. **Events received** confirms delivery from an agent. Start a new session after connecting; existing sessions may need a reload.

## Open a session

Click a session card to open its Codex task or originating terminal/editor. The chevron expands details. Switching apps keeps the island open until the pointer leaves. Local helper events identify Ghostty, Terminal, iTerm, VS Code, Cursor, WezTerm, Warp and Zed from the caller’s environment. This activates the app; it does not select a particular terminal tab. File-only observations may have no app address until the adapter sends an event.

Custom integrations can set `terminal_bundle_id` (for example, `com.mitchellh.ghostty`) or `target_url`. Accepted links are `codex://threads/<UUID>` and local file routes for VS Code, Cursor and Zed. Command and extension URLs are rejected. SSH events do not infer a local terminal.

## Codex and Pi

Codex Desktop sessions are observed automatically through local IPC; CLI sessions can also be discovered from local session files. **Connect Codex** adds and authorizes the eight bundled CLI hooks after checking their exact content. Existing hooks and `notify` are preserved. If authorization fails, review the entries in Codex CLI’s `/hooks` screen. The Desktop protocol may change between Codex versions.

**Connect Pi** registers the bundled extension in `~/.pi/agent/settings.json`. Run `/reload` in an existing Pi session or restart Pi.

## Claude Code, Gemini CLI, Copilot CLI and Cursor

Click **Connect** to merge the bundled observer into the configuration below. Existing settings and hooks are kept, with a backup beside each changed file. Invalid JSON, disabled hooks and conflicting older observers require manual review. No Python runtime is needed for these integrations.

| Agent | User configuration |
| --- | --- |
| Claude Code | `~/.claude/settings.json` |
| Gemini CLI | `~/.gemini/settings.json` |
| Copilot CLI | `~/.copilot/hooks/si-notch.json` |
| Cursor | `~/.cursor/hooks.json` |

Permission decisions stay in the agent. The optional [Claude permission bridge](claude-permissions.md) is configured separately. Managed policies and workspace trust can prevent hooks from running; si-notch does not override them.

## OpenCode and Hermes

**Connect OpenCode** copies the bundled plugin to `~/.config/opencode/plugins/`. Restart OpenCode to load it. An existing project-level copy should be removed before using the global plugin.

**Connect Hermes** copies the bundled plugin to `~/.hermes/plugins/si-notch/`. Enable it in Hermes, then restart the session:

```sh
hermes plugins enable si-notch
```

Both plugins record the installed helper’s absolute path, including custom app locations. Copies installed manually also check `/Applications` and `~/Applications`. `SI_NOTCH_CLI` can override the helper path.

Absolute `CLAUDE_CONFIG_DIR`, `COPILOT_HOME`, `XDG_CONFIG_HOME` and `HERMES_HOME` values are respected when present in the app’s environment. Finder does not inherit a terminal’s shell configuration. For a custom home or Hermes profile, review the destination shown before connecting and configure that profile separately if needed.

## Custom API and remote agents

Custom integrations send session events through the [JSON API](architecture.md). Use the [SSH relay](remote-connections.md) for agents running on another host.

If a session does not appear, reload the adapter, start a new turn and check **Settings → Diagnostics**. The helper path shown there can query live delivery:

```sh
/Applications/si-notch.app/Contents/Helpers/si-notchctl status
```

[Verification scope](parity.md). Protocol references: [Claude](https://code.claude.com/docs/en/hooks), [Pi](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md), [OpenCode](https://opencode.ai/docs/plugins/), [Hermes](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins), [Gemini](https://geminicli.com/docs/hooks/), [Copilot](https://docs.github.com/en/copilot/reference/hooks-reference), [Cursor](https://cursor.com/docs/hooks).
