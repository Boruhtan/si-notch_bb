#!/usr/bin/env python3
"""Isolated ordinary Pi -> registered extension -> helper -> private socket test.

No user Pi settings, credentials, model service, or GUI are used. A temporary
loopback HTTP server supplies two deterministic OpenAI-compatible model turns:
one bash tool call and one final answer.
"""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "scripts/adapters/pi-si-notch.js"
DEFAULT_HELPER = ROOT / "build/si-notch.app/Contents/Helpers/si-notchctl"
DEFAULT_PI = Path(shutil.which("pi") or "/usr/bin/pi")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class EventSocket:
    def __init__(self, path):
        self.path = path
        self.events = []
        self.errors = []
        self.stopping = threading.Event()
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(path))
        path.chmod(0o600)
        self.listener.listen(16)
        self.listener.settimeout(0.1)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stopping.is_set():
            try:
                conn, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError as error:
                if not self.stopping.is_set():
                    self.errors.append(str(error))
                return
            try:
                with conn:
                    conn.settimeout(2)
                    frame = bytearray()
                    while b"\n" not in frame and len(frame) < 131072:
                        chunk = conn.recv(8192)
                        if not chunk:
                            break
                        frame.extend(chunk)
                    require(b"\n" in frame, "incomplete helper frame")
                    event = json.loads(frame.split(b"\n", 1)[0])
                    self.events.append(event)
                    conn.sendall(b'{"ok":true,"disposition":"applied"}\n')
            except (OSError, ValueError, AssertionError) as error:
                self.errors.append(str(error))

    def close(self):
        self.stopping.set()
        self.listener.close()
        self.thread.join(timeout=2)
        require(not self.errors, f"socket fixture errors: {self.errors}")


