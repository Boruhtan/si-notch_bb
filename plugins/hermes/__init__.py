"""Hermes Agent observer plugin for si-notch. Task text is opt-in; raw tool content is excluded."""

from __future__ import annotations

import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import threading
import time
from uuid import uuid4


_SAFE_TOOL_NAMES = frozenset({
    "terminal", "browser", "web_search", "web_fetch", "read_file",
    "write_file", "edit_file", "delegate_task", "search", "python", "grep",
})
_LOCK = threading.Lock()
_SEQUENCES: dict[str, int] = {}
_STARTED: set[str] = set()
_TASK_TITLES: dict[str, str] = {}
_METADATA: dict[str, dict] = {}
_TODO_IDS: dict[str, set[str]] = {}
_CONTEXT = None
_EFFORTS = frozenset({"none", "off", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "auto", "adaptive", "enabled", "disabled"})
_DISABLED_UNTIL = 0.0
_TIMEOUT_SECONDS = 1.2
_RETRY_SECONDS = 5.0


def _opaque_id(value: object, prefix: str) -> str | None:
    if not isinstance(value, str) or not value or len(value) > 4096:
        return None
    return prefix + hashlib.sha256(value.encode("utf-8")).hexdigest()[:32]


def _settings() -> dict:
    config = Path(__file__).resolve().parent / "si-notch.json"
    try:
        if not config.is_symlink() and config.is_file() and config.stat().st_size <= 8192:
            value = json.loads(config.read_text())
            if isinstance(value, dict):
                return value
    except (OSError, ValueError):
        pass
    return {}


def _display_name() -> str:
    value = _settings().get("displayName")
    if isinstance(value, str):
        value = value.strip()
        if 0 < len(value) <= 128 and not any(ord(char) < 32 or ord(char) == 127 for char in value):
            return value
    return "Hermes Agent"


def _connection_id() -> str | None:
    return _opaque_id(_settings().get("instanceId"), "hermes-instance-")


def _session_key(value: object) -> str | None:
    opaque = _opaque_id(value, "hermes-")
    if opaque is None:
        return None
    connection = _connection_id()
    return _opaque_id(connection + ":" + opaque, "hermes-") if connection else opaque


def _session_text(value: object, *, prompt: bool = False) -> str | None:
    if _settings().get("showSessionText") is not True or not isinstance(value, str):
        return None
    if prompt:
        # A brief task description also avoids displaying a connector's trailing instructions.
        value = value.removeprefix("message:\n").split("\n\n", 1)[0]
    value = "".join(char for char in value if ord(char) >= 32 or char in "\n\t").replace("\x7f", "").strip()
    limit = 1600 if prompt else 4000
    return (value[:limit - 1] + "…" if len(value) > limit else value) or None


def _metadata_text(value: object, limit: int = 256) -> str | None:
    if not isinstance(value, str) or not value.strip() or len(value.encode("utf-8")) > limit:
        return None
    return value.strip() if not any(ord(c) < 32 or ord(c) == 127 for c in value) else None


def _reasoning(body: dict) -> str | None:
    reasoning = body.get("reasoning")
    candidates = [body.get("reasoning_effort"), reasoning.get("effort") if isinstance(reasoning, dict) else None]
    extra = body.get("extra_body")
    if isinstance(extra, dict):
        candidates += [extra.get("reasoning_effort")]
        if isinstance(extra.get("reasoning"), dict): candidates.append(extra["reasoning"].get("effort"))
    for value in candidates:
        if isinstance(value, str) and value in _EFFORTS: return value
    thinking = body.get("thinking")
    if isinstance(thinking, dict):
        if thinking.get("type") == "disabled": return "off"
        budget = thinking.get("budget_tokens")
        if type(budget) is int and 0 < budget <= 10_000_000: return str(budget) + " tokens"
        if thinking.get("type") in ("adaptive", "enabled"): return thinking["type"]
    return None


