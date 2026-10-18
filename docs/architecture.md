[English](architecture.md) · [Русский](ru/architecture.md) · [简体中文](zh-CN/architecture.md)

# Local API

The bundled helper sends JSON to `~/.si-notch/run/events.sock`. Use a stable `session_id` and your agent’s name as `provider`.

```sh
~/Applications/si-notch.app/Contents/Helpers/si-notchctl emit \
  '{"event":"agent.working","session_id":"my-task","provider":"custom","title":"Check build","message":"Running tests"}'
```

Common events: `session.start`, `agent.working`, `agent.waiting`, `agent.completed`, `agent.failed`, `session.end`, `tool.start`, `tool.finish`. Optional fields include `title`, `message`, `cwd`, `tool_name`, `model`, `id` and `sequence`. Unique event IDs and ordered sequences prevent duplicate or stale updates. Use the same `turn_id` across observers of one turn to deduplicate its sounds; use a new ID for the next turn. The parser in [AgentEvent.swift](../Sources/SINotchCore/AgentEvent.swift) defines the accepted fields.

## Decisions

```sh
~/Applications/si-notch.app/Contents/Helpers/si-notchctl request \
  '{"session_id":"my-task","provider":"custom","message":"Allow this action?"}' --timeout 60
```

`request` waits for a response for this request only. Exit codes: **0** allow/answer, **1** deny, **2** invalid input, timeout or disconnection. The caller must enforce the returned decision. si-notch does not run the requested action.

## Transport and code

- JSON messages are limited to 128 KiB; `emit` waits up to one second for acknowledgement.
- The socket and its directory use modes 0600 and 0700 and require the same user. Up to 16 clients and eight pending requests are supported.
- Override the socket with `SI_NOTCH_SOCKET` or `--socket /absolute/path`.
- `SINotchCore` contains session state and parsing; `SINotchTransport` handles IPC; `SINotch` contains AppKit/SwiftUI and observers.
- Sessions and action history are held in memory. Preferences use UserDefaults.

Run `si-notchctl --help` for `run`, `hook`, `notify`, `paths` and `status`.

## Agent availability

Sessions contains working, waiting, approval, completed and failed tasks. Idle agent connections and Codex lifecycle placeholders without task context are listed only under Agents. Multiple sessions of one provider share one availability row. Online means a native application is running or an event was received in the last two minutes; older observations show Last seen. Installed alone does not mean online.

Codex sessions tagged `internal` or `subagent` are excluded from task lists. Custom and unclassified sources remain eligible. API clients can mark internal sessions with the optional `is_internal_session` field, including when the source becomes known after initial events.
