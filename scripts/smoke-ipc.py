#!/usr/bin/env python3
"""Exercise a running si-notch's local socket with disposable synthetic sessions.

Does not launch the app, modify agent settings, or contact a network endpoint.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import socket
import stat
import sys
import time
import uuid

MAXIMUM_FRAME = 128 * 1024


def private_socket(path):
    endpoint = Path(path)
    info = endpoint.lstat()
    parent = endpoint.parent.lstat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError("endpoint must be this user's Unix socket with mode 0600")
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.geteuid() or parent.st_mode & 0o077:
        raise ValueError("socket parent must be this user's private directory (0700)")


def exchange(path, payload, timeout=5, allow_drop=False):
    frame = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode() + b"\n"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(timeout)
        client.connect(path)
        try:
            client.sendall(frame)
            client.shutdown(socket.SHUT_WR)
            response = bytearray()
            while b"\n" not in response:
                chunk = client.recv(4096)
                if not chunk:
                    if allow_drop:
                        return None
                    raise AssertionError("socket closed without a JSON reply")
                response.extend(chunk)
                if len(response) > MAXIMUM_FRAME:
                    raise AssertionError("reply exceeds 128 KiB")
        except (BrokenPipeError, ConnectionResetError):
            if allow_drop:
                return None
            raise
    data = json.loads(bytes(response).split(b"\n", 1)[0])
    if not isinstance(data, dict):
        raise AssertionError("reply is not a JSON object")
    return data


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def run(path, interactive=False, timeout=45):
    private_socket(path)
    prefix = "smoke-" + uuid.uuid4().hex[:12]
    sessions = [prefix + "-status", prefix + "-a", prefix + "-b"]
    counts = {"events": 0, "invalid": 0, "concurrent_requests": 0}

    def event(kind, session=None, **fields):
        value = {"event": kind, "session_id": session or sessions[0], "provider": "custom",
                 "title": "si-notch IPC smoke", **fields}
        reply = exchange(path, value)
        require(reply.get("ok") is True, "event rejected: " + kind + " " + str(reply))
        counts["events"] += 1
        return reply

    try:
        for kind in ("session.start", "agent.working", "tool.start", "tool.finish",
                     "agent.waiting", "approval.request", "agent.completed", "agent.failed"):
            event(kind, message="Synthetic smoke event", tool_name="smoke")
        # Shape-valid JSON reaches the app validator; malformed JSON is dropped by transport.
        for invalid in ({"event": "agent.working"}, {"event": "tool.start", "session_id": []}):
            reply = exchange(path, invalid)
            require(reply.get("ok") is False, "invalid event was accepted")
            counts["invalid"] += 1
        require(exchange(path, b"{broken-json}\n", allow_drop=True) is None,
                "malformed JSON should be dropped")
        counts["invalid"] += 1
        event("agent.working", message="Server still responds after malformed input")

        def request(index):
            sid = sessions[index + 1]
            rid = sid + "-request"
            message = ("Smoke test: choose Allow for A and Deny for B" if interactive else
                       "Synthetic cancellation test; no action will run")
            payload = {"session_id": sid, "provider": "custom", "event": "approval.request",
                       "title": "Smoke " + ("A" if index == 0 else "B"), "message": message,
                       "await_response": True, "request_id": rid, "approval_id": rid}
            reply = exchange(path, payload, timeout=timeout if interactive else 8)
            require(reply.get("request_id", reply.get("approval_id")) == rid,
                    "request correlation mismatch: " + str(reply))
            return reply

        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = [executor.submit(request, index) for index in range(2)]
            if interactive:
                print("В панели: разрешите Smoke A и отклоните Smoke B.", flush=True)
            else:
                # Repetition removes an inter-connection delivery-order assumption.
                # No permission decision is manufactured by this harness.
                deadline = time.monotonic() + 5
                while not all(future.done() for future in futures) and time.monotonic() < deadline:
                    for sid in sessions[1:]:
                        event("session.end", session=sid)
                    time.sleep(0.05)
            results = [future.result() for future in futures]
            decisions = [result.get("decision") for result in results]
            expected = ["allow", "deny"] if interactive else ["cancelled", "cancelled"]
            require(decisions == expected, "unexpected concurrent decisions: " + str(decisions))
            counts["concurrent_requests"] = len(results)
        event("agent.completed", message="IPC smoke finished")
        return counts
    finally:
        for sid in sessions:
            try:
                exchange(path, {"event": "session.end", "session_id": sid, "provider": "custom"})
            except (OSError, ValueError, AssertionError):
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default=os.environ.get("SI_NOTCH_SOCKET", str(Path.home() / ".si-notch/run/events.sock")))
    parser.add_argument("--interactive", action="store_true", help="wait for real UI Allow A / Deny B decisions")
    parser.add_argument("--timeout", type=int, default=45, choices=range(5, 61), metavar="5..60")
    args = parser.parse_args()
    try:
        counts = run(args.socket, args.interactive, args.timeout)
    except (OSError, ValueError, AssertionError) as error:
        print("FAIL: " + str(error), file=sys.stderr)
        return 1
    print(json.dumps({"ok": True, **counts}, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
