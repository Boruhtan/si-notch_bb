[English](hermes-plugin-development.md) · [Русский](ru/hermes-plugin-development.md)

# Develop a Hermes observer plugin

For normal installation, use [si-notch for Hermes](../plugins/hermes/README.md). This guide explains how the maintained observer maps Hermes's public plugin API to si-notch and how to extend it without changing the agent's behavior.

Hermes plugins use `plugin.yaml` and `register(ctx)` in `__init__.py`. Register callbacks with `ctx.register_hook(name, callback)` and accept `**kwargs` so additional upstream fields do not break the callback. Install into the intended user/profile plugin directory; project-local plugin discovery is not a reliable gateway installation route. Follow the current [official plugin guide](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins) and the installed version's `hermes plugins --help`.

## Use the maintained integration

The package consists of:

| File | Responsibility |
| --- | --- |
| [`plugin.yaml`](../plugins/hermes/plugin.yaml) | Plugin name/version and declared hooks. |
| [`__init__.py`](../plugins/hermes/__init__.py) | Hook registration, bounded metadata extraction, lifecycle translation, profile/session identity, presence and numeric usage queue. |
| [`relay.py`](../plugins/hermes/relay.py) | Standalone Python client for the local or SSH-forwarded Unix socket. |
| [`configure.py`](../plugins/hermes/configure.py) | Setup of this plugin's settings, delivery check and guarded stale-socket recovery. |
| `si-notch.json` | Installed profile settings: `instanceId`, `displayName`, `showSessionText`, `socketPath`, optional `helperPath`. Not a source-controlled user configuration. |

Local Mac setup: **Settings → Connection → Hermes → Connect**, then `hermes plugins enable si-notch` in the chosen profile and start a new turn. For a manually installed plugin, run `configure.py setup --name "Local Hermes" --hide-text --socket "$HOME/.si-notch/run/events.sock"`. The normal local helper is discovered automatically. Remote setup uses **Settings → Remote SSH** or the native installation steps in the plugin README. It forwards a private remote socket to the Mac; no HTTP listener or model API key is required.

Do not enable two copies for the same profile. App-managed setup owns the installed bundled code; a native Git installation owns its chosen revision. Reapplying the first replaces the latter. Preserve `instanceId` when updating, but generate a distinct profile identity when cloning to another machine.

## Profile identity and ingress

Every local and remote profile needs its own stable `instanceId`. The observer hashes the profile identity into session IDs, so equal native session/turn/request IDs from different profiles stay independent. Preserve existing IDs on updates; use `configure.py setup --new-instance` only for an explicitly new clone and never move another profile's usage queue. App setup discovers the local default home and named profile homes, scopes installation/activation to the selected home, and retains existing plugin settings.

The Mac records ingress origin separately from event metadata. App-managed SSH connectors own separate local sockets; the remote socket path and event envelope remain compatible. Local origin requires the bundled native helper's kernel-reported peer executable. Unknown sources do not suppress discovery. Profile receipts, independent unnamed-session receipts and provider-wide diagnostic receipts have separate roles. A task cannot move from an established legacy session to a named identity. The live app keeps bounded stores of 1,024 sessions and 1,024 profile observations; History has its own retention policy.

## Map lifecycle correctly

The maintained mapping is based on its actual registered callbacks:

| Hermes callback | si-notch behavior |
| --- | --- |
| `on_session_start` | Start one session, retain available model metadata. |
| `pre_llm_call` | Begin a user turn; optionally share its public task excerpt. Return `None`. |
| `pre_api_request` | Working state, current request model/reasoning settings, capture parent identity for this child turn. |
| `pre_tool_call`, `post_tool_call` | Tool start and finish/failure. Use `session_id`, falling back to `task_id` where supplied. Return `None`. |
| `on_interim_message`, `post_llm_call` | Optional visible assistant text; `post_llm_call` alone does not finish the turn. |
| `on_session_end` | End of a **turn**: completed → completed; interrupted → waiting; explicit failure or `completed=False, interrupted=False` → failed. Missing outcome fields remain waiting/unknown. |
| `on_session_finalize` | Close the durable session and discard per-session transient state. |
| `subagent_start`, `subagent_stop` | Child lifecycle and parent/child relation. The child reports its own request usage. |
| `on_human_input_request`, `on_human_input_resolved` | Attention with an opaque request identity, then resumed work. No reply transport. |
| `post_api_request`, successful `post_auxiliary_call` | Final numeric request usage, stable request ID and task attribution. |

Do not equate `on_session_end` with conversation closure. The upstream [hook contract](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks) defines it at turn finalization, including interruption and unsuccessful outcomes. Also distinguish the `on_*` plugin callbacks from gateway event hooks such as `agent:start`: they are separate APIs with different loaders and payloads.

Keep `tool_name` and outcome flags; do not forward raw `args`, result strings, conversation history or hidden reasoning. The maintained observer only inspects bounded tool-result flags and structured todo items, then emits allowlisted fields. Task and assistant text follows the profile's explicit text-sharing setting. A missing field means unknown, not evidence of success.

## Write callbacks with a narrow contract

A small observer can use the [tested Python producer](examples/custom-agent/agent.py), copied into its own plugin directory as `agent.py`. This minimal plugin reports tools only; it is a development starting point, not a replacement for the maintained plugin's lifecycle and durable usage implementation:

```yaml
# plugin.yaml
name: my-notch-observer
version: "0.1"
description: Report tool activity to a configured si-notch socket
provides_hooks:
  - pre_tool_call
  - post_tool_call
```

