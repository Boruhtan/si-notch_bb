#!/usr/bin/env python3
"""Opt-in Claude PermissionRequest hook. Only a verified UI click decides."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import uuid


MAX_INPUT_BYTES = 128 * 1024
MAX_PREVIEW_CHARS = 240  # The card displays at most eight lines: never elide input.
REQUEST_SECONDS = 70
PROCESS_SECONDS = 75
TOOL_NAMES = {"Bash", "Read", "Write", "Edit", "MultiEdit", "NotebookEdit"}
IDENTIFIER = re.compile(r"[A-Za-z0-9._:-]{1,160}\Z")
FALLBACK = {}


def decision_for(payload, cli_path, runner=subprocess.run):
    """Return a Claude hook decision, or no decision for Claude's native prompt."""
    if not isinstance(payload, dict) or payload.get("hook_event_name") != "PermissionRequest":
        return FALLBACK
    session_id = payload.get("session_id")
    tool_name = payload.get("tool_name")
    tool_input = payload.get("tool_input")
    if not isinstance(session_id, str) or not IDENTIFIER.fullmatch(session_id):
        return FALLBACK
    if not isinstance(tool_name, str) or tool_name not in TOOL_NAMES or not isinstance(tool_input, dict) or not tool_input:
        return FALLBACK
    try:
        preview = json.dumps(tool_input, ensure_ascii=True, sort_keys=True, separators=(",", ":"), allow_nan=False)
    except (TypeError, ValueError, RecursionError):
        return FALLBACK
    if len(preview) > MAX_PREVIEW_CHARS:
        return FALLBACK

    request_id = str(uuid.uuid4())
    event = {
        "event": "approval.request",
        "provider": "claude",
        "session_id": session_id,
        "request_id": request_id,
        "approval_id": request_id,
        "title": "Claude permission: " + tool_name,
        "tool_name": tool_name,
        "message": tool_name + " requests permission for:\n" + preview,
    }
    cwd = payload.get("cwd")
    if isinstance(cwd, str) and cwd.startswith("/") and len(cwd) <= 4096 and not any(ord(c) < 32 for c in cwd):
        event["cwd"] = cwd
    try:
        result = runner(
            [cli_path, "request", "--timeout", str(REQUEST_SECONDS)],
            input=json.dumps(event, ensure_ascii=True),
            text=True,
            capture_output=True,
            timeout=PROCESS_SECONDS,
            check=False,
        )
        if result.returncode not in (0, 1) or len(result.stdout) > 4096:
            return FALLBACK
        reply = json.loads(result.stdout)
    except (OSError, subprocess.TimeoutExpired, TypeError, ValueError):
        return FALLBACK
    if not isinstance(reply, dict) or reply.get("ok") is not True or reply.get("request_id") != request_id:
        return FALLBACK
    choice = reply.get("decision")
    if (choice, result.returncode) not in (("allow", 0), ("deny", 1)):
        return FALLBACK
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": choice}}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, help="absolute path to the installed si-notchctl")
    args = parser.parse_args()
    # A missing/misconfigured helper should leave Claude's own prompt intact.
    if not Path(args.cli).is_absolute():
        print("{}")
        return 0
    try:
        raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
        payload = json.loads(raw) if len(raw) <= MAX_INPUT_BYTES else None
    except (OSError, ValueError, RecursionError):
        payload = None
    print(json.dumps(decision_for(payload, args.cli), separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
