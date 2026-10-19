import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "scripts/adapters/codex-hook.py"
spec = importlib.util.spec_from_file_location("codex_hook", ADAPTER)
hook_adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook_adapter)


class CodexHookTests(unittest.TestCase):
    def permission(self):
        return {"hook_event_name": "PermissionRequest", "session_id": "thread_123", "tool_name": "Bash",
                "cwd": "/tmp/project", "tool_input": {"command": "printf approval-smoke", "description": "Local harmless check"}}

    def test_permission_roundtrip_uses_exact_request_and_complete_input(self):
        for decision, code in (("allow", 0), ("deny", 1)):
            seen = []
            def runner(args, **kwargs):
                event = json.loads(kwargs["input"])
                seen.append(event)
                self.assertEqual(args[1:], ["request", "--timeout", "70"])
                self.assertEqual(event["event"], "approval.request")
                return SimpleNamespace(returncode=code, stdout=json.dumps({"ok": True, "decision": decision, "request_id": event["request_id"]}))
            payload = self.permission()
            payload["tool_input"]["command"] += "x" * 600
            result = hook_adapter.permission_decision(payload, "/tmp/helper", runner)
            self.assertEqual(result["hookSpecificOutput"]["decision"]["behavior"], decision)
            self.assertEqual(json.loads(seen[0]["message"].split("\n", 1)[1]), payload["tool_input"])

    def test_permission_never_accepts_stale_invalid_or_implicit_decisions(self):
        for reply, code in (({"ok": True, "decision": "allow", "request_id": "stale"}, 0),
                            ({"ok": True, "decision": "allow"}, 0),
                            ({"ok": False, "decision": "allow"}, 0),
                            ({"ok": True, "decision": "allow"}, 2)):
            result = hook_adapter.permission_decision(self.permission(), "/tmp/helper",
                lambda *a, **kw: SimpleNamespace(returncode=code, stdout=json.dumps(reply)))
            self.assertEqual(result, {})
        def unavailable(*a, **kw):
            raise subprocess.TimeoutExpired("helper", 75)
        self.assertEqual(hook_adapter.permission_decision(self.permission(), "/tmp/helper", unavailable), {})
        oversized = self.permission()
        oversized["tool_input"]["command"] = "x" * 13000
        self.assertEqual(hook_adapter.permission_decision(oversized, "/tmp/helper", lambda *a, **kw: self.fail("Must not present partial input")), {})

    def test_lifecycle_mapping_copies_only_supported_bounded_summaries(self):
        cases = {
            "SessionStart": "session.start",
            "UserPromptSubmit": "agent.working",
            "PreToolUse": "tool.start",
            "PostToolUse": "tool.finish",
            "PermissionRequest": "agent.waiting",
            "Stop": "agent.completed",
            "Interrupt": "session.start",
            "SessionEnd": "session.end",
        }
        for name, expected in cases.items():
            with self.subTest(name=name):
                payload = {
                    "hook_event_name": name, "session_id": "thread_123", "turn_id": "turn_456",
                    "cwd": "/tmp/project", "model": "gpt-6.1-sol", "tool_name": "Bash",
                    "prompt": "PRIVATE_PROMPT", "tool_input": {"command": "PRIVATE_COMMAND"},
                    "tool_response": "PRIVATE_OUTPUT", "last_assistant_message": "PRIVATE_ANSWER",
                    "transcript_path": "/tmp/PRIVATE_TRANSCRIPT", "permission_mode": "bypassPermissions",
                }
                event = hook_adapter.event_from_hook(payload)
                self.assertEqual(event["event"], expected)
                self.assertEqual(event["provider"], "codex")
                self.assertEqual(event["session_id"], "thread_123")
                self.assertEqual(event["cwd"], "/tmp/project")
                self.assertEqual(event["model"], "gpt-6.1-sol")
                serialized = json.dumps(event)
                for secret in ("PRIVATE_COMMAND", "PRIVATE_OUTPUT",
                               "PRIVATE_TRANSCRIPT", "bypassPermissions"):
                    self.assertNotIn(secret, serialized)
                self.assertNotIn("approval_id", event)
                self.assertNotIn("await_response", event)

    def test_summary_redaction_bounds_and_title_is_not_overwritten(self):
        prompt = "Fix auth\n token=example-secret sk-abcdefghijklmnopqrstuvwxyz " + "я" * 1000
        event = hook_adapter.event_from_hook({"hook_event_name": "UserPromptSubmit", "session_id": "thread_123", "prompt": prompt})
        self.assertLessEqual(len(event["title"]), 100)
        self.assertLessEqual(len(event["message"]), 600)
        self.assertNotIn("example-secret", json.dumps(event))
        self.assertNotIn("sk-abcdefghijklmnopqrstuvwxyz", json.dumps(event))
        self.assertIn("[redacted]", event["message"])
        result = hook_adapter.event_from_hook({"hook_event_name": "Stop", "session_id": "thread_123", "last_assistant_message": "Fixed and tested."})
        self.assertEqual(result["message"], "Fixed and tested.")
        self.assertNotIn("title", result)
        tool = hook_adapter.event_from_hook({"hook_event_name": "PreToolUse", "session_id": "thread_123", "prompt": "must not copy", "tool_name": "Read"})
        self.assertNotIn("title", tool)
        self.assertNotIn("message", tool)

    def test_invalid_session_and_unsafe_metadata_are_rejected(self):
        self.assertIsNone(hook_adapter.event_from_hook({"hook_event_name": "Stop", "session_id": "bad id"}))
        self.assertIsNone(hook_adapter.event_from_hook({"hook_event_name": "Other", "session_id": "thread_123"}))
        event = hook_adapter.event_from_hook({"hook_event_name": "PreToolUse", "session_id": "thread_123",
                                              "cwd": "relative", "model": "bad\nmodel", "tool_name": "bad tool"})
        self.assertNotIn("cwd", event)
        self.assertNotIn("model", event)
        self.assertNotIn("tool_name", event)

    def test_subprocess_receives_summary_and_hook_is_fail_open(self):
        with tempfile.TemporaryDirectory(prefix="si-notch-codex-hook-") as directory:
            output = Path(directory) / "event.json"
            helper = Path(directory) / "si-notchctl"
            helper.write_text('#!/bin/sh\n/bin/cat > "$FIXTURE_OUTPUT"\n')
            helper.chmod(0o700)
            env = {**os.environ, "SI_NOTCH_CLI": str(helper), "FIXTURE_OUTPUT": str(output)}
            payload = {"hook_event_name": "UserPromptSubmit", "session_id": "thread_123",
                       "prompt": "PRIVATE_PROMPT", "cwd": "/tmp/project"}
            result = subprocess.run([sys.executable, str(ADAPTER)], input=json.dumps(payload).encode(),
                                    capture_output=True, env=env, timeout=5)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")
            self.assertEqual(result.stderr, b"")
            actual = json.loads(output.read_bytes())
            self.assertEqual(actual["event"], "agent.working")
            self.assertEqual(actual["title"], "PRIVATE_PROMPT")

            output.unlink()
            invalid = subprocess.run([sys.executable, str(ADAPTER)], input=b"{bad json",
                                     capture_output=True, env=env, timeout=5)
            self.assertEqual(invalid.returncode, 0)
            self.assertEqual(invalid.stdout, b"")
            self.assertFalse(output.exists())

            oversized = subprocess.run([sys.executable, str(ADAPTER)], input=b"x" * (129 * 1024),
                                      capture_output=True, env=env, timeout=5)
            self.assertEqual(oversized.returncode, 0)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
