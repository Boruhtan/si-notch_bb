[English](agent-integrations.md) · [Русский](ru/agent-integrations.md) · [简体中文](zh-CN/agent-integrations.md)

# Connect agents

Open **Settings → Connection → Rescan**, choose an agent and review its setup. Scanning checks application bundles, executable paths and common version-manager directories. It does not launch or install agents.

**Adapter configured** means the files are ready. **Events received** confirms delivery from an agent. Start a new session after connecting; existing sessions may need a reload.

## Open a session

Click a session card to open its Codex task or originating terminal/editor. The chevron expands details. Switching apps keeps the island open until the pointer leaves. Local helper events identify Ghostty, Terminal, iTerm, VS Code, Cursor, WezTerm, Warp and Zed from the caller’s environment. This activates the app; it does not select a particular terminal tab. File-only observations may have no app address until the adapter sends an event.

Custom integrations can set `terminal_bundle_id` (for example, `com.mitchellh.ghostty`) or `target_url`. Accepted links are `codex://threads/<UUID>` and local file routes for VS Code, Cursor and Zed. Command and extension URLs are rejected. SSH events do not infer a local terminal.

The bundled Hermes observer links to an existing chat in the profile that reported it. The default local profile opens in Hermes Desktop when available. Other local profiles open in a terminal tab. A managed SSH card connects to the configured host and checks the chat ID in that profile before resuming. Whether an ongoing request can be answered there depends on Hermes and the original client. When Rex is installed, new terminal tabs open in the local Rex app.

Pi selects the original Rex pane when its full session and pane IDs are available. It can also select the original Apple Terminal tab when its process and TTY match and Terminal automation is already allowed. Otherwise it opens the exact saved session after checking the session file header. A reopened session does not include a dialog that remains in the first Pi process.

## Codex and Pi

Codex Desktop sessions are observed automatically through local IPC; CLI sessions can also be discovered from local session files. **Connect Codex** adds and authorizes the bundled CLI hooks after checking their exact content. Existing hooks and `notify` are preserved. If authorization fails, review the entries in Codex CLI’s `/hooks` screen. The Desktop protocol may change between Codex versions.

The bundled PermissionRequest hook offers **Allow once** and **Deny** in the island for supported requests in a confirmed manual-review turn. Automatic review keeps its normal path and creates no native prompt. Because the hook does not expose its effective reviewer, the adapter checks only the matching session/turn metadata in a bounded tail of its supplied transcript. This transcript format is not a stable API: missing, mismatched or unknown metadata defers to Codex. Global configuration is never used to guess a turn's reviewer. Review the full tool input before deciding. Each decision is bound to one request with a 70-second deadline; there is no permanent grant. Missing, expired, oversized or unsupported requests return to Codex's normal permission flow. Reconnect Codex after upgrading an older hook setup; only si-notch's owned permission timeout changes to 80 seconds, and the updated hook requires authorization. Verification scope is listed in [feature status](parity.md).

Local Desktop discovery does not require a reasoning log message. Resumed CLI rollouts are discovered in older date folders through native file events; active files continue to be polled. Parallel sessions are not limited to eight Desktop subscriptions or sixteen rollout files. Opening completed Desktop history alone does not create a task card. Local-only Work uses the same local integration; its live verification scope is listed in [feature status](parity.md). Cloud Work and dots are outside this integration's supported scope.

Local Work cards show **Work** with a briefcase icon. Codex keeps its code icon and name. This distinction uses native product metadata; mentioning Work in a prompt or title does not change the badge. A new observed turn can restore a conversation after its previous CLI process has exited.

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

## Rex and Zed

The **Agents** tab shows two collapsible groups on a Mac with Rex or Zed installed.
A group lists tasks from that host and shows children reported by the agent.
It shares the same sessions and agent counts with the main view. Clicking a
task opens its details in **Sessions**.

For **Rex**, launch a supported agent with its existing si-notch adapter in a
local Rex terminal. The native helper recognizes the Rex environment and
associates subsequent events with that group. If a plugin loses those environment
variables, the helper can identify an ancestor executable from a known local
Rex or Zed installation. This also works for supported
agents launched in **Zed Terminal Threads**. Reconnect Codex in si-notch to register
and review its `SubagentStart` and `SubagentStop` hooks. An agent that forwards a
turn to a separate gateway without reporting the originating terminal still
appears under its own provider. Shell output and Rex program-status
records are not imported. Rex is a terminal and does not identify the canonical
session behind an arbitrary program-status record.

For **Zed Agent Panel**, add a custom external agent using the bundled
`zed-acp.py` observer and your existing Codex ACP executable. Keep the standard
registry entry for sessions that do not use the observer. Example custom entry
under `agent_servers` in Zed settings (adjust absolute paths for your Mac):

```json
"Codex (si-notch)": {
  "type": "custom",
  "command": "/absolute/path/to/python3",
  "args": [
    "/absolute/path/to/si-notch.app/Contents/Resources/adapters/zed-acp.py",
    "--helper", "/absolute/path/to/si-notch.app/Contents/Helpers/si-notchctl",
    "--", "/absolute/path/to/node", "/absolute/path/to/codex-acp"
  ]
}
```

Select **Codex (si-notch)** when starting a new external-agent thread. Existing
registry threads keep using their original settings. During ACP initialization,
the observer advertises support for Codex ACP's child-session notifications.
It passes other traffic through as received, uses the Codex session ID, and forwards
lifecycle metadata, tool names and child statuses to si-notch. Approvals remain
in the client. It does not copy prompts, answers, tool arguments or credentials.
Child rows require child-session updates from the agent. Zed's built-in agent
has no supported telemetry connection in this integration.

## Custom API and remote agents

Custom integrations send session events through the [JSON API](architecture.md). Use the [SSH relay](remote-connections.md) for agents running on another host.

If a session does not appear, reload the adapter, start a new turn and check **Settings → Diagnostics**. The helper path shown there can query live delivery:

```sh
/Applications/si-notch.app/Contents/Helpers/si-notchctl status
```

[Verification scope](parity.md). Protocol references: [Claude](https://code.claude.com/docs/en/hooks), [Pi](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md), [OpenCode](https://opencode.ai/docs/plugins/), [Hermes](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins), [Gemini](https://geminicli.com/docs/hooks/), [Copilot](https://docs.github.com/en/copilot/reference/hooks-reference), [Cursor](https://cursor.com/docs/hooks).

For a complete producer implementation, see the [custom-agent guide](custom-agents.md) and [Hermes plugin development](hermes-plugin-development.md). The guides cover lifecycle, identity, progress, usage, request deadlines and isolated socket tests.