def _observe_metadata(session_id: object, model=None, request=None, reasoning_effort=None) -> None:
    session = _session_key(session_id)
    if session is None: return
    body = request.get("body", request) if isinstance(request, dict) else None
    if not isinstance(body, dict): body = None
    name = _metadata_text(body.get("model")) if body is not None else None
    name = name or _metadata_text(model)
    effort = reasoning_effort if isinstance(reasoning_effort, str) and reasoning_effort in _EFFORTS else None
    cwd = None
    try:
        value = _CONTEXT.session_cwd() if _CONTEXT is not None else None
        if isinstance(value, str) and value.startswith("/"):
            cwd = _metadata_text(value, 4096)
    except Exception:
        pass  # Older Hermes versions need not expose the session-cwd API.
    with _LOCK:
        data = _METADATA.setdefault(session, {})
        if name:
            if name != data.get("model"): data["reasoning_effort"] = ""
            data["model"] = name
        if body is not None: data["reasoning_effort"] = _reasoning(body) or ""
        elif effort is not None: data["reasoning_effort"] = effort
        if cwd: data["cwd"] = cwd


def _observe_todos(session_id: object, outcome: dict) -> None:
    todos = outcome.get("todos")
    session = _session_key(session_id)
    if session is None or not isinstance(todos, list) or len(todos) > 256: return
    current = {}
    for index, item in enumerate(todos):
        if not isinstance(item, dict): continue
        identifier = _opaque_id(item.get("id"), "task-")
        if not identifier: continue
        title = _session_text(item.get("content"), prompt=True) or "Task " + str(index + 1)
        title = title.encode("utf-8")[:512].decode("utf-8", errors="ignore")
        status = {"completed": "completed", "cancelled": "ended", "in_progress": "working"}.get(item.get("status"), "idle")
        current[identifier] = {"id": identifier, "title": title, "status": status}
    with _LOCK:
        previous = _TODO_IDS.get(session, set())
        _TODO_IDS[session] = set(current)
    for identifier in sorted(previous - current.keys()):
        _emit("task.update", session_id, task={"id": identifier, "title": "Task", "status": "ended"})
    for item in current.values(): _emit("task.update", session_id, task=item)


def _helper_path() -> Path | None:
    def executable(value) -> Path | None:
        if not isinstance(value, (str, Path)) or any(ord(char) < 32 for char in str(value)):
            return None
        path = Path(value)
        return path if path.is_absolute() and path.is_file() and os.access(path, os.X_OK) else None

    configured = os.environ.get("SI_NOTCH_CLI")
    if configured is not None:
        return executable(configured)
    directory = Path(__file__).resolve().parent
    settings = _settings()
    if "helperPath" in settings:
        return executable(settings["helperPath"])
    for candidate in (directory.parent.parent.parent / "Helpers/si-notchctl",
                      Path("/Applications/si-notch.app/Contents/Helpers/si-notchctl"),
                      Path.home() / "Applications/si-notch.app/Contents/Helpers/si-notchctl"):
        if path := executable(candidate):
            return path
    return None


def _send(payload: dict) -> bool:
    """Bounded, fail-open delivery; never invoke a shell or capture helper output."""
    global _DISABLED_UNTIL
    if time.monotonic() < _DISABLED_UNTIL:
        return False
    helper = _helper_path()
    command = [str(helper)] if helper else None
    if command is None and "SI_NOTCH_CLI" not in os.environ and "helperPath" not in _settings():
        # Git subdirectory installs may not preserve executable bits. Use the
        # running Hermes interpreter for our bundled, dependency-free relay.
        relay = Path(__file__).resolve().parent / "relay.py"
        if relay.is_file() and not relay.is_symlink():
            command = [sys.executable, str(relay)]
    if command is None:
        return False
    environment = dict(os.environ)
    socket_path = _settings().get("socketPath")
    if isinstance(socket_path, str) and socket_path.startswith("/") and not any(ord(c) < 32 for c in socket_path):
        environment["SI_NOTCH_SOCKET"] = socket_path
    try:
        result = subprocess.run(
            [*command, "emit", json.dumps(payload, separators=(",", ":"))],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=_TIMEOUT_SECONDS,
            check=False,
            env=environment,
        )
        if result.returncode == 0:
            return True
    except (OSError, subprocess.TimeoutExpired):
        pass
    _DISABLED_UNTIL = time.monotonic() + _RETRY_SECONDS
    return False


