"""Portable relay deadlines and request identity using private fixture sockets."""

import contextlib
import errno
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest
from unittest import mock


SOURCE = Path(__file__).resolve().parents[2] / "plugins/hermes/relay.py"
spec = importlib.util.spec_from_file_location("remote_relay_test", SOURCE)
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)


class RemoteRelayTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="notch-relay-", dir="/private/tmp")
        self.addCleanup(self.directory.cleanup)
        self.path = str(Path(self.directory.name) / "events.sock")

    def server(self, reply):
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(self.path); os.chmod(self.path, 0o600); listener.listen(1); listener.settimeout(2)
        self.addCleanup(listener.close)
        self.seen, self.errors = [], []

        def serve():
            try:
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(2)
                    incoming = bytearray()
                    while b"\n" not in incoming:
                        chunk = connection.recv(8192)
                        if not chunk:
                            raise AssertionError("relay disconnected before sending an event")
                        incoming.extend(chunk)
                    self.seen.append(json.loads(incoming))
                    reply(connection)
            except (BrokenPipeError, ConnectionResetError):
                pass  # The deadline test deliberately closes before the final reply.
            except Exception as error:
                self.errors.append(error)

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 2)
        return thread

    def test_complete_acknowledgement_is_received(self):
        thread = self.server(lambda connection: connection.sendall(b'{"ok":true}\n'))
        event = {"event": "agent.completed", "session_id": "fixture"}
        self.assertEqual(relay.exchange(event, self.path, .5), {"ok": True})
        thread.join(2)
        self.assertEqual(self.seen, [event]); self.assertEqual(self.errors, [])

    def test_peer_close_before_half_close_keeps_the_buffered_acknowledgement(self):
        thread = self.server(lambda connection: connection.sendall(b'{"ok":true}\n'))
        with mock.patch.object(relay.socket.socket, "shutdown", side_effect=OSError(errno.ENOTCONN, "Socket is not connected")):
            result = relay.exchange({"event": "agent.completed", "session_id": "fixture"}, self.path, .5)
        thread.join(2)
        self.assertEqual(result, {"ok": True}); self.assertEqual(self.errors, [])

    def test_partial_reply_does_not_extend_the_total_deadline(self):
        def trickle(connection):
            for _ in range(6):
                time.sleep(.04)
                connection.sendall(b' ')
            connection.sendall(b'{"ok":true}\n')
        thread = self.server(trickle)
        with self.assertRaises(TimeoutError):
            relay.exchange({"event": "agent.completed", "session_id": "fixture"}, self.path, .15)
        thread.join(2)
        self.assertEqual(self.errors, [])

    def test_disconnect_without_acknowledgement_is_an_error(self):
        thread = self.server(lambda connection: None)
        with self.assertRaisesRegex(relay.RelayError, "closed before acknowledgement"):
            relay.exchange({"event": "agent.completed", "session_id": "fixture"}, self.path, .5)
        thread.join(2)
        self.assertEqual(self.errors, [])

    def test_permission_reply_must_match_the_pending_request(self):
        event = json.dumps({"session_id": "fixture", "request_id": "expected"})
        for identity, decision, expected in [("expected", "allow", 0), ("expected", "deny", 1),
                                              ("other", "allow", 2), ("expected", "unexpected", 2)]:
            with self.subTest(identity=identity, decision=decision), \
                 mock.patch.object(relay.sys, "argv", ["relay", "request", event, "--timeout", ".2"]), \
                 mock.patch.object(relay, "exchange", return_value={"ok": True, "request_id": identity, "decision": decision}), \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(relay.main(), expected)


if __name__ == "__main__":
    unittest.main()
