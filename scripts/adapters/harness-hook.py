#!/usr/bin/env python3
"""Observer-only bridge from documented harness hook JSON to si-notchctl emit.

The response is `{}`, except Cursor beforeSubmitPrompt's required fail-open
`{"continue":true}`. No prompt, tool input, result, error, or assistant text is
passed to si-notch. This adapter never makes a permission decision.
"""

import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys


MAX_INPUT_BYTES = 128 * 1024
HELPER_TIMEOUT_SECONDS = 1.2

EVENTS = {
    "gemini": {
        "SessionStart": "session.start",
        "BeforeAgent": "agent.working",
        "AfterAgent": "agent.completed",
        "Notification": "agent.waiting",
        "SessionEnd": "session.end",
    },
    "copilot": {
        "sessionStart": "session.start",
        "userPromptSubmitted": "agent.working",
        "agentStop": "agent.completed",
        "notification": "agent.waiting",
        "sessionEnd": "session.end",
    },
    "cursor": {
        "sessionStart": "session.start",
        "beforeSubmitPrompt": "agent.working",
        "stop": "agent.completed",
        "sessionEnd": "session.end",
    },
}


def normalized_event(source: str, hook: str, raw: object) -> dict | None:
    if not isinstance(raw, dict) or hook not in EVENTS[source]:
        return None
    actual_hook = raw.get("hook_event_name")
    if actual_hook is not None and actual_hook != hook:
        return None
    session_id = raw.get("conversation_id", raw.get("session_id")) if source == "cursor" else raw.get("sessionId", raw.get("session_id"))
    if not isinstance(session_id, str) or not session_id or len(session_id) > 256 or any(ord(c) < 32 for c in session_id):
        return None

    kind = EVENTS[source][hook]
    if source == "gemini" and hook == "Notification" and raw.get("notification_type") != "ToolPermission":
        return None
    if source == "copilot" and hook == "notification" and raw.get("notification_type") not in ("permission_prompt", "elicitation_dialog"):
        return None
    if source == "cursor" and hook == "stop":
        status = raw.get("status")
        if status == "error":
            kind = "agent.failed"
        elif status == "aborted":
            kind = "agent.waiting"
        elif status != "completed":
            return None

    event = {"event": kind, "session_id": session_id, "provider": source}
    model = raw.get("model", raw.get("model_name"))
    if isinstance(model, str) and 0 < len(model.encode("utf-8")) <= 256 and not any(ord(c) < 32 or ord(c) == 127 for c in model):
        event["model"] = model
    effort = raw.get("reasoning_effort")
    if isinstance(effort, str) and effort in {"none", "off", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"}:
        event["reasoning_effort"] = effort
    cwd = raw.get("cwd")
    if source == "cursor":
        roots = raw.get("workspace_roots")
        cwd = roots[0] if isinstance(roots, list) and len(roots) == 1 else None
    if isinstance(cwd, str) and cwd.startswith("/") and len(cwd) <= 4096 and "\x00" not in cwd:
        event["cwd"] = cwd
    return event


def main() -> int:
    output = {}
    try:
        parser = argparse.ArgumentParser(description=__doc__, add_help=False)
        parser.add_argument("--source", choices=EVENTS, required=True)
        parser.add_argument("--event", required=True)
        parser.add_argument("--helper", type=Path, required=True)
        with contextlib.redirect_stderr(io.StringIO()):
            args = parser.parse_args()
        if args.source == "cursor" and args.event == "beforeSubmitPrompt":
            output = {"continue": True}
        incoming = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
        if len(incoming) <= MAX_INPUT_BYTES and args.event in EVENTS[args.source]:
            event = normalized_event(args.source, args.event, json.loads(incoming))
            helper = args.helper
            if event is not None and helper.is_absolute() and helper.is_file() and os.access(helper, os.X_OK):
                subprocess.run([str(helper), "emit"], input=json.dumps(event, separators=(",", ":")),
                               text=True, capture_output=True, timeout=HELPER_TIMEOUT_SECONDS, check=False)
    except (OSError, ValueError, TypeError, SystemExit, subprocess.TimeoutExpired):
        pass  # Hook observation never changes harness behavior.
    sys.stdout.write(json.dumps(output, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
