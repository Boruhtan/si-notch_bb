[English](custom-agents.md) · [Русский](ru/custom-agents.md)

# Connect a custom agent

An integration reports what its agent is doing. si-notch displays sessions, tools, progress, usage and requests for attention. Your agent owns its execution, credentials and permission policy.

Use the bundled CLI for most integrations. Use the Unix-socket protocol when you need a dependency-free producer or cannot launch the helper. For Hermes, use the [maintained plugin](../plugins/hermes/README.md) rather than installing a second observer.

## Start with the CLI

Run si-notch, open **Settings → Diagnostics**, and copy the helper path for your installation. The standard path is:

```sh
SI_NOTCH_CLI=/Applications/si-notch.app/Contents/Helpers/si-notchctl
"$SI_NOTCH_CLI" paths
"$SI_NOTCH_CLI" status
"$SI_NOTCH_CLI" emit '{"event":"agent.working","session_id":"my-agent-machine1-chat1","provider":"my-agent","turn_id":"turn-1","id":"event-1","sequence":1,"title":"Check a build","message":"Running checks"}'
"$SI_NOTCH_CLI" emit '{"event":"agent.completed","session_id":"my-agent-machine1-chat1","provider":"my-agent","turn_id":"turn-1","id":"event-2","sequence":2,"message":"Checks passed"}'
```

These last two commands create and complete a real local card. Do not send private text unless the user has chosen to share it. JSON on stdin is also accepted. `emit` exits nonzero on invalid input, rejection, timeout or disconnection; observation hooks should handle delivery failure without interrupting their agent.

For a command with no native hooks:

```sh
"$SI_NOTCH_CLI" run --agent my-agent --title "Project checks" -- python3 -m unittest
```

`run` executes the command directly, inherits stdio and reports its exit status. It cannot infer tool calls, model tokens, approval prompts or subagents inside that process. `hook`, `notify` and `harness-hook` are adapters for existing agent payloads; they are observers, not permission transports.

## Identity and ordering

| Field | Contract |
| --- | --- |
| `session_id` | Required stable conversation/runtime identity. Namespace it by agent, host and profile. Live session IDs are global, not scoped by `provider`; reusing another provider's ID is invalid. |
| `provider` | Your short identifier, such as `my-agent`. Do not use `codex` or `pi` to imitate another adapter: their native usage logs are authoritative. |
| `turn_id` | One ID for one user request, shared by all events for that turn. Use a new ID for the next request in the same session. |
| `id` | Unique immutable event ID. Re-deliver the same envelope with the same ID after an uncertain observation acknowledgement. |
| `sequence` | Optional nonnegative integer, strictly increasing across the session, including after a producer restart. If you cannot persist it, omit it consistently and send ordered timestamps. |
| `timestamp` | Unix seconds or ISO 8601; defaults to reception time. Use the actual occurrence time, especially for delayed usage. |
| `connection_id`, `connection_name` | Optional stable profile identity and display label. A name requires an ID. Preserve the ID across upgrades; use a new one for a cloned profile on another host. |

IDs begin with an ASCII letter or digit and then contain only letters, digits, `.`, `_`, `:`, `-`. Session, turn, connection and task IDs are at most 256 UTF-8 bytes; event IDs and usage request IDs are at most 512. Provider IDs are at most 64.

The live reducer remembers a bounded set of event IDs. It rejects older/equal sequences; when a comparable sequence is absent, older timestamps are rejected. This is bounded duplicate suppression, not a durable general-purpose message queue. `session.start` does not reset ordering. Serialize sends for one session; different sessions can run concurrently.

## Lifecycle, progress and attention

A typical sequence is:

```text
session.start → agent.working → tool.start → tool.finish → agent.completed
                       └────→ agent.waiting → agent.working
```

