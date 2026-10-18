"""Hermes Agent observer plugin for si-notch. No prompt or tool content leaves Hermes."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
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
_DISABLED_UNTIL = 0.0
_TIMEOUT_SECONDS = 1.2
_RETRY_SECONDS = 5.0


def _opaque_id(value: object, prefix: str) -> str | None:
    if not isinstance(value, str) or not value or len(value) > 4096:
        return None
    return prefix + hashlib.sha256(value.encode("utf-8")).hexdigest()[:32]


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
    config = directory / "si-notch.json"
    try:
        if not config.is_symlink() and config.is_file() and config.stat().st_size <= 8192:
            settings = json.loads(config.read_text())
            if isinstance(settings, dict) and "helperPath" in settings:
                return executable(settings["helperPath"])
    except (OSError, ValueError):
        pass
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
    if helper is None:
        return False
    try:
        result = subprocess.run(
            [str(helper), "emit", json.dumps(payload, separators=(",", ":"))],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=_TIMEOUT_SECONDS,
            check=False,
        )
        if result.returncode == 0:
            return True
    except (OSError, subprocess.TimeoutExpired):
        pass
    _DISABLED_UNTIL = time.monotonic() + _RETRY_SECONDS
    return False


def _emit(kind: str, session_id: object, *, tool_name: object = None,
          approval_id: object = None, message: str | None = None) -> bool:
    session = _opaque_id(session_id, "hermes-")
    if session is None:
        return False
    with _LOCK:
        sequence = _SEQUENCES.get(session, 0) + 1
        _SEQUENCES[session] = sequence
    payload = {
        "event": kind,
        "session_id": session,
        "provider": "hermes",
        "id": str(uuid4()),
        "sequence": sequence,
        "timestamp": time.time(),
        "title": "Hermes Agent",
    }
    if tool_name is not None:
        payload["tool_name"] = tool_name if isinstance(tool_name, str) and tool_name in _SAFE_TOOL_NAMES else "tool"
    if approval_id is not None:
        safe_id = _opaque_id(approval_id, "request-")
        if safe_id:
            payload["approval_id"] = safe_id
    if message:
        payload["message"] = message
    return _send(payload)


def _start_once(session_id: object) -> None:
    session = _opaque_id(session_id, "hermes-")
    if session is None:
        return
    with _LOCK:
        if session in _STARTED:
            return
        _STARTED.add(session)
    _emit("session.start", session_id)


def on_session_start(session_id=None, **kwargs) -> None:
    _start_once(session_id)


def pre_api_request(session_id=None, **kwargs) -> None:
    _start_once(session_id)
    _emit("agent.working", session_id)


def post_tool_call(session_id=None, tool_name=None, status=None, **kwargs) -> None:
    _start_once(session_id)
    _emit("tool.failed" if status in {"error", "failed", "blocked"} else "tool.finish", session_id,
          tool_name=tool_name)


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
                   interrupted=False, **kwargs) -> None:
    # Hermes fires this once per turn; only finalize closes the durable session.
    if failed:
        kind = "agent.failed"
    elif interrupted:
        kind = "agent.waiting"
    elif completed:
        kind = "agent.completed"
    else:
        kind = "agent.waiting"
    _emit(kind, session_id)


def on_session_finalize(session_id=None, **kwargs) -> None:
    _emit("session.end", session_id)
    session = _opaque_id(session_id, "hermes-")
    if session:
        with _LOCK:
            _STARTED.discard(session)
            _SEQUENCES.pop(session, None)


def register(ctx) -> None:
    """Register only observer hooks; Hermes' authorization path is untouched."""
    for name, callback in (
        ("on_session_start", on_session_start),
        ("pre_api_request", pre_api_request),
        ("post_tool_call", post_tool_call),
        ("on_human_input_request", on_human_input_request),
        ("on_human_input_resolved", on_human_input_resolved),
        ("on_session_end", on_session_end),
        ("on_session_finalize", on_session_finalize),
    ):
        ctx.register_hook(name, callback)
