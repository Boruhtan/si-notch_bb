#!/usr/bin/env python3
"""Small si-notch producer. Requires an explicit socket; never executes an action.

Run test_agent.py first. The walkthrough uses synthetic token counts.
For a real integration, report the provider's final per-request counters.
"""
from __future__ import annotations

import argparse
import errno
import json
import os
from pathlib import Path
import socket
import stat
import time
import uuid

MAX_BYTES = 128 * 1024


class BridgeError(Exception):
    pass


def exchange(path: str, event: dict, timeout: float = 1.0) -> dict:
    """One bounded newline-delimited JSON request/reply per connection."""
    endpoint = Path(path)
    if not endpoint.is_absolute() or str(endpoint.resolve()) != str(endpoint):
        raise BridgeError("Use an absolute socket path without symlinks")
    for item, expected in ((endpoint.parent, stat.S_ISDIR), (endpoint, stat.S_ISSOCK)):
        info = item.lstat()
        if not expected(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise BridgeError("Socket and parent must be private and owned by this user")
    frame = json.dumps(event, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode() + b"\n"
    if len(frame) > MAX_BYTES:
        raise BridgeError("Payload exceeds 128 KiB")
    deadline = time.monotonic() + timeout
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(path)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Send deadline expired")
        connection.settimeout(remaining)
        connection.sendall(frame)
        try:
            connection.shutdown(socket.SHUT_WR)
        except OSError as error:
            # macOS may report ENOTCONN after the peer has sent its ACK and closed.
            # Drain the buffered reply; every other shutdown error still fails.
            if error.errno != errno.ENOTCONN:
                raise
        received = bytearray()
        while b"\n" not in received:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Reply deadline expired")
            connection.settimeout(remaining)
            chunk = connection.recv(8192)
            if not chunk:
                raise BridgeError("Disconnected before reply")
            received.extend(chunk)
            if len(received) > MAX_BYTES:
                raise BridgeError("Reply exceeds 128 KiB")
    if not received.endswith(b"\n") or received.count(b"\n") != 1:
        raise BridgeError("Expected exactly one reply frame")
    reply = json.loads(received)
    if not isinstance(reply, dict):
        raise BridgeError("Expected a JSON object")
    return reply


class Agent:
    def __init__(self, path: str, session: str | None = None):
        self.path = path
        self.session = session or "example-" + uuid.uuid4().hex
        self.turn = "turn-" + uuid.uuid4().hex
        self.sequence = 0

    def event(self, kind: str, **fields) -> dict:
        self.sequence += 1
        return {"event": kind, "session_id": self.session, "provider": "custom",
                "id": "event-" + uuid.uuid4().hex, "sequence": self.sequence,
                "timestamp": time.time(), "turn_id": self.turn,
                "title": "Custom agent walkthrough", **fields}

    def deliver(self, event: dict) -> dict:
        reply = exchange(self.path, event)
        expected = {"applied", "duplicate"}
        if event.get("event") == "usage.update" and event.get("usage", {}).get("request_id"):
            expected = {"usage_committed"}
        if reply.get("ok") is not True or reply.get("disposition") not in expected:
            raise BridgeError("Event was not accepted: " + str(reply.get("disposition", reply.get("error", "unknown"))))
        return reply

    def emit(self, kind: str, **fields) -> dict:
        return self.deliver(self.event(kind, **fields))

    def ask(self, message: str, timeout: float = 30) -> str | None:
        """Optional free-text question. No retry; no tool execution or approval."""
        if not 0.1 <= timeout <= 110:
            raise ValueError("Timeout must be 0.1–110 seconds")
        request_id = "question-" + uuid.uuid4().hex
        event = self.event("approval.request", request_id=request_id, approval_id=request_id,
                           await_response=True, response_timeout=timeout, question=True, message=message)
        reply = exchange(self.path, event, timeout=timeout + 1)
        if reply.get("request_id") != request_id:
            raise BridgeError("Reply belongs to another request")
        if reply.get("ok") is not True:
            raise BridgeError("Question ended without a decision")
        if reply.get("decision") == "deny":
            return None
        answer = reply.get("answer")
        if reply.get("decision") != "answer" or not isinstance(answer, str) or not answer.strip():
            raise BridgeError("Expected a nonempty answer")
        return answer


def walkthrough(agent: Agent, ask: bool = False) -> None:
    agent.emit("session.start")
    agent.emit("agent.working", message="Checking the example inputs", first_prompt="Check the example inputs")
    agent.emit("task.update", task={"id": "check", "title": "Check inputs", "status": "working"})
    agent.emit("tool.start", tool_name="validate")
    agent.emit("tool.finish", tool_name="validate")
    agent.emit("task.update", task={"id": "check", "title": "Check inputs", "status": "completed"})
    # Synthetic numbers demonstrate the protocol, not an actual provider call.
    agent.emit("usage.update", usage={"request_id": "usage-" + uuid.uuid4().hex,
               "input_tokens": 1200, "output_tokens": 180, "cached_input_tokens": 800})
    if ask:
        answer = agent.ask("What label should this example use?")
        agent.emit("agent.working", message="Answer received" if answer is not None else "Question declined")
    agent.emit("agent.completed", message="Example checks finished")
    agent.emit("session.end")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True, help="Explicit absolute private Unix socket")
    parser.add_argument("--ask", action="store_true", help="Ask one free-text question; never execute its answer")
    args = parser.parse_args()
    try:
        walkthrough(Agent(args.socket), ask=args.ask)
    except (BridgeError, OSError, ValueError) as error:
        parser.exit(2, f"si-notch example: {error}\n")
    print("Walkthrough acknowledged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
