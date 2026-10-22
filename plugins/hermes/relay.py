#!/usr/bin/env python3
"""Portable remote-side si-notchctl subset for a private SSH-forwarded Unix socket.

Supports emit, hook, notify (observation) and request (one correlated decision).
No TCP listener, credential storage, shell invocation, or automatic approval.
"""

import argparse
import json
import os
from pathlib import Path
import re
import socket
import stat
import sys
import uuid


MAX_BYTES = 128 * 1024
REQUEST_ID = re.compile(r"^[A-Za-z0-9._:-]{1,160}$")


class RelayError(Exception):
    pass


def socket_path(value=None):
    path = value or os.environ.get("SI_NOTCH_SOCKET") or str(Path.home() / ".si-notch/run/events.sock")
    if not path.startswith("/") or len(os.fsencode(path)) >= 100 or ":" in path or "\x00" in path:
        raise RelayError("invalid socket path")
    parts = Path(path).parts
    if ".." in parts or "." in parts:
        raise RelayError("invalid socket path")
    parent_path = os.path.dirname(path)
    current = ""
    for component in Path(parent_path).parts[1:]:
        current += "/" + component
        info = os.lstat(current)
        if not stat.S_ISDIR(info.st_mode):
            raise RelayError("socket directory must not use symlinks")
        if current == parent_path:
            if info.st_uid != os.geteuid() or info.st_mode & 0o077:
                raise RelayError("socket directory must belong to this user and have mode 0700")
        elif info.st_uid not in (0, os.geteuid()) or (info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX):
            raise RelayError("unsafe socket directory ancestor")
    endpoint = os.lstat(path)
    if not stat.S_ISSOCK(endpoint.st_mode) or endpoint.st_uid != os.geteuid() or endpoint.st_mode & 0o077:
        raise RelayError("socket must belong to this user and have mode 0600")
    return path


def read_object(argument):
    raw = argument.encode() if argument is not None else sys.stdin.buffer.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise RelayError("event exceeds 128 KiB")
    try:
        value = json.loads(raw)
    except (ValueError, UnicodeDecodeError) as error:
        raise RelayError("expected a JSON object") from error
    if not isinstance(value, dict):
        raise RelayError("expected a JSON object")
    return value


def exchange(event, path, timeout):
    encoded = json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode()
    if len(encoded) + 1 > MAX_BYTES:
        raise RelayError("event exceeds 128 KiB")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(socket_path(path))
        connection.sendall(encoded + b"\n")
        connection.shutdown(socket.SHUT_WR)
        response = bytearray()
        while b"\n" not in response:
            chunk = connection.recv(8192)
            if not chunk:
                raise RelayError("connection closed before acknowledgement")
            response.extend(chunk)
            if len(response) > MAX_BYTES:
                raise RelayError("acknowledgement exceeds 128 KiB")
    try:
        result = json.loads(bytes(response).split(b"\n", 1)[0])
    except ValueError as error:
        raise RelayError("invalid acknowledgement") from error
    if not isinstance(result, dict):
        raise RelayError("invalid acknowledgement")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", help="Absolute remote path to the SSH-forwarded socket")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("emit", "notify"):
        sub.add_parser(name).add_argument("json", nargs="?")
    hook = sub.add_parser("hook")
    hook.add_argument("--agent", default="claude")
    request = sub.add_parser("request")
    request.add_argument("json", nargs="?")
    request.add_argument("--timeout", type=float, default=60)
    args = parser.parse_args()
    silent = args.command in ("hook", "notify")
    try:
        event = read_object(None if args.command == "hook" else args.json)
        if args.command == "hook":
            event["provider"] = args.agent
        if args.command == "request":
            if not 0.1 <= args.timeout <= 110:
                raise RelayError("request timeout must be between 0.1 and 110 seconds")
            request_id = event.get("request_id") or event.get("approval_id") or str(uuid.uuid4())
            if not isinstance(request_id, str) or not REQUEST_ID.fullmatch(request_id):
                raise RelayError("invalid request_id")
            event.update({"event": "approval.request", "request_id": request_id,
                          "approval_id": event.get("approval_id") or request_id,
                          "await_response": True, "response_timeout": args.timeout})
        result = exchange(event, args.socket, args.timeout + 1 if args.command == "request" else 1.2)
        if args.command == "request":
            if result.get("request_id") != request_id:
                raise RelayError("decision request_id mismatch")
            print(json.dumps(result, separators=(",", ":")))
            if result.get("ok") is not True:
                return 2
            decision = result.get("decision")
            if decision == "deny":
                return 1
            if decision == "answer":
                return 0 if isinstance(result.get("answer"), str) and result["answer"].strip() else 2
            return 0 if decision in ("allow", "allow-once") else 2
        if result.get("ok") is not True:
            raise RelayError("app rejected observation")
        if event.get("event") == "usage.update" and (event.get("usage") or {}).get("request_id"):
            if result.get("disposition") != "usage_committed":
                raise RelayError("usage was not durably saved")
        return 0
    except (OSError, ValueError, RelayError) as error:
        if not silent:
            print(f"si-notch remote relay: {error}", file=sys.stderr)
        return 0 if silent else 2


if __name__ == "__main__":
    raise SystemExit(main())
