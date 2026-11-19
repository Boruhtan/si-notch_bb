#!/usr/bin/env python3
"""Transparent ACP observer for si-notch. Never logs or persists protocol content."""
import argparse
from collections import OrderedDict
from copy import deepcopy
import json
import os
from pathlib import Path
import queue
import re
import signal
import subprocess
import sys
import threading
import time
import uuid

MAX_FRAME = 2 * 1024 * 1024
LIMIT = 512


def identifier(value):
    return value if isinstance(value, str) and 0 < len(value) <= 512 and not any(ord(c) < 32 for c in value) else None


def outcome(reason):
    if reason == "end_turn":
        return "agent.completed"
    if reason in ("error", "refusal", "max_tokens", "max_turn_requests"):
        return "agent.failed"
    return "session.end"


def report_children_request(value):
    """Request Codex ACP's metadata-only child notifications for this observer."""
    if value.get("method") != "initialize":
        return None
    params = value.get("params")
    if not isinstance(params, dict) or params.get("protocolVersion") not in (1, 2):
        return None
    result = deepcopy(value)
    params = result["params"]
    key = "clientCapabilities" if params["protocolVersion"] == 1 else "capabilities"
    cursor = params
    for name in (key, "_meta", "jetbrains", "air"):
        cursor = cursor.setdefault(name, {})
        if not isinstance(cursor, dict):
            return None
    version = cursor.setdefault("version", 1)
    capabilities = cursor.setdefault("capabilities", [])
    if type(version) is not int or version < 1 or not isinstance(capabilities, list):
        return None
    if "nativeSubagentSessions" in capabilities:
        return None
    capabilities.append("nativeSubagentSessions")
    return result


class Observer:
    def __init__(self, emit, provider="codex"):
        self.emit = emit
        self.provider = provider
        self.version = 1
        self.requests = OrderedDict()
        self.sessions = OrderedDict()
        self.permissions = {}
        self.children = OrderedDict()
        self.child_names = OrderedDict()
        self.counter = 0
        self.nonce = uuid.uuid4().hex

    def bounded(self, table, key, value):
        table[key] = value
        while len(table) > LIMIT:
            del table[next(iter(table))]

    def send(self, sid, kind, **fields):
        if identifier(sid) is None:
            return
        self.counter += 1
        value = {"session_id": sid, "provider": self.provider, "event": kind,
                 "id": "zed-acp:" + self.nonce + ":" + str(self.counter), "timestamp": time.time(),
                 "terminal_bundle_id": "dev.zed.Zed"}
        cwd = self.sessions.get(sid, {}).get("cwd")
        if isinstance(cwd, str) and cwd.startswith("/") and len(cwd) <= 4096:
            value["cwd"] = cwd
        value.update(fields)
        self.emit(value)

    def frontend(self, msg):
        method, params = msg.get("method"), msg.get("params") or {}
        if not isinstance(params, dict):
            return
        sid = identifier(params.get("sessionId"))
        key = json.dumps(msg.get("id"))
        if method in ("initialize", "session/new", "session/load", "session/resume", "session/prompt"):
            self.bounded(self.requests, key, (method, sid, params.get("cwd")))
        if method in ("session/load", "session/resume") and sid:
            self.bounded(self.sessions, sid, {"cwd": params.get("cwd"), "active": False, "replaying": True})
        if method == "session/prompt" and sid:
            state = self.sessions.get(sid)
            if state is None:
                self.bounded(self.sessions, sid, {"active": False})
                state = self.sessions[sid]
            if state.pop("ended", False):
                self.send(sid, "session.start")
            state.update(active=True, replaying=False)
            self.send(sid, "agent.working")
        # A reply is passed unchanged to the agent. Observation never makes a decision.
        if method is None and key in self.permissions:
            sid = self.permissions.pop(key)
            if self.sessions.get(sid, {}).get("active"):
                self.send(sid, "agent.working")

    def finish(self, sid, kind):
        state = self.sessions.get(sid)
        if state and state.get("active"):
            state["active"] = False
            state["ended"] = kind == "session.end"
            self.send(sid, kind)

    def backend(self, msg):
        method, params = msg.get("method"), msg.get("params") or {}
        if method is None and "id" in msg:
            request = self.requests.pop(json.dumps(msg["id"]), None)
            if request is None:
                return
            operation, sid, cwd = request
            result = msg.get("result") or {}
            if not isinstance(result, dict):
                result = {}
            if operation == "initialize":
                self.version = result.get("protocolVersion", 1)
            elif operation in ("session/new", "session/load", "session/resume"):
                sid = identifier(result.get("sessionId")) or sid
                if sid and "error" not in msg:
                    self.bounded(self.sessions, sid, {"cwd": cwd, "active": False, "replaying": False})
                    # Loading history establishes no live work and creates no card.
                    if operation == "session/new":
                        self.send(sid, "session.start", title=self.provider.capitalize() + " · Zed")
            elif operation == "session/prompt" and sid:
                if "error" in msg:
                    self.finish(sid, "agent.failed")
                elif self.version == 1:
                    reason = result.get("stopReason")
                    self.finish(sid, outcome(reason))
                # v2's response acknowledges insertion, NOT task completion.
            return
        if not isinstance(params, dict):
            return
        sid = identifier(params.get("sessionId"))
        if method == "session/request_permission" and sid and self.sessions.get(sid, {}).get("active"):
            self.bounded(self.permissions, json.dumps(msg.get("id")), sid)
            self.send(sid, "approval.request")
            return
        if method != "session/update" or sid is None:
            return
        update = params.get("update")
        if not isinstance(update, dict):
            return
        tag = update.get("sessionUpdate")
        state = self.sessions.get(sid)
        parent = self.children.get(sid)
        if state is None and parent:
            state = self.sessions.get(parent)
        if state is None or state.get("replaying"):
            return
        if tag == "state_update":
            activity = update.get("state")
            if isinstance(activity, dict):
                activity = activity.get("state")
            if parent:
                self.child(parent, sid, None, activity)
            elif activity == "running":
                state["active"] = True
                self.send(sid, "agent.working")
            elif activity == "requires_action" and state.get("active"):
                self.send(sid, "agent.waiting")
            elif activity == "idle":
                reason = update.get("stopReason")
                meta = update.get("_meta") or {}
                failed = isinstance(meta, dict) and (meta.get("error") or meta.get("codexErrorInfo"))
                self.finish(sid, "agent.failed" if failed else outcome(reason))
            return
        root = parent or sid
        if tag in ("subagent_update", "_subagent_update", "subagent_spawned", "subagent_state_update"):
            child = identifier(update.get("subagentSessionId"))
            if child and (state.get("active") or self.children.get(child) == root):
                self.child(root, child, update.get("name"), update.get("state"))
        elif state.get("active") and tag in ("tool_call", "tool_call_update"):
            status = update.get("status")
            name = update.get("name")
            name = name if isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", name) else update.get("kind", "tool")
            name = name if isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", name) else "tool"
            kind = {"pending": "tool.start", "in_progress": "tool.start", "completed": "tool.finish", "failed": "tool.failed"}.get(status)
            if kind:
                self.send(root, kind, tool_name=name)
        # Prompts, reasoning, message text, tool inputs/results, auth and MCP traffic are never copied.

    def child(self, parent, child, name, state):
        if child == parent:
            return
        self.bounded(self.children, child, parent)
        if isinstance(state, dict):
            state = state.get("state")
        status = {"running": "working", "working": "working", "idle": "completed", "completed": "completed",
                  "failed": "failed", "error": "failed", "cancelled": "ended", "disconnected": "ended",
                  "requires_action": "waiting"}.get(state if isinstance(state, str) else "")
        if status is None and name is None:
            return
        if isinstance(name, str) and 0 < len(name) <= 128 and not any(ord(c) < 32 for c in name):
            self.bounded(self.child_names, child, name)
        safe_name = self.child_names.get(child, "Subagent")
        self.send(parent, "subagent.end" if status in ("completed", "failed", "ended") else "subagent.start",
                  subagent={"id": child, "sessionID": child, "name": safe_name, "status": status or "working"})

    def disconnected(self):
        for sid in list(self.sessions):
            self.finish(sid, "session.end")