- `session.start` initializes an idle session. It may appear under Agents until there is real work.
- `agent.working` begins/resumes work; `tool.start`, `tool.finish`, `tool.failed` describe a tool via `tool_name`. A failed tool does not automatically fail the whole turn.
- `agent.completed` finishes a turn; `agent.failed` reports its failure. A later `agent.working` can begin the next turn in that conversation.
- `session.end` closes the session. A subsequent explicit `session.start` is required to reopen an explicitly ended session.
- `agent.waiting` means waiting. Include a stable `attention_request_id` only for an actual unresolved human question. Reuse it while that question remains pending, and send `agent.working` when it resolves. Do not treat model latency or tool execution as a human-input request.
- `approval.request` without a live reply channel reports attention only. The user must respond in the originating agent.
- `agent.presence` requires `connection_id`; it updates availability without creating a task or extending task progress. Presence is considered fresh for two minutes. Do not emit fake work as a heartbeat.

Use `task.update` for measurable checklist progress; there is no arbitrary percentage field:

```json
{"event":"task.update","session_id":"my-agent-machine1-chat1","provider":"my-agent","turn_id":"turn-1","task":{"id":"tests","title":"Run checks","status":"completed"}}
```

Task status is `idle`, `working`, `waiting`, `approval`, `completed`, `failed` or `ended`; `ended` removes a checklist item. Send a stable task ID for replacements. `subagent.start`/`subagent.end` take a `subagent` object with `id`, `name`, `status` and optional `sessionID`, `parentTurnID`. Those two nested keys are camelCase. Child sessions report their own events and usage; completing a parent turn does not imply that all background children have stopped.

`title` is capped at 512 UTF-8 bytes, `message` and `first_prompt` at 16,384, `cwd` at 4,096. Send brief public status text, not tool argument dictionaries, output or hidden reasoning. Optional `model`, `reasoning_effort`, `terminal_bundle_id` and supported `target_url` routes enrich cards. [Navigation restrictions and history](architecture.md) describe those boundaries.

## Token usage without double counting

Send a final numeric record for each provider request:

```json
{"event":"usage.update","session_id":"my-agent-machine1-chat1","provider":"my-agent","turn_id":"turn-1","id":"usage-event-1","usage":{"request_id":"provider-call-1","input_tokens":1200,"output_tokens":180,"cached_input_tokens":800,"cache_write_input_tokens":0,"reasoning_output_tokens":40,"started_at":1792700000,"ended_at":1792700002}}
```

Here the total is **1,380**. Cache reads/writes are already included in input; reasoning is already included in output. Normalize upstream counters to this convention once. Counts are nonnegative integers; timestamps are finite Unix seconds. Omit unknown values instead of inventing zero. The persistent Usage view needs both `input_tokens` and `output_tokens` to construct a count record.

`usage.request_id` identifies one immutable request within its provider/connection/session. Retries must keep the same ID and counts. Conflicting data for an existing ID mark the session incomplete rather than adding another request. For children, include `usage.parent_session_id` and `usage.parent_turn_id`, plus the child's own envelope `turn_id`; this attributes descendants to the correct root task. Set `usage.incomplete: true` when records were lost. Task totals and session-family totals count each request once. Do not put a parent's family total into its own request counter.

For request records, require `{"ok":true,"disposition":"usage_committed"}` before deleting a queued record. This path commits the Usage journal and does not change the live card. An ordinary `ok:true` is insufficient. The CLI and portable relay perform this check. A bounded private outbox can retry immutable numeric records after reconnect; never retry a model call just because telemetry was not delivered.

Without `usage.request_id`, counts are cumulative snapshots and replace previous snapshots. Choose snapshots **or** per-request records for a custom session; mixing them can double count. Snapshots cannot provide accurate per-request task attribution. Native Codex/Pi usage comes from their local logs, so custom event counters for those provider names are not added. Account quota windows are a separate Codex integration, not a conversion of local token totals or a general provider billing API.

## Explicit decisions and questions

Only a producer that can pause and enforce a decision should call `request`:

```sh
"$SI_NOTCH_CLI" request '{"session_id":"my-agent-machine1-chat1","provider":"my-agent","turn_id":"turn-2","request_id":"permission-2","approval_id":"permission-2","message":"Allow this one build command?"}' --timeout 60
```

It prints one JSON decision. Exit **0** means allow or a nonempty answer, **1** means deny, **2** means invalid input, unavailable delivery, timeout or other failure. Inspect the JSON decision as well as the exit code. Approval replies contain `ok`, `decision` (`allow` or `deny`) and the exact `request_id`. With `"question":true`, the same command offers a free-text question; success has `decision:"answer"` and `answer`. The generic socket API does not expose the Desktop adapter's arbitrary choice lists or permanent grants.

