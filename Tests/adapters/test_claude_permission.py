"""Contract tests for the optional Claude PermissionRequest adapter."""

import importlib.util
from pathlib import Path
import subprocess
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "claude-permission.py"
SPEC = importlib.util.spec_from_file_location("claude_permission", SCRIPT)
adapter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(adapter)


def sample(command="npm test"):
    return {
        "hook_event_name": "PermissionRequest",
        "session_id": "session-123",
        "tool_name": "Bash",
        "tool_input": {"command": command},
        "cwd": "/tmp/example",
    }


class PermissionAdapterTests(unittest.TestCase):
    def runner_for(self, decision, exit_code):
        def runner(args, **kwargs):
            self.assertEqual(args[:2], ["/tmp/si-notchctl", "request"])
            self.assertEqual(kwargs["timeout"], adapter.PROCESS_SECONDS)
            import json
            event = json.loads(kwargs["input"])
            self.assertEqual(event["provider"], "claude")
            self.assertEqual(event["session_id"], "session-123")
            self.assertEqual(event["message"], 'Bash requests permission for:\n{"command":"npm test"}')
            self.assertEqual(event["approval_id"], event["request_id"])
            return subprocess.CompletedProcess(args, exit_code, json.dumps({
                "ok": True, "decision": decision, "request_id": event["request_id"]
            }), "")
        return runner

    def test_explicit_allow(self):
        result = adapter.decision_for(sample(), "/tmp/si-notchctl", self.runner_for("allow", 0))
        self.assertEqual(result["hookSpecificOutput"]["decision"], {"behavior": "allow"})

    def test_explicit_deny(self):
        result = adapter.decision_for(sample(), "/tmp/si-notchctl", self.runner_for("deny", 1))
        self.assertEqual(result["hookSpecificOutput"]["decision"], {"behavior": "deny"})

    def test_no_decision_for_bad_or_incomplete_input(self):
        for payload in (None, {}, {**sample(), "hook_event_name": "PreToolUse"},
                        {**sample(), "session_id": "../bad"},
                        {**sample(), "tool_name": []},
                        {**sample(), "tool_name": "AskUserQuestion"},
                        {**sample(), "tool_input": {}},
                        sample("a" * 300)):
            with self.subTest(payload=payload):
                self.assertEqual(adapter.decision_for(payload, "/tmp/si-notchctl",
                                                      lambda *a, **kw: self.fail("unexpected request")), {})

    def test_no_decision_for_error_timeout_or_mismatched_reply(self):
        cases = [subprocess.CompletedProcess([], 2, "", ""),
                 subprocess.CompletedProcess([], 0, '{"ok":true,"decision":"allow","request_id":"wrong"}', ""),
                 subprocess.CompletedProcess([], 0, '{"ok":false,"decision":"allow"}', ""),
                 subprocess.CompletedProcess([], 1, '{"ok":true,"decision":"allow"}', ""),
                 subprocess.CompletedProcess([], 0, "broken", "")]
        for outcome in cases:
            with self.subTest(outcome=outcome):
                self.assertEqual(adapter.decision_for(sample(), "/tmp/si-notchctl",
                    lambda *a, **kw: outcome), {})
        def timed_out(*_args, **_kwargs):
            raise subprocess.TimeoutExpired("request", 75)
        self.assertEqual(adapter.decision_for(sample(), "/tmp/si-notchctl", timed_out), {})


if __name__ == "__main__":
    unittest.main()
