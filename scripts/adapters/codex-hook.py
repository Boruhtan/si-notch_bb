#!/usr/bin/env python3
"""Codex status observer and request-bound native permission bridge.

Status events omit tool arguments, outputs and transcripts. PermissionRequest
alone shows the complete bounded tool input for an explicit one-time decision.
"""

import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path

MAX_INPUT_BYTES = 128 * 1024
MAX_EVENT_BYTES = 8 * 1024
TIMEOUT_SECONDS = 1.2
PERMISSION_SECONDS = 70
MAX_PERMISSION_BYTES = 12000
IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$")
SAFE_TOOL = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")

EVENTS = {
    "SessionStart": "session.start",
    "UserPromptSubmit": "agent.working",
    "PreToolUse": "tool.start",
    "PostToolUse": "tool.finish",
    "PermissionRequest": "agent.waiting",
    "Stop": "agent.completed",
    "Interrupt": "session.start",  # Idle; an interrupted turn is not a completion.
    "SessionEnd": "session.end",
}


def safe_identifier(value):
    return value if isinstance(value, str) and IDENTIFIER.fullmatch(value) else None


def display_summary(value, limit=600):
    if not isinstance(value, str):
        return None
    text = value[:16384]
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
    text = re.sub(r"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*", "[redacted]", text)
    text = re.sub(r"\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,}|AKIA[A-Z0-9]{16})\b", "[redacted]", text)
    text = re.sub(r"(?i)\b(bearer\s+)[A-Za-z0-9._~+/-]+=*", r"\1[redacted]", text)
    text = re.sub(r"(?i)\b((?:api[_-]?key|access[_-]?token|token|password|secret)\s*[:=]\s*)[^\s,;]+", r"\1[redacted]", text)
    text = " ".join("".join(c for c in text if ord(c) >= 32 or c.isspace()).split())
    if not text:
        return None
    return text if len(text) <= limit else text[:limit - 1] + "…"


def event_from_hook(hook):
    if not isinstance(hook, dict):
        return None
    name = hook.get("hook_event_name")
    session = safe_identifier(hook.get("session_id"))
    kind = EVENTS.get(name)
    if not session or not kind:
        return None
    event = {
        "event": kind,
        "session_id": session,
        "provider": "codex",
        "id": "codex-hook-" + uuid.uuid4().hex,
        "timestamp": time.time(),
    }
    cwd = hook.get("cwd")
    if isinstance(cwd, str) and os.path.isabs(cwd) and len(cwd.encode("utf-8")) <= 4096 and "\x00" not in cwd:
        event["cwd"] = cwd
    if name == "SessionStart":
        event["title"] = display_summary(os.path.basename(cwd.rstrip("/")), 100) if "cwd" in event else "Codex"
    if name == "UserPromptSubmit":
        summary = display_summary(hook.get("prompt"))
        if summary:
            event.update(title=display_summary(summary, 100), first_prompt=summary, message=summary)
    if name == "Stop":
        summary = display_summary(hook.get("last_assistant_message"))
        if summary:
            event["message"] = summary
    model = hook.get("model")
    if isinstance(model, str) and 0 < len(model.encode("utf-8")) <= 256 and not any(ord(c) < 32 for c in model):
        event["model"] = model
    effort = hook.get("reasoning_effort")
    if isinstance(effort, str) and effort in {"none", "off", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"}:
        event["reasoning_effort"] = effort
    if name in ("PreToolUse", "PostToolUse", "PermissionRequest"):
        tool = hook.get("tool_name")
        if isinstance(tool, str) and SAFE_TOOL.fullmatch(tool):
            event["tool_name"] = tool
    if name == "PermissionRequest":
        # This is observation only. A decision must remain in Codex itself.
        event["message"] = "Approval requested in Codex"
    return event


def cli_path(argv):
    if len(argv) == 3 and argv[1] == "--cli":
        return argv[2]
    if len(argv) != 1:
        return None
    return os.environ.get("SI_NOTCH_CLI") or str(Path(__file__).resolve().parents[2] / "Helpers" / "si-notchctl")


def permission_decision(hook, cli, runner=subprocess.run):
    """No decision means Codex retains its normal approval flow."""
    session = safe_identifier(hook.get("session_id"))
    tool = hook.get("tool_name")
    tool_input = hook.get("tool_input")
    if not session or len(session) > 160 or not isinstance(tool, str) or not SAFE_TOOL.fullmatch(tool):
        return {}
    if not isinstance(tool_input, dict) or not tool_input:
        return {}
    try:
        preview = json.dumps(tool_input, ensure_ascii=True, sort_keys=True, indent=2, allow_nan=False)
    except (TypeError, ValueError, RecursionError):
        return {}
    # Never offer Allow for an elided or partial command.
    if len(preview.encode("utf-8")) > MAX_PERMISSION_BYTES:
        return {}
    request_id = uuid.uuid4().hex
    event = {"event": "approval.request", "provider": "codex", "session_id": session,
             "id": "codex-permission-" + request_id, "request_id": request_id, "approval_id": request_id,
             "tool_name": tool, "title": "Codex permission: " + tool,
             "message": tool + "\n" + preview}
    cwd = hook.get("cwd")
    if isinstance(cwd, str) and os.path.isabs(cwd) and len(cwd.encode("utf-8")) <= 4096 and "\x00" not in cwd:
        event["cwd"] = cwd
    try:
        result = runner([cli, "request", "--timeout", str(PERMISSION_SECONDS)],
                        input=json.dumps(event, separators=(",", ":")), text=True, capture_output=True,
                        timeout=PERMISSION_SECONDS + 5, check=False)
        if result.returncode not in (0, 1) or len(result.stdout) > 4096:
            return {}
        reply = json.loads(result.stdout)
    except (OSError, subprocess.TimeoutExpired, TypeError, ValueError):
        return {}
    if not isinstance(reply, dict) or reply.get("ok") is not True or reply.get("request_id") != request_id:
        return {}
    decision = reply.get("decision")
    if (decision, result.returncode) not in (("allow", 0), ("deny", 1)):
        return {}
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": decision}}}


def main(argv=None):
    argv = sys.argv if argv is None else argv
    try:
        raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
        if not raw or len(raw) > MAX_INPUT_BYTES:
            return 0
        hook = json.loads(raw)
        cli = cli_path(argv)
        if not cli or not os.path.isabs(cli) or not os.access(cli, os.X_OK):
            return 0
        if isinstance(hook, dict) and hook.get("hook_event_name") == "PermissionRequest":
            print(json.dumps(permission_decision(hook, cli), separators=(",", ":")))
            return 0
        event = event_from_hook(hook)
        if not event:
            return 0
        data = json.dumps(event, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        if len(data) > MAX_EVENT_BYTES:
            return 0
        subprocess.run([cli, "emit"], input=data, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=TIMEOUT_SECONDS, check=False)
    except (OSError, ValueError, TypeError, subprocess.TimeoutExpired):
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
