#!/usr/bin/env python3
"""No account, app, or model required. All traffic uses a temporary private socket."""
from contextlib import contextmanager
import errno
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
from unittest.mock import patch
from types import SimpleNamespace

from agent import Agent, BridgeError, MAX_BYTES, exchange


@contextmanager
def server(responder):
    with tempfile.TemporaryDirectory(prefix="sn-example-") as temporary:
        root = Path(temporary).resolve()
        os.chmod(root, 0o700)
        path = str(root / "events.sock")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(path)
        except BaseException:
            listener.close()
            raise
        os.chmod(path, 0o600)
        listener.listen(4)
        listener.settimeout(0.1)
        stop = threading.Event()
        events, failures = [], []

        def work():
            while not stop.is_set():
                try:
                    peer, _ = listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    return
                try:
                    with peer:
                        peer.settimeout(1)
                        frame = bytearray()
                        while b"\n" not in frame:
                            part = peer.recv(4096)
                            if not part:
                                raise AssertionError("Incomplete request frame")
                            frame.extend(part)
                            if len(frame) > MAX_BYTES:
                                raise AssertionError("Oversized request")
                        event = json.loads(frame)
                        events.append(event)
                        response = responder(event)
                        if response is not None:
                            peer.sendall(json.dumps(response).encode() + b"\n")
                except (BrokenPipeError, ConnectionResetError):
                    pass  # Expected when the client deadline is exercised.
                except Exception as error:
                    failures.append(error)

        worker = threading.Thread(target=work)
        worker.start()
        try:
            yield path, events
        finally:
            stop.set()
            listener.close()
            worker.join(2)
            if worker.is_alive():
                raise AssertionError("Mock server failed to stop")
            if failures:
                raise failures[0]


def accepted(event):
    return {"ok": True, "disposition": "usage_committed" if event["event"] == "usage.update" else "applied"}


class ExampleTests(unittest.TestCase):
    def test_complete_walkthrough_over_real_socket(self):
        with server(accepted) as (path, events):
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("agent.py")), "--socket", path],
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(events[0]["event"], "session.start")
            self.assertEqual(events[-2]["event"], "agent.completed")
            self.assertEqual(events[-1]["event"], "session.end")
            self.assertEqual(len({e["session_id"] for e in events}), 1)
            self.assertEqual([e["sequence"] for e in events], list(range(1, len(events) + 1)))
            self.assertEqual(len({e["id"] for e in events}), len(events))

    def test_ambiguous_observation_can_resend_same_envelope(self):
        seen = set()
        def responder(event):
            disposition = "duplicate" if event["id"] in seen else "applied"
            seen.add(event["id"])
            return {"ok": True, "disposition": disposition}
        with server(responder) as (path, events):
            agent = Agent(path)
            event = agent.event("agent.working")
            agent.deliver(event)
            self.assertEqual(agent.deliver(event)["disposition"], "duplicate")
            self.assertEqual(events[0], events[1])

    def test_usage_requires_durable_acknowledgement(self):
        with server(lambda _: {"ok": True, "disposition": "applied"}) as (path, _):
            with self.assertRaises(BridgeError):
                Agent(path).emit("usage.update", usage={"request_id": "request-1", "input_tokens": 10, "output_tokens": 2})

    def test_question_accepts_only_matching_nonempty_answer(self):
        with server(lambda e: {"ok": True, "request_id": e["request_id"], "decision": "answer", "answer": "Example"}) as (path, _):
            self.assertEqual(Agent(path).ask("Label?"), "Example")
        for reply in ({"ok": True, "request_id": "other", "decision": "allow"},
                      {"ok": True, "decision": "answer", "answer": " "},
                      {"ok": False, "decision": "timeout"}):
            with self.subTest(reply=reply):
                with server(lambda e: {"request_id": e["request_id"], **reply}) as (path, _):
                    with self.assertRaises(BridgeError):
                        Agent(path).ask("Label?")

    def test_denial_and_disconnect_never_become_answers(self):
        with server(lambda e: {"ok": True, "request_id": e["request_id"], "decision": "deny"}) as (path, _):
            self.assertIsNone(Agent(path).ask("Label?"))
        with server(lambda _: None) as (path, _):
            with self.assertRaises(BridgeError):
                Agent(path).ask("Label?")

    def test_ack_is_read_after_macos_shutdown_race(self):
        native_socket = socket.socket
        class ShutdownRace:
            def __init__(self, *args):
                self.peer = native_socket(*args)
            def __getattr__(self, name):
                return getattr(self.peer, name)
            def __enter__(self):
                return self
            def __exit__(self, *args):
                self.peer.close()
            def shutdown(self, _):
                raise OSError(errno.ENOTCONN, "Peer already closed")
        api = SimpleNamespace(socket=ShutdownRace, AF_UNIX=socket.AF_UNIX,
                              SOCK_STREAM=socket.SOCK_STREAM, SHUT_WR=socket.SHUT_WR)
        with server(accepted) as (path, _):
            with patch("agent.socket", api):
                self.assertEqual(Agent(path).emit("agent.working")["disposition"], "applied")

    def test_transport_deadline_is_bounded(self):
        def delayed(_):
            time.sleep(0.15)
            return {"ok": True}
        with server(delayed) as (path, _):
            with self.assertRaises(TimeoutError):
                exchange(path, {"command": "status"}, timeout=0.03)

    def test_explicit_socket_and_private_permissions_required(self):
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("agent.py"))], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        with server(accepted) as (path, events):
            os.chmod(path, 0o666)
            with self.assertRaises(BridgeError):
                Agent(path).emit("session.start")
            self.assertEqual(events, [])


if __name__ == "__main__":
    unittest.main()
