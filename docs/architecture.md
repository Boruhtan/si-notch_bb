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
- Live session state is held in memory; a separate local text archive survives clearing completed cards and app restarts. Preferences use UserDefaults.

Run `si-notchctl --help` for `run`, `hook`, `notify`, `paths` and `status`.

## Agent availability

Sessions contains working, waiting, approval, completed and failed tasks. Idle agent connections and Codex lifecycle placeholders without task context are listed only under Agents. Multiple sessions of one provider share one availability row. Online means a native application is running or an event was received in the last two minutes; older observations show Last seen. Installed alone does not mean online.

Codex sessions tagged `internal` or `subagent` are excluded from task lists. Custom and unclassified sources remain eligible. API clients can mark internal sessions with the optional `is_internal_session` field, including when the source becomes known after initial events.

## Local text history

History is the last Sessions filter, after All, Working, Attention and Done, and remains available without live cards. Each record contains one request/turn, public assistant replies and available command text. Codex Desktop and local rollouts and Pi files provide explicit text items. Other integrations retain the text they already share; si-notch does not enable optional remote content sharing or reconstruct missing commands. Reasoning, tool output, attachments and permission payloads are excluded. Old conversations are not imported.

`HistoryController` sends immutable events to a serial utility queue. `HistoryStore` stores private JSON records and a metadata-only index under `~/Library/Application Support/si-notch/History` (directory 0700, files 0600). The list shows 50 records at a time and reads a record only when opened. At most eight record bodies remain cached. There is no archive polling or idle timer. Changed text is coalesced for up to two seconds, terminal events flush promptly, and normal shutdown drains buffered writes.

Defaults are 1,000 records and 200 MiB including the index. Custom limits accept 1–10,000 records and 1–2,048 MiB; oldest records are removed until both limits hold. The metadata index is additionally capped at 4 MiB. Each text item is bounded at 16,384 characters and a record at 256 KiB; unusually long records keep the request and latest text and display a truncation notice. Search covers request titles, projects and providers. Clear History cancels buffered writes and fences recent cleared turns against late snapshots. Disabling recording preserves existing records. Known token/password forms are redacted; local text can still contain private information.

Custom event producers may supply `history_items`: an array of `{ "id": "stable-item-id", "role": "user|assistant|command", "text": "public text" }`. Use stable item IDs for streaming replacement and a fresh `turn_id` per request. The envelope accepts up to 64 items and 128 KiB of item text, within the transport's overall payload limit. Never send tool output or generic argument dictionaries in these items.
