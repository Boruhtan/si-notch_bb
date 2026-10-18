"""Synthetic Claude hook JSON through the built helper and a private ACK socket."""

import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[2]
PERMISSION = ROOT / "scripts/claude-permission.py"


class ClaudeSocketTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("SI_NOTCH_HELPER"), "set SI_NOTCH_HELPER to test the built helper")
    def test_observer_and_bound_permission_decision(self):
        helper = Path(os.environ["SI_NOTCH_HELPER"]).resolve()
        self.assertTrue(helper.is_file() and os.access(helper, os.X_OK))
        seen = []
        errors = []
        with tempfile.TemporaryDirectory(prefix="si-notch-claude-", dir="/private/tmp") as directory:
            os.chmod(directory, 0o700)
            endpoint = str(Path(directory) / "events.sock")
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(endpoint)
            os.chmod(endpoint, 0o600)
            listener.listen(4)
            listener.settimeout(3)

            def serve():
                try:
                    for index in range(4):
                        connection, _ = listener.accept()
                        with connection:
                            connection.settimeout(2)
                            frame = bytearray()
                            while b"\n" not in frame:
                                part = connection.recv(8192)
                                if not part:
                                    raise AssertionError("helper closed before complete frame")
                                frame.extend(part)
                            event = json.loads(bytes(frame).split(b"\n", 1)[0])
                            seen.append(event)
                            if index in (0, 3):
                                answer = {"ok": True, "disposition": "applied"}
                            else:
                                answer = {"ok": True, "decision": "allow" if index == 1 else "deny",
                                          "request_id": event["request_id"]}
                            connection.sendall(json.dumps(answer).encode() + b"\n")
                except Exception as error:
                    errors.append(error)

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            environment = os.environ | {"SI_NOTCH_SOCKET": endpoint}
            try:
                stop = subprocess.run([str(helper), "hook", "--agent", "claude"],
                                      input=json.dumps({"hook_event_name": "Stop", "session_id": "claude-1",
                                                        "last_assistant_message": "PRIVATE RESPONSE",
                                                        "prompt": "PRIVATE PROMPT",
                                                        "tool_input": {"token": "PRIVATE TOKEN"},
                                                        "tool_response": "PRIVATE TOOL OUTPUT"}),
                                      text=True, capture_output=True, timeout=3, env=environment)
                self.assertEqual((stop.returncode, stop.stdout, stop.stderr), (0, "", ""))

                for choice in ("allow", "deny"):
                    response = subprocess.run([sys.executable, str(PERMISSION), "--cli", str(helper)],
                                              input=json.dumps({"hook_event_name": "PermissionRequest",
                                                                "session_id": "claude-1", "tool_name": "Bash",
                                                                "tool_input": {"command": "npm test"}}),
                                              text=True, capture_output=True, timeout=4, env=environment)
                    self.assertEqual(response.returncode, 0)
                    self.assertEqual(response.stderr, "")
                    result = json.loads(response.stdout)
                    self.assertEqual(result["hookSpecificOutput"]["decision"]["behavior"], choice)

                explicit = subprocess.run([str(helper), "emit", json.dumps({
                    "event": "agent.working", "session_id": "claude-1", "provider": "claude",
                    "message": "INTENTIONAL MESSAGE",
                })], text=True, capture_output=True, timeout=3, env=environment)
                self.assertEqual((explicit.returncode, explicit.stdout, explicit.stderr), (0, "", ""))

                thread.join(timeout=3)
                self.assertFalse(thread.is_alive())
                self.assertEqual(errors, [])
                self.assertEqual([event["event"] if "event" in event else event["hook_event_name"] for event in seen],
                                 ["Stop", "approval.request", "approval.request", "agent.working"])
                self.assertEqual([event.get("await_response") for event in seen], [None, True, True, None])
                self.assertEqual(seen[3]["message"], "INTENTIONAL MESSAGE")
                self.assertIn("Bash requests permission for:", seen[1]["message"])
                for secret in ("PRIVATE RESPONSE", "PRIVATE PROMPT", "PRIVATE TOKEN", "PRIVATE TOOL OUTPUT"):
                    self.assertNotIn(secret, json.dumps(seen))
                self.assertNotEqual(seen[1]["request_id"], seen[2]["request_id"])
            finally:
                listener.close()


if __name__ == "__main__":
    unittest.main()