class FakeModel(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        pass

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length))
        calls = self.server.calls
        calls.append(request)
        tool_names = [tool.get("function", {}).get("name") for tool in request.get("tools", [])]
        if len(calls) == 1:
            require("bash" in tool_names, "Pi did not offer bash tool to fake model")
            deltas = [
                {"role": "assistant", "content": None},
                {"tool_calls": [{"index": 0, "id": "call_pi_fixture", "type": "function",
                                 "function": {"name": "bash", "arguments": '{"command":"printf pi-fixture-ok"}'}}]},
            ]
            finish = "tool_calls"
        else:
            deltas = [{"role": "assistant", "content": "fixture complete"}]
            finish = "stop"
        chunks = [
            {"id": f"chatcmpl-fixture-{len(calls)}", "object": "chat.completion.chunk",
             "created": 0, "model": "fixture-model",
             "choices": [{"index": 0, "delta": delta, "finish_reason": None}]}
            for delta in deltas
        ]
        chunks.append({"id": f"chatcmpl-fixture-{len(calls)}", "object": "chat.completion.chunk",
                       "created": 0, "model": "fixture-model",
                       "choices": [{"index": 0, "delta": {}, "finish_reason": finish}]})
        payload = b"".join(b"data: " + json.dumps(chunk).encode() + b"\n\n" for chunk in chunks) + b"data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def run(pi, helper):
    require(pi.is_file() and os.access(pi, os.X_OK), f"Pi is not executable: {pi}")
    require(helper.is_file() and os.access(helper, os.X_OK), f"helper is not executable: {helper}")
    require(ADAPTER.is_file(), f"Pi adapter is missing: {ADAPTER}")
    result = None
    with tempfile.TemporaryDirectory(prefix="si-notch-pi-e2e-", dir="/private/tmp") as temp:
        base = Path(temp)
        base.chmod(0o700)
        for folder in ("home", "config", "cache", "data", "state", "tmp", "work", "pi-config", "socket"):
            (base / folder).mkdir(mode=0o700)
        sock = None
        model = None
        server_thread = None
        process = None
        try:
            # Copy the exact adapter and helper into a temporary app layout.
            # Pi loads it from its ordinary user settings, with no -e flag or
            # SI_NOTCH_CLI override; the adapter must resolve its sibling helper.
            bundledAdapters = base / "si-notch.app/Contents/Resources/adapters"
            bundledHelpers = base / "si-notch.app/Contents/Helpers"
            bundledAdapters.mkdir(parents=True)
            bundledHelpers.mkdir(parents=True)
            shutil.copy2(ADAPTER, bundledAdapters / "pi-si-notch.js")
            shutil.copy2(ROOT / "scripts/adapters/package.json", bundledAdapters / "package.json")
            shutil.copy2(helper, bundledHelpers / "si-notchctl")
            settings = {"extensions": [str(bundledAdapters / "pi-si-notch.js")]}
            (base / "pi-config/settings.json").write_text(json.dumps(settings))
            sock = EventSocket(base / "socket/events.sock")
            model = ThreadingHTTPServer(("127.0.0.1", 0), FakeModel)
            model.calls = []
            server_thread = threading.Thread(target=model.serve_forever, daemon=True)
            server_thread.start()
            models = {"providers": {"fixture": {"baseUrl": f"http://127.0.0.1:{model.server_port}/v1",
                                                  "api": "openai-completions", "apiKey": "fixture-only",
                                                  "models": [{"id": "fixture-model", "name": "Fixture model",
                                                              "contextWindow": 32000, "maxTokens": 1024,
                                                              "reasoning": False, "input": ["text"],
                                                              "cost": {"input": 0, "output": 0,
                                                                       "cacheRead": 0, "cacheWrite": 0}}]}}}
            (base / "pi-config/models.json").write_text(json.dumps(models))
            env = {"HOME": str(base / "home"), "XDG_CONFIG_HOME": str(base / "config"),
                   "XDG_CACHE_HOME": str(base / "cache"), "XDG_DATA_HOME": str(base / "data"),
                   "XDG_STATE_HOME": str(base / "state"), "TMPDIR": str(base / "tmp"),
                   "PI_CODING_AGENT_DIR": str(base / "pi-config"), "PI_OFFLINE": "1",
                   "SI_NOTCH_SOCKET": str(base / "socket/events.sock"),
                   "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"}
            version = subprocess.check_output([str(pi), "--version"], env=env, cwd=base / "work", timeout=5).decode().strip()
            cmd = [str(pi), "--mode", "rpc", "--no-session", "--no-mcp", "--no-skills",
                   "--no-prompt-templates", "--no-themes", "--no-context-files",
                   "--no-approve", "--offline", "--provider", "fixture", "--model", "fixture-model"]
            process = subprocess.Popen(cmd, cwd=base / "work", env=env,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True)
            records = queue.Queue()
            diagnostics = []

            def consume_stdout():
                for line in process.stdout:
                    try:
                        records.put(json.loads(line))
                    except ValueError:
                        records.put({"type": "invalid_json"})

            def consume_stderr():
                for line in process.stderr:
                    diagnostics.append(line.decode(errors="replace")[:300])

            threading.Thread(target=consume_stdout, daemon=True).start()
            threading.Thread(target=consume_stderr, daemon=True).start()
            process.stdin.write(b'{"type":"get_state","id":"state"}\n')
            process.stdin.flush()
            deadline = time.monotonic() + 20
            state = None
            while time.monotonic() < deadline:
                try:
                    record = records.get(timeout=0.2)
                except queue.Empty:
                    if process.poll() is not None:
                        break
                    continue
                if record.get("id") == "state":
                    state = record
                    break
            require(state and state.get("success") is True, f"Pi did not initialize: {diagnostics[-3:]}")
            process.stdin.write(b'{"type":"prompt","id":"prompt","message":"Review the fixture task, then run the bash tool once. token=PI_PROMPT_SECRET_DO_NOT_FORWARD"}\n')
            process.stdin.flush()
            observed = []
            response = None
            while time.monotonic() < deadline:
                try:
                    record = records.get(timeout=0.2)
                except queue.Empty:
                    if process.poll() is not None:
                        break
                    continue
                kind = record.get("type")
                if record.get("id") == "prompt":
                    response = record
                if kind in ("tool_execution_start", "tool_execution_end", "agent_settled"):
                    observed.append((kind, record.get("toolName")))
                if kind == "agent_settled":
                    break
            require(response and response.get("success") is True, f"Pi rejected prompt: {response}; {diagnostics[-3:]}")
            require(("tool_execution_start", "bash") in observed, f"no real Pi bash start: {observed}")
            require(("tool_execution_end", "bash") in observed, f"no real Pi bash end: {observed}")
            require(any(kind == "agent_settled" for kind, _ in observed), f"Pi did not settle: {observed}")
            process.stdin.close()
            process.wait(timeout=5)
            require(process.returncode == 0, f"Pi exited {process.returncode}: {diagnostics[-3:]}")
            deadline = time.monotonic() + 2
            while len(sock.events) < 5 and time.monotonic() < deadline:
                time.sleep(0.02)
            events = sock.events
            kinds = [event.get("event") for event in events]
            require(len(model.calls) == 2, f"expected two local model calls, got {len(model.calls)}")
            require("pi-fixture-ok" in json.dumps(model.calls[1].get("messages", [])), "bash result did not reach model")
            require(["session.start", "agent.working", "tool.start", "tool.finish", "agent.completed"] == kinds,
                    f"unexpected acknowledged helper sequence: {kinds}")
            require(all(event.get("provider") == "pi" for event in events), "provider changed")
            require(len({event.get("session_id") for event in events}) == 1, "session identity changed")
            require([event.get("sequence") for event in events] == list(range(1, 6)), "sequence changed")
            working = events[1]
            require(working.get("title", "").startswith("Review the fixture task"),
                    "Pi working card lacks the current task summary")
            require(working.get("first_prompt", "").startswith("Review the fixture task"),
                    "Pi working card lacks the first prompt summary")
            require("token=[redacted]" in working.get("first_prompt", ""),
                    "Pi working summary did not redact the prompt token")
            require(len(working.get("title", "")) <= 100 and len(working.get("first_prompt", "")) <= 600,
                    "Pi task summary exceeded display bounds")
            require(events[-1].get("message") == "fixture complete",
                    "Pi completed card lacks the final assistant text")
            require(all("pi-fixture-ok" not in json.dumps(event) and
                        "PI_PROMPT_SECRET_DO_NOT_FORWARD" not in json.dumps(event)
                        for event in events), "prompt or tool output leaked")
            result = {"pi_version": version, "result": "passed", "launch": "settings.extensions (no --extension)",
                      "model": "local deterministic fixture",
                      "pi_rpc_tool_events": [kind for kind, _ in observed], "acknowledged_events": kinds,
                      "task_summary": "bounded and token-redacted", "last_result": "fixture complete",
                      "model_requests": len(model.calls), "user_configuration_touched": False}
        finally:
            if process and process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=3)
            if model:
                if server_thread:
                    model.shutdown()
                model.server_close()
            if server_thread:
                server_thread.join(timeout=2)
            if sock:
                sock.close()
    require(not Path(temp).exists(), "temporary fixture directory remained")
    result["temporary_files_removed"] = True
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pi", type=Path, default=DEFAULT_PI)
    parser.add_argument("--helper", type=Path, default=DEFAULT_HELPER)
    args = parser.parse_args()
    print(json.dumps(run(args.pi.resolve(), args.helper.resolve()), sort_keys=True))