The request ID must be 1–160 ASCII letters/digits/`._:-`. Use a fresh ID for each distinct pending operation. The app binds the response to its pending connection and deadline; it permits eight pending requests, at most one per session. `--timeout` is 0.1–110 seconds (default 60). A newer request can cancel the previous one. On denial, cancellation, timeout, mismatch or disconnection, do not execute the protected operation. Return to the agent's own approval UI or cancel it. Do not replay an uncertain approval/answer submission. After a decision, emit the next actual lifecycle event; the app does not execute the action for you.

## Raw Unix IPC

The default endpoint is `~/.si-notch/run/events.sock`; `SI_NOTCH_SOCKET` or the CLI's `--socket` selects another absolute path. The app and producer must agree on it. Socket mode is 0600, immediate parent directory 0700, owned by the same user. The bundled transport also rejects unsafe ancestors and symlinks. There is no TCP endpoint or authentication token.

Open one `AF_UNIX`/`SOCK_STREAM` connection per message. Send one compact UTF-8 JSON object followed by `\n`, read one JSON line, then close. Do not multiplex events on a connection. The wire limit is **128 KiB**, even though the core parser accepts a larger envelope. Bound your connect/read/write time and keep IDs short enough for Unix socket paths.

Ordinary receipts contain `ok` and `disposition`, including `applied`, `duplicate`, `outOfOrder`, `ignoredUnknown`, `invalid` or `filtered`. `ok:true` can acknowledge an ignored observation; it is not proof that a visible card changed. `status` is a CLI diagnostic for live receipts, not a stable subscription stream. Raw decision requests additionally set `await_response:true`, `request_id`, `response_timeout` and optionally `question:true`.

## Runnable example and isolated checks

[`agent.py`](examples/custom-agent/agent.py) is a standard-library-only Python 3.10+ producer. It demonstrates lifecycle, one checklist item, tool activity, immutable request usage and an optional question. Its token numbers are synthetic. It requires an explicit socket argument and does not execute returned answers.

```sh
python3 docs/examples/custom-agent/test_agent.py
```

The tests create a temporary private Unix socket. They verify the complete process, duplicate delivery, durable usage acknowledgement, correlated answers, denial/disconnection, timeout and permission rejection. No running app, account, model call or real agent is involved. An OS sandbox that disallows Unix sockets must allow this isolated test process to bind a temporary local socket.

To show the walkthrough in a running app, explicitly select its endpoint:

```sh
python3 docs/examples/custom-agent/agent.py --socket "$HOME/.si-notch/run/events.sock"
# Add --ask to test one user-entered reply.
```

For SSH, install the standalone [`plugins/hermes/relay.py`](../plugins/hermes/relay.py) on the remote host and follow [remote connections](remote-connections.md). `scripts/remote-relay.py` is a repository wrapper and is not a standalone installable file. The relay supports `emit`, `hook`, `notify` and `request`; it does not provide the complete macOS CLI.

## Diagnose and remove an integration

Check the helper's `paths` and `status`, the configured endpoint, file ownership and **Settings → Diagnostics**. Distinguish installed/configured from events received. Start a new turn after enabling hooks. For missing cards inspect the event disposition, provider/session collision, sequence reset, completed-only filters, paused state and hidden providers. For missing usage verify final counters, stable request IDs and `usage_committed`.

Removing a custom integration means removing only its hook/plugin registration and stopping its owned worker. Preserve unrelated hooks and configuration. Disconnect any app-managed SSH tunnel separately. Existing local History and Usage records are not erased by removing an observer; use the application's relevant controls when you intend to clear stored data.

Contract sources: [event parser](../Sources/SINotchCore/AgentEvent.swift), [models](../Sources/SINotchCore/AgentModels.swift), [live reducer](../Sources/SINotchCore/SessionStore.swift), [CLI](../Sources/NotchCLI/main.swift), [transport](../Sources/SINotchTransport/IPC.swift), [request handling](../Sources/SINotch/AppMain.swift), [usage journal](../Sources/SINotch/UsageStore.swift). See [feature status](parity.md) for the distinction between implemented behavior and live verification.