def _emit(kind: str, session_id: object, *, tool_name: object = None,
          approval_id: object = None, message: str | None = None,
          first_prompt: str | None = None, turn_id: object = None,
          task: dict | None = None, subagent: dict | None = None) -> bool:
    session = _session_key(session_id)
    if session is None:
        return False
    with _LOCK:
        sequence = _SEQUENCES.get(session, 0) + 1
        _SEQUENCES[session] = sequence
        task_title = _TASK_TITLES.get(session)
        metadata = dict(_METADATA.get(session, {}))
    title = _display_name()
    if task_title and _settings().get("showSessionText") is True:
        title += " · " + task_title
    title = title.encode("utf-8")[:512].decode("utf-8", errors="ignore")
    payload = {
        "event": kind,
        "session_id": session,
        "provider": "hermes",
        "id": str(uuid4()),
        "sequence": sequence,
        "timestamp": time.time(),
        "title": title,
        **metadata,
    }
    if task is not None: payload["task"] = task
    if subagent is not None: payload["subagent"] = subagent
    if connection := _connection_id():
        payload["connection_id"] = connection
        payload["connection_name"] = _display_name()
    if tool_name is not None:
        payload["tool_name"] = tool_name if isinstance(tool_name, str) and (tool_name in _SAFE_TOOL_NAMES or re.fullmatch(r"[a-z][a-z0-9_]{0,127}", tool_name)) else "tool"
    if approval_id is not None:
        safe_id = _opaque_id(approval_id, "request-")
        if safe_id:
            payload["approval_id"] = safe_id
    if message:
        payload["message"] = message
    if first_prompt:
        payload["first_prompt"] = first_prompt
    if safe_turn := _opaque_id(turn_id, "turn-"):
        payload["turn_id"] = safe_turn
    return _send(payload)


def _start_once(session_id: object) -> None:
    session = _session_key(session_id)
    if session is None:
        return
    with _LOCK:
        if session in _STARTED:
            return
        _STARTED.add(session)
    _emit("session.start", session_id)


def on_session_start(session_id=None, model=None, **kwargs) -> None:
    _observe_metadata(session_id, model, reasoning_effort=kwargs.get("reasoning_effort"))
    _start_once(session_id)


def pre_api_request(session_id=None, turn_id=None, model=None, request=None, **kwargs) -> None:
    _observe_metadata(session_id, model, request, kwargs.get("reasoning_effort"))
    _start_once(session_id)
    _emit("agent.working", session_id, turn_id=turn_id)


def pre_llm_call(session_id=None, user_message=None, turn_id=None, model=None, **kwargs) -> None:
    _observe_metadata(session_id, model, reasoning_effort=kwargs.get("reasoning_effort"))
    text = _session_text(user_message, prompt=True)
    if text and (session := _session_key(session_id)):
        with _LOCK:
            _TASK_TITLES[session] = " ".join(text.split())[:100]
    _start_once(session_id)
    _emit("agent.working", session_id, message=text, first_prompt=text, turn_id=turn_id)


def pre_tool_call(session_id=None, tool_name=None, turn_id=None, task_id=None, **kwargs) -> None:
    # Hermes tool hooks also use task_id on some supported runtimes.
    session_id = session_id or task_id
    # Always return None: this callback observes tools and never supplies a directive.
    _start_once(session_id)
    _emit("tool.start", session_id, tool_name=tool_name, turn_id=turn_id)


