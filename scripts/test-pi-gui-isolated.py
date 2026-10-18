#!/usr/bin/env python3
"""Send a real isolated Pi tool lifecycle into an already-running si-notch GUI.

The fake model listens only on loopback. A temporary observer shim records
event IDs and invokes the *installed* helper; an exact duplicate replay reads
the GUI's disposition, proving that the helper's ACK represented an applied
event. No user Pi config, terminal UI, or model account is touched.
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
import stat
import subprocess
import tempfile
import threading
import time
import uuid


DEFAULT_PI = Path(shutil.which("pi") or "/usr/bin/pi")
DEFAULT_APP = Path.home() / "Applications/si-notch.app"
DEFAULT_SOCKET = Path.home() / ".si-notch/run/events.sock"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class FakeModel(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        pass

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        request = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        server = self.server
        server.calls.append(request)
        call = len(server.calls)
        if call == 1:
            require("bash" in [tool.get("function", {}).get("name") for tool in request.get("tools", [])],
                    "Pi did not offer bash tool")
            deltas = [
                {"role": "assistant", "content": None},
                {"tool_calls": [{"index": 0, "id": "call_pi_gui_fixture", "type": "function",
                                 "function": {"name": "bash", "arguments": '{"command":"printf pi-gui-fixture-ok"}'}}]},
            ]
            finish = "tool_calls"
        else:
            require("pi-gui-fixture-ok" in json.dumps(request.get("messages", [])),
                    "bash tool result missing from second model request")
            print("WORKING_WINDOW_START", flush=True)
            time.sleep(server.hold_seconds)
            deltas = [{"role": "assistant", "content": "fixture complete"}]
            finish = "stop"
        chunks = [
            {"id": f"chatcmpl-gui-fixture-{call}", "object": "chat.completion.chunk",
             "created": 0, "model": "fixture-model",
             "choices": [{"index": 0, "delta": delta, "finish_reason": None}]}
            for delta in deltas
        ]
        chunks.append({"id": f"chatcmpl-gui-fixture-{call}", "object": "chat.completion.chunk",
                       "created": 0, "model": "fixture-model",
                       "choices": [{"index": 0, "delta": {}, "finish_reason": finish}]})
        payload = b"".join(b"data: " + json.dumps(chunk).encode() + b"\n\n" for chunk in chunks) + b"data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


# This shim runs only in the fixture HOME. It delegates emit to the installed
# helper and logs the fixture-generated payload privately for post-run replay.
# Replay is outside Pi's 1.2-second observer budget.
SHIM = r'''#!/usr/bin/env python3
import json, os, subprocess, sys, time
payload = json.loads(sys.argv[2])
entry = {key: payload.get(key) for key in ("event", "id", "sequence", "session_id", "provider")}
entry["payload"] = payload
entry["phase"] = "started"
with open(os.environ["SI_NOTCH_RECEIPTS"], "a", encoding="utf-8") as out:
    out.write(json.dumps(entry, separators=(",", ":")) + "\n")
started = time.monotonic()
try:
    result = subprocess.run([os.environ["SI_NOTCH_REAL_HELPER"], *sys.argv[1:]],
                            env=os.environ, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=3, check=False)
    entry["helper_ack"] = result.returncode == 0
except Exception as error:
    entry["helper_ack"] = False
    entry["error_class"] = type(error).__name__
entry["phase"] = "finished"
entry["duration_ms"] = round((time.monotonic() - started) * 1000)
with open(os.environ["SI_NOTCH_RECEIPTS"], "a", encoding="utf-8") as out:
    out.write(json.dumps(entry, separators=(",", ":")) + "\n")
sys.exit(0 if entry["helper_ack"] else 2)
'''


def replay(sock, payload):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(2)
        conn.connect(str(sock))
        conn.sendall(json.dumps(payload, separators=(",", ":")).encode() + b"\n")
        conn.shutdown(socket.SHUT_WR)
        frame = bytearray()
        while b"\n" not in frame:
            chunk = conn.recv(4096)
            require(chunk, "GUI closed before duplicate acknowledgement")
            frame.extend(chunk)
    return json.loads(frame.split(b"\n", 1)[0])


def cleanup_sessions(receipts, helper, sock, env):
    """End only session IDs observed from this run's private shim log."""
    if not receipts.exists():
        return []
    last_sequence = {}
    for line in receipts.read_text().splitlines():
        try:
            entry = json.loads(line)
            session_id = str(uuid.UUID(entry["session_id"]))
            sequence = entry["sequence"]
            if isinstance(sequence, int) and 0 <= sequence < 1_000_000:
                last_sequence[session_id] = max(last_sequence.get(session_id, 0), sequence)
        except (KeyError, ValueError, TypeError):
            continue
    cleaned = []
    for session_id, sequence in last_sequence.items():
        event = {"event": "session.end", "session_id": session_id, "provider": "pi",
                 "id": "pi-gui-fixture-cleanup-" + uuid.uuid4().hex,
                 "sequence": sequence + 1, "timestamp": time.time()}
        try:
            delivery = subprocess.run([str(helper), "emit", json.dumps(event)], env=env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                      timeout=2, check=False)
            answer = replay(sock, event) if delivery.returncode == 0 else {}
            cleaned.append({"session_id": session_id,
                            "confirmed": answer.get("ok") is True and answer.get("disposition") == "duplicate"})
        except (OSError, ValueError, subprocess.TimeoutExpired):
            cleaned.append({"session_id": session_id, "confirmed": False})
    return cleaned