```python
# __init__.py (agent.py is copied beside it)
import hashlib
import os
import threading
from .agent import Agent, BridgeError


def register(ctx):
    agents = {}
    lock = threading.Lock()
    endpoint = os.environ.get("SI_NOTCH_SOCKET")
    namespace = os.environ.get("MY_NOTCH_INSTANCE")
    if not endpoint or not namespace:
        return  # Explicit per-profile setup; do not guess another profile's socket.

    def report(kind, session_id=None, task_id=None, tool_name=None, **kwargs):
        identity = session_id or task_id
        if not isinstance(identity, str) or not identity or not isinstance(tool_name, str):
            return
        key = "observer-" + hashlib.sha256((namespace + "\0" + identity).encode()).hexdigest()
        with lock:
            agent = agents.get(key)
            if agent is None:
                if len(agents) >= 256:
                    return
                agent = agents[key] = Agent(endpoint, session=key)
            event = agent.event(kind, tool_name=tool_name[:128])
            # This minimal producer does not persist sequence across plugin reloads.
            event.pop("sequence", None)
            event.pop("turn_id", None)  # Tool-only example cannot invent user-turn identity.
            try:
                agent.deliver(event)
            except (OSError, ValueError, BridgeError):
                # Reporting must not interrupt tools. Production adapters should
                # log a bounded, redacted diagnostic and use retry backoff.
                pass
        return None

    def before_tool(**kwargs):
        report("tool.start", **kwargs)

    def after_tool(status=None, **kwargs):
        report("tool.failed" if status in ("error", "failed", "blocked") else "tool.finish", **kwargs)

    ctx.register_hook("pre_tool_call", before_tool)
    ctx.register_hook("post_tool_call", after_tool)
```

Set `SI_NOTCH_SOCKET` to the correct absolute endpoint and `MY_NOTCH_INSTANCE` to a stable unique profile identifier in the process that loads this development plugin. Enable it with `hermes plugins enable my-notch-observer`, confirm load with `hermes plugins list`, and test a new turn. This code deliberately has no text sharing, worker or decision path. Use the maintained plugin when you need full sessions, profiles, backoff, task usage and lifecycle cleanup. Do not run both observers for the same sessions.

Callbacks must not return a permission directive, tool-argument modification or injected context merely to send telemetry. `pre_tool_call` and `pre_llm_call` can affect behavior if they return values; si-notch returns `None`. The [observer API](https://hermes-agent.nousresearch.com/docs/developer-guide/observer-hooks) describes the telemetry envelope and compatibility rules.

## Handle concurrency and unload

Several sessions and tools may invoke callbacks concurrently. Lock identity/counter maps and use bounded I/O. Do not hold a global lock around a slow model call. The maintained plugin uses a bounded subprocess for delivery and a retry backoff; it never launches a shell command supplied by a hook.

Use `ctx.session_cwd()` inside the current session callback when available. A gateway process's `os.getcwd()` is not a reliable session project. Read only the current request's model/reasoning metadata; never infer it from a global default when a request can override it.

Register cleanup with `ctx.on_unload(dispose)` before starting a worker. Stop it on disable/reload and release its resources. The maintained plugin only starts its 30-second presence/retry worker when this API exists; older runtimes retain startup presence and ordinary lifecycle delivery. The cleanup API is defined by [Hermes PluginContext](https://github.com/nousresearch/hermes-agent/blob/main/hermes_cli/plugins.py).

## Normalize and persist usage

Hermes supplies a normalized usage dictionary and `api_request_id` at `post_api_request`. The si-notch adapter hashes IDs and converts separate upstream input/cache buckets into its inclusive input count. Reasoning is included in output and is not added again. Each request retains its own turn and the parent turn captured before a reused child starts that request. Successful auxiliary calls are separate request facts. Missing hooks or counts stay unknown; older remote history is not imported.

The private `usage-outbox` contains only bounded numeric records, opaque identities, model/profile labels and timestamps. It retries records until `usage_committed`, never model calls. Request identity deduplicates delivery in the app; a queue overflow marks subsequent data incomplete. Preserve pending records when updating; review whether they should be delivered before removing the plugin. See the [custom protocol](custom-agents.md#token-usage-without-double-counting) for field names, totals and ACK semantics.

## Attention is not authorization

The current Hermes plugin observes human input but does not register an approval transport, inject replies, call a message API or control tools. It sends attention identity so the app can direct the user to the original Hermes chat/terminal. Do not connect a notification hook to `si-notchctl request` without implementing a real, request-bound response path in the owning agent. A future responder must validate the exact pending request, available action, deadline and one-shot result; timeout or uncertain delivery must never become permission.

## Verify changes

Use the isolated tests before enabling a modified plugin:

```sh
python3 -m unittest discover -s Tests/adapters -p 'test_hermes*.py'
python3 docs/examples/custom-agent/test_agent.py
```

The first command checks the maintained plugin's callbacks, privacy, profile separation, usage queue, configuration and socket delivery with fixtures. The second checks the standalone producer. Neither proves a real Hermes UI roundtrip. For a live check, install in a chosen test profile, verify load, connect the Mac, and use the [smoke-test prompt](../plugins/hermes/SMOKE_TEST_PROMPT.md). Inspect Working → two tool completions → Done, a second profile's distinct identity, optional text, and newly collected request usage. Human-input checks must be answered in Hermes. Test reconnect/unload separately; a tunnel or presence ACK alone does not prove model lifecycle.

Record the Hermes version, plugin version and installation method when reporting a failure. Use the [plugin README](../plugins/hermes/README.md) for installation, removal and recovery, and [feature status](parity.md) for current verification scope.