def post_tool_call(session_id=None, tool_name=None, status=None, turn_id=None, task_id=None, result=None, **kwargs) -> None:
    session_id = session_id or task_id
    failed = status in ("error", "failed", "blocked")
    outcome = None
    # Inspect outcome flags only; never forward result content or errors.
    if not failed and isinstance(result, str) and len(result) <= 128 * 1024:
        try:
            outcome = json.loads(result)
            if isinstance(outcome, dict):
                failed = bool(outcome.get("error")) or outcome.get("success") is False
        except ValueError:
            pass
    _start_once(session_id)
    _emit("tool.failed" if failed else "tool.finish", session_id,
          tool_name=tool_name, turn_id=turn_id)
    if not failed and tool_name in ("todo", "todo_list") and isinstance(outcome, dict):
        _observe_todos(session_id, outcome)


def _subagent(parent_session_id, child_session_id, child_role, status) -> None:
    identifier = _opaque_id(child_session_id, "subagent-")
    if identifier is None: return
    role = _metadata_text(child_role, 128)
    name = role if role and re.fullmatch(r"[a-zA-Z0-9_./ -]+", role) else "Subagent"
    _emit("subagent.start" if status == "working" else "subagent.end", parent_session_id,
          subagent={"id": identifier, "name": name, "status": status})


def subagent_start(parent_session_id=None, child_session_id=None, child_role=None, **kwargs) -> None:
    _subagent(parent_session_id, child_session_id, child_role, "working")


def subagent_stop(parent_session_id=None, child_session_id=None, child_role=None, child_status=None, **kwargs) -> None:
    _subagent(parent_session_id, child_session_id, child_role, "failed" if child_status == "failed" else "completed")


def on_interim_message(session_id=None, text=None, turn_id=None, **kwargs) -> None:
    if message := _session_text(text):
        _emit("agent.working", session_id, message=message, turn_id=turn_id)


def post_llm_call(session_id=None, assistant_response=None, turn_id=None, **kwargs) -> None:
    if message := _session_text(assistant_response):
        # The canonical on_session_end hook owns the completed/failed state.
        _emit("agent.working", session_id, message=message, turn_id=turn_id)


def on_human_input_request(session_id=None, request_id=None, kind=None, **kwargs) -> None:
    _start_once(session_id)
    if kind == "approval":
        _emit("approval.request", session_id, approval_id=request_id,
              message="Hermes is waiting for approval")
    else:
        _emit("agent.waiting", session_id, message="Hermes is waiting for input")


def on_human_input_resolved(session_id=None, **kwargs) -> None:
    _emit("agent.working", session_id)


def on_session_end(session_id=None, completed=False, failed=False,
                   interrupted=False, turn_id=None, **kwargs) -> None:
    # Hermes fires this once per turn; only finalize closes the durable session.
    if failed:
        kind = "agent.failed"
    elif interrupted:
        kind = "agent.waiting"
    elif completed:
        kind = "agent.completed"
    else:
        kind = "agent.waiting"
    _emit(kind, session_id, turn_id=turn_id)


def on_session_finalize(session_id=None, **kwargs) -> None:
    _emit("session.end", session_id)
    session = _session_key(session_id)
    if session:
        with _LOCK:
            _STARTED.discard(session)
            _SEQUENCES.pop(session, None)
            _TASK_TITLES.pop(session, None)
            _METADATA.pop(session, None)
            _TODO_IDS.pop(session, None)


def register(ctx) -> None:
    """Register only observer hooks; Hermes' authorization path is untouched."""
    global _CONTEXT
    _CONTEXT = ctx
    for name, callback in (
        ("on_session_start", on_session_start),
        ("pre_llm_call", pre_llm_call),
        ("pre_api_request", pre_api_request),
        ("pre_tool_call", pre_tool_call),
        ("post_tool_call", post_tool_call),
        ("on_interim_message", on_interim_message),
        ("post_llm_call", post_llm_call),
        ("on_human_input_request", on_human_input_request),
        ("on_human_input_resolved", on_human_input_resolved),
        ("on_session_end", on_session_end),
        ("on_session_finalize", on_session_finalize),
        ("subagent_start", subagent_start),
        ("subagent_stop", subagent_stop),
    ):
        ctx.register_hook(name, callback)
    if connection := _connection_id():
        # A loaded profile announces availability without creating a task.
        _emit("agent.presence", "presence-" + connection)