class Sink:
    def __init__(self, helper):
        self.helper = helper
        self.pending = queue.Queue(maxsize=256)
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.work, daemon=True)
        self.thread.start()

    def emit(self, value):
        try:
            self.pending.put_nowait(value)
        except queue.Full:
            # Preserve the newest lifecycle transition without blocking ACP.
            try:
                self.pending.get_nowait(); self.pending.task_done()
            except queue.Empty:
                pass
            try:
                self.pending.put_nowait(value)
            except queue.Full:
                pass

    def deliver(self, value):
        try:
            subprocess.run([self.helper, "emit", json.dumps(value, separators=(",", ":"))],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=.8)
        except (OSError, subprocess.TimeoutExpired):
            pass

    def work(self):
        while not self.stop.is_set() or not self.pending.empty():
            try:
                value = self.pending.get(timeout=.2)
            except queue.Empty:
                value = None
            if value is not None:
                self.deliver(value); self.pending.task_done()

    def close(self):
        self.stop.set()
        self.thread.join(timeout=2)


def copy_frames(source, destination, observe, transform=None):
    oversized = False
    while True:
        frame = source.readline(MAX_FRAME + 1)
        if not frame:
            return
        if not oversized and len(frame) <= MAX_FRAME and frame.endswith(b"\n"):
            try:
                value = json.loads(frame)
                if isinstance(value, dict):
                    observe(value)
                    if transform and (changed := transform(value)) is not None:
                        frame = json.dumps(changed, separators=(",", ":")).encode() + b"\n"
            except (ValueError, TypeError, KeyError, IndexError, RecursionError):
                pass
        destination.write(frame)
        destination.flush()
        oversized = not frame.endswith(b"\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", required=True)
    parser.add_argument("--provider", default="codex", choices=["codex"])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("an existing ACP agent command is required")
    # The ACP feed owns the child identity and display name for this process.
    environment = {**os.environ, "SI_NOTCH_ACP_OBSERVES_SUBAGENTS": "1"}
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             start_new_session=True, env=environment)
    sink = Sink(args.helper)
    observer = Observer(sink.emit, args.provider)
    lock = threading.Lock()
    def observe(handler):
        def synchronized(value):
            with lock:
                handler(value)
        return synchronized
    def interrupt(signum, _frame):
        try:
            os.killpg(child.pid, signum)
        except ProcessLookupError:
            pass
    signal.signal(signal.SIGTERM, interrupt); signal.signal(signal.SIGINT, interrupt)
    def frontend():
        try:
            copy_frames(sys.stdin.buffer, child.stdin, observe(observer.frontend), report_children_request)
        except (BrokenPipeError, OSError):
            pass
        finally:
            try:
                child.stdin.close()
            except OSError:
                pass
    thread = threading.Thread(target=frontend, daemon=True); thread.start()
    try:
        copy_frames(child.stdout, sys.stdout.buffer, observe(observer.backend))
    except (BrokenPipeError, OSError):
        interrupt(signal.SIGTERM, None)
    finally:
        code = child.wait()
        with lock:
            observer.disconnected()
        sink.close()
    return code


if __name__ == "__main__":
    sys.exit(main())
