"""Contract and local-socket tests for the observer-only harness adapter."""

import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/adapters/harness-hook.py"
spec = importlib.util.spec_from_file_location("harness_hook", SCRIPT)
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class HookContractTests(unittest.TestCase):
    def test_documented_lifecycle_payloads_and_privacy_allowlist(self):
        samples = [
            ("gemini", "BeforeAgent", {"hook_event_name": "BeforeAgent", "session_id": "gemini-1",
                                         "cwd": "/work/gemini", "prompt": "PRIVATE PROMPT"}, "agent.working"),
            ("copilot", "agentStop", {"sessionId": "copilot-1", "cwd": "/work/copilot",
                                      "transcriptPath": "/private/transcript", "stopReason": "end_turn"}, "agent.completed"),
            ("cursor", "stop", {"hook_event_name": "stop", "conversation_id": "cursor-1",
                                   "workspace_roots": ["/work/cursor"], "status": "error",
                                   "text": "PRIVATE RESPONSE", "error_message": "PRIVATE ERROR"}, "agent.failed"),
        ]
        for source, hook, payload, kind in samples:
            with self.subTest(source=source):
                event = adapter.normalized_event(source, hook, payload)
                self.assertEqual(event, {"event": kind, "session_id": payload.get("conversation_id") or
                                        payload.get("sessionId") or payload.get("session_id"),
                                        "provider": source, "cwd": payload.get("cwd") or payload["workspace_roots"][0]
                                        if source == "cursor" else payload.get("cwd")})
                serialized = json.dumps(event)
                for private in ("PRIVATE", "transcript", "response", "error_message"):
                    self.assertNotIn(private, serialized)

    def test_only_documented_attention_and_terminal_states_are_mapped(self):
        self.assertEqual(adapter.normalized_event("gemini", "Notification", {
            "hook_event_name": "Notification", "session_id": "s", "notification_type": "ToolPermission"
        })["event"], "agent.waiting")
        self.assertIsNone(adapter.normalized_event("gemini", "Notification", {
            "hook_event_name": "Notification", "session_id": "s", "notification_type": "Other"
        }))
        self.assertIsNone(adapter.normalized_event("copilot", "notification", {
            "sessionId": "s", "notification_type": "agent_completed"
        }))
        self.assertEqual(adapter.normalized_event("cursor", "stop", {
            "hook_event_name": "stop", "session_id": "s", "status": "aborted"
        })["event"], "agent.waiting")
        self.assertIsNone(adapter.normalized_event("cursor", "stop", {
            "hook_event_name": "beforeSubmitPrompt", "conversation_id": "s", "status": "completed"
        }))
        self.assertIsNone(adapter.normalized_event("gemini", "AfterAgent", {
            "hook_event_name": "AfterAgent", "session_id": "bad\nID"
        }))

    def test_malformed_input_or_missing_helper_returns_empty_json_and_success(self):
        for raw in ("not-json", '{"session_id":"s"}', "{}"):
            with self.subTest(raw=raw):
                result = subprocess.run([sys.executable, str(SCRIPT), "--source", "gemini", "--event", "AfterAgent",
                                         "--helper", "/nonexistent/si-notchctl"], input=raw, text=True,
                                        capture_output=True, timeout=3)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "{}\n", ""))

        cursor = subprocess.run([sys.executable, str(SCRIPT), "--source", "cursor",
                                 "--event", "beforeSubmitPrompt", "--helper", "/nonexistent/si-notchctl"],
                                input="not-json", text=True, capture_output=True, timeout=3)
        self.assertEqual((cursor.returncode, cursor.stdout, cursor.stderr), (0, '{"continue":true}\n', ""))

    def test_slow_helper_is_bounded_and_hook_stays_fail_open(self):
        with tempfile.TemporaryDirectory(prefix="si-notch-slow-", dir="/private/tmp") as directory:
            slow_helper = Path(directory) / "slow-helper"
            slow_helper.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(3)\n")
            slow_helper.chmod(0o700)
            started = time.monotonic()
            result = subprocess.run([sys.executable, str(SCRIPT), "--source", "cursor", "--event",
                                     "beforeSubmitPrompt", "--helper", str(slow_helper)],
                                    input='{"hook_event_name":"beforeSubmitPrompt","conversation_id":"s"}',
                                    text=True, capture_output=True, timeout=2)
            self.assertLess(time.monotonic() - started, 1.6)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '{"continue":true}\n', ""))

    @unittest.skipUnless(os.environ.get("SI_NOTCH_HELPER"), "set SI_NOTCH_HELPER to test the built helper")
    def test_actual_helper_receives_whitelisted_events_and_acknowledges(self):
        helper = Path(os.environ["SI_NOTCH_HELPER"]).resolve()
        self.assertTrue(helper.is_file() and os.access(helper, os.X_OK))
        events = []
        errors = []
        with tempfile.TemporaryDirectory(prefix="si-notch-harness-", dir="/private/tmp") as directory:
            os.chmod(directory, 0o700)
            endpoint = str(Path(directory) / "events.sock")
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(endpoint)
            os.chmod(endpoint, 0o600)
            listener.listen(4)
            listener.settimeout(3)

            def serve():
                try:
                    for _ in range(4):
                        connection, _ = listener.accept()
                        with connection:
                            connection.settimeout(2)
                            frame = bytearray()
                            while b"\n" not in frame:
                                chunk = connection.recv(8192)
                                if not chunk:
                                    raise AssertionError("helper closed before complete frame")
                                frame.extend(chunk)
                            events.append(json.loads(bytes(frame).split(b"\n", 1)[0]))
                            connection.sendall(b'{"ok":true,"disposition":"applied"}\n')
                except Exception as error:
                    errors.append(error)

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            try:
                cases = [
                    ("gemini", "AfterAgent", {"hook_event_name": "AfterAgent", "session_id": "g-1",
                                              "cwd": "/work/g", "prompt": "PRIVATE PROMPT",
                                              "prompt_response": "PRIVATE RESPONSE"}),
                    ("copilot", "agentStop", {"sessionId": "co-1", "cwd": "/work/co",
                                              "transcriptPath": "/private/transcript"}),
                    ("cursor", "stop", {"hook_event_name": "stop", "conversation_id": "cu-1",
                                        "workspace_roots": ["/work/cu"], "status": "completed", "text": "PRIVATE RESPONSE"}),
                    ("cursor", "beforeSubmitPrompt", {"hook_event_name": "beforeSubmitPrompt",
                                                      "conversation_id": "cu-2", "workspace_roots": ["/work/cu"],
                                                      "prompt": "PRIVATE PROMPT"}),
                ]
                for source, hook, payload in cases:
                    result = subprocess.run([sys.executable, str(SCRIPT), "--source", source, "--event", hook,
                                             "--helper", str(helper)], input=json.dumps(payload), text=True,
                                            env=os.environ | {"SI_NOTCH_SOCKET": endpoint},
                                            capture_output=True, timeout=3)
                    expected = '{"continue":true}\n' if source == "cursor" and hook == "beforeSubmitPrompt" else "{}\n"
                    self.assertEqual((result.returncode, result.stdout, result.stderr), (0, expected, ""))
                thread.join(timeout=3)
                self.assertFalse(thread.is_alive())
                self.assertEqual(errors, [])
                self.assertEqual([(e["provider"], e["event"], e["session_id"]) for e in events],
                                 [("gemini", "agent.completed", "g-1"),
                                  ("copilot", "agent.completed", "co-1"),
                                  ("cursor", "agent.completed", "cu-1"),
                                  ("cursor", "agent.working", "cu-2")])
                for event in events:
                    # emit adds its own receive timestamp after the adapter's allowlist.
                    self.assertEqual(set(event), {"provider", "event", "session_id", "cwd", "timestamp"})
            finally:
                listener.close()


if __name__ == "__main__":
    unittest.main()