def run(pi, app, sock, hold_seconds):
    adapter = app / "Contents/Resources/adapters/pi-si-notch.js"
    helper = app / "Contents/Helpers/si-notchctl"
    require(pi.is_file() and os.access(pi, os.X_OK), f"Pi executable missing: {pi}")
    require(adapter.is_file() and helper.is_file() and os.access(helper, os.X_OK),
            "installed adapter or helper missing")
    directory = sock.parent
    directory_stat = directory.stat()
    socket_stat = sock.stat()
    require(directory_stat.st_uid == os.getuid() and socket_stat.st_uid == os.getuid(), "GUI socket owner mismatch")
    require(stat.S_ISSOCK(socket_stat.st_mode) and directory_stat.st_mode & 0o077 == 0,
            "GUI socket/directory is not private")
    require(0 <= hold_seconds <= 60, "hold duration outside 0..60 seconds")

    result = None
    with tempfile.TemporaryDirectory(prefix="si-notch-pi-gui-", dir="/private/tmp") as temp:
        base = Path(temp)
        base.chmod(0o700)
        for folder in ("home", "config", "cache", "data", "state", "tmp", "work", "pi-config"):
            (base / folder).mkdir(mode=0o700)
        shim = base / "si-notch-observer-shim.py"
        shim.write_text(SHIM)
        shim.chmod(0o700)
        receipts = base / "receipts.jsonl"
        settings = {"extensions": [str(adapter)]}
        (base / "pi-config/settings.json").write_text(json.dumps(settings))
        model = None
        model_thread = None
        process = None
        env = None
        cleaned = []
        try:
            model = ThreadingHTTPServer(("127.0.0.1", 0), FakeModel)
            model.calls = []
            model.hold_seconds = hold_seconds
            model_thread = threading.Thread(target=model.serve_forever, daemon=True)
            model_thread.start()
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
                   "SI_NOTCH_SOCKET": str(sock), "SI_NOTCH_CLI": str(shim),
                   "SI_NOTCH_REAL_HELPER": str(helper), "SI_NOTCH_RECEIPTS": str(receipts),
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
                    try: records.put(json.loads(line))
                    except ValueError: records.put({"type": "invalid_json"})

            def consume_stderr():
                for line in process.stderr:
                    diagnostics.append(line.decode(errors="replace")[:300])

            threading.Thread(target=consume_stdout, daemon=True).start()
            threading.Thread(target=consume_stderr, daemon=True).start()
            process.stdin.write(b'{"type":"get_state","id":"state"}\n')
            process.stdin.flush()
            deadline = time.monotonic() + max(25, hold_seconds + 15)
            state = None
            while time.monotonic() < deadline:
                try: record = records.get(timeout=0.2)
                except queue.Empty:
                    if process.poll() is not None: break
                    continue
                if record.get("id") == "state":
                    state = record
                    break
            require(state and state.get("success") is True, f"isolated Pi failed to start: {diagnostics[-2:]}")
            process.stdin.write(b'{"type":"prompt","id":"prompt","message":"Review the fixture task, then run the bash tool once. token=PI_GUI_PROMPT_SECRET_DO_NOT_FORWARD"}\n')
            process.stdin.flush()
            observed = []
            prompt_accepted = False
            while time.monotonic() < deadline:
                try: record = records.get(timeout=0.2)
                except queue.Empty:
                    if process.poll() is not None: break
                    continue
                if record.get("id") == "prompt":
                    prompt_accepted = record.get("success") is True
                if record.get("type") in ("tool_execution_start", "tool_execution_end", "agent_settled"):
                    observed.append((record["type"], record.get("toolName")))
                if record.get("type") == "agent_settled": break
            require(prompt_accepted, f"Pi rejected isolated prompt: {diagnostics[-2:]}")
            require(("tool_execution_start", "bash") in observed and ("tool_execution_end", "bash") in observed,
                    f"Pi did not complete a tool cycle: {observed}")
            require(any(kind == "agent_settled" for kind, _ in observed), "Pi did not settle")
            process.stdin.close()
            process.wait(timeout=5)
            require(process.returncode == 0, f"Pi exited {process.returncode}: {diagnostics[-2:]}")
            deadline = time.monotonic() + 2
            while (not receipts.exists() or len(receipts.read_text().splitlines()) < 10) and time.monotonic() < deadline:
                time.sleep(0.02)
            logged = [json.loads(line) for line in receipts.read_text().splitlines()]
            entries = [entry for entry in logged if entry["phase"] == "finished"]
            kinds = [entry["event"] for entry in entries]
            require(kinds == ["session.start", "agent.working", "tool.start", "tool.finish", "agent.completed"],
                    f"unexpected helper receipts: finished={[(e['event'], e.get('helper_ack'), e.get('duration_ms')) for e in entries]}, started={[(e['event'], e['sequence']) for e in logged if e['phase'] == 'started']}")
            require(all(entry["helper_ack"] is True for entry in entries),
                    f"helper rejected events: {[(e['event'], e.get('helper_ack'), e.get('error_class')) for e in entries]}")
            working = entries[1]["payload"]
            require(working.get("title", "").startswith("Review the fixture task") and
                    working.get("first_prompt", "").startswith("Review the fixture task"),
                    "installed Pi adapter omitted the task summary")
            require("token=[redacted]" in working.get("first_prompt", "") and
                    len(working.get("title", "")) <= 100 and len(working.get("first_prompt", "")) <= 600,
                    "installed Pi adapter did not bound and redact the task summary")
            require(entries[-1]["payload"].get("message") == "fixture complete",
                    "installed Pi adapter omitted the final assistant result")
            require(all("PI_GUI_PROMPT_SECRET_DO_NOT_FORWARD" not in json.dumps(entry["payload"]) and
                        "pi-gui-fixture-ok" not in json.dumps(entry["payload"]) for entry in entries),
                    "prompt token or tool output leaked into the GUI events")
            for entry in entries:
                answer = replay(sock, entry["payload"])
                entry["replay_ok"] = answer.get("ok")
                entry["replay_disposition"] = answer.get("disposition")
            require(all(entry["replay_ok"] is True and entry["replay_disposition"] == "duplicate"
                        for entry in entries),
                    f"GUI did not apply each helper event: {[(e['event'], e['replay_disposition']) for e in entries]}")
            require([entry["sequence"] for entry in entries] == [1, 2, 3, 4, 5], "sequence mismatch")
            require(len({entry["session_id"] for entry in entries}) == 1, "session mismatch")
            require(len(model.calls) == 2, "model fixture did not run two turns")
            result = {"result": "passed", "pi_version": version, "model": "local loopback fixture",
                      "gui_socket": str(sock), "event_count": len(entries),
                      "session_id": entries[0]["session_id"],
                      "task_summary": "bounded and token-redacted", "last_result": "fixture complete",
                      "events": [{"event": entry["event"], "id": entry["id"], "sequence": entry["sequence"],
                                  "helper_ack": entry["helper_ack"], "gui_replay": entry["replay_disposition"]}
                                 for entry in entries],
                      "hold_seconds": hold_seconds, "user_pi_config_changed": False}
        finally:
            if process and process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try: process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=3)
            if env:
                cleaned = cleanup_sessions(receipts, helper, sock, env)
            if model:
                if model_thread: model.shutdown()
                model.server_close()
            if model_thread: model_thread.join(timeout=2)
    require(not Path(temp).exists(), "temporary Pi fixture directory remained")
    result["cleaned_sessions"] = cleaned
    require(all(item["confirmed"] for item in cleaned), "fixture cleanup was not confirmed")
    result["temporary_files_removed"] = True
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pi", type=Path, default=DEFAULT_PI)
    parser.add_argument("--app", type=Path, default=DEFAULT_APP)
    parser.add_argument("--socket", type=Path, default=DEFAULT_SOCKET)
    parser.add_argument("--hold-seconds", type=float, default=15)
    args = parser.parse_args()
    print(json.dumps(run(args.pi.resolve(), args.app.resolve(), args.socket.resolve(), args.hold_seconds),
                     separators=(",", ":")), flush=True)
