#!/usr/bin/env python3
"""Real OpenCode -> bundled helper -> private Unix ACK smoke test.

Installs one pinned official CLI only in /tmp. No model, tool, or permission
operation is requested. Does not load the user's environment or agent configs.
All installation files, runtime state, logs, sockets and processes are removed.
"""

import argparse
import base64
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request


PACKAGE = "@opencode/cli@2.0.32"
VERSION = "2.0.32"
MAX_FRAME = 256 * 1024


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def progress(message):
    print(message, flush=True)


def terminate_owned(process):
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)


def peer_executable(connection):
    # Darwin's public LOCAL_PEERPID identifies only this fixture's own peer.
    pid = struct.unpack("i", connection.getsockopt(0, 2, 4))[0]
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    require(library.proc_pidpath(pid, buffer, len(buffer)) > 0,
            "Could not identify fixture socket peer")
    return Path(os.fsdecode(buffer.value)).resolve()


class AckFixture:
    def __init__(self, endpoint, helper):
        self.endpoint, self.helper = endpoint, helper
        self.events = []
        self.errors = []
        self.stopping = threading.Event()
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(endpoint))
        os.chmod(endpoint, 0o600)
        self.listener.listen(8)
        self.listener.settimeout(0.1)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stopping.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                if not self.stopping.is_set():
                    self.errors.append("Fixture listener failed")
                return
            try:
                with connection:
                    connection.settimeout(2)
                    require(peer_executable(connection) == self.helper,
                            "Socket peer was not the installed si-notchctl")
                    frame = bytearray()
                    while b"\n" not in frame:
                        chunk = connection.recv(8192)
                        require(chunk, "Helper closed before sending its frame")
                        frame.extend(chunk)
                        require(len(frame) <= MAX_FRAME, "Event exceeded frame bound")
                    require(frame[-1] == 10 and frame.count(10) == 1, "Unexpected frame boundary")
                    event = json.loads(frame)
                    require(event.get("provider") == "opencode", "Unexpected event provider")
                    require("await_response" not in event, "Fixture must not receive a permission decision")
                    connection.sendall(b'{"ok":true,"disposition":"applied"}\n')
                    require(connection.recv(1) == b"", "Helper did not close after ACK")
                    self.events.append(event)
            except Exception as error:
                self.errors.append(str(error))

    def wait_event(self, kind, session_id, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            require(not self.errors, "; ".join(self.errors))
            matches = [event for event in self.events
                       if event.get("event") == kind and event.get("session_id") == session_id]
            if matches:
                return matches[-1]
            self.stopping.wait(0.05)
        raise AssertionError(f"Real plugin did not deliver {kind} through the helper")

    def close(self):
        self.stopping.set()
        self.listener.close()
        self.thread.join(timeout=3)
        require(not self.thread.is_alive(), "Fixture listener thread did not exit")


def environment(root, helper, endpoint):
    paths = {name: root / name for name in
             ("home", "config", "data", "cache", "state", "runtime", "tmp", "npm-cache", "bun", "bun-cache")}
    for path in paths.values():
        path.mkdir(mode=0o700)
    for name in ("npm-user.conf", "npm-global.conf"):
        (root / name).write_text("")
    # Construct an allowlist instead of copying credentials, proxy settings,
    # NODE_OPTIONS, shell initialization, or the user's package-manager config.
    return {
        "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(paths["home"]), "TMPDIR": str(paths["tmp"]),
        "XDG_CONFIG_HOME": str(paths["config"]), "XDG_DATA_HOME": str(paths["data"]),
        "XDG_CACHE_HOME": str(paths["cache"]), "XDG_STATE_HOME": str(paths["state"]),
        "XDG_RUNTIME_DIR": str(paths["runtime"]), "BUN_INSTALL": str(paths["bun"]),
        "BUN_RUNTIME_TRANSPILER_CACHE_PATH": str(paths["bun-cache"]),
        "npm_config_cache": str(paths["npm-cache"]),
        "npm_config_userconfig": str(root / "npm-user.conf"),
        "npm_config_globalconfig": str(root / "npm-global.conf"),
        "npm_config_registry": "https://registry.npmjs.org",
        "npm_config_update_notifier": "false", "npm_config_audit": "false",
        "npm_config_fund": "false", "NO_COLOR": "1", "CI": "1",
        "OPENCODE_DISABLE_AUTOUPDATE": "true",
        "OPENCODE_SERVER_USERNAME": "opencode",
        "OPENCODE_SERVER_PASSWORD": secrets.token_urlsafe(32),
        "SI_NOTCH_CLI": str(helper), "SI_NOTCH_SOCKET": str(endpoint),
    }


def request(base, password, method, route, body=None, timeout=3):
    data = None if body is None else json.dumps(body).encode()
    call = urllib.request.Request(base + route, data=data, method=method,
                                  headers={"Content-Type": "application/json",
                                           "Authorization": "Basic " + base64.b64encode(
                                               ("opencode:" + password).encode()).decode()})
    with urllib.request.urlopen(call, timeout=timeout) as response:
        payload = response.read(1_048_577)
        require(len(payload) <= 1_048_576, "Local API response exceeded fixture limit")
        return json.loads(payload) if payload else None


def dictionaries(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from dictionaries(child)
    elif isinstance(value, list):
        for child in value:
            yield from dictionaries(child)


def run(helper, npm):
    require(sys.platform == "darwin", "This smoke test verifies the installed macOS helper")
    helper = helper.resolve(strict=True)
    require(os.access(helper, os.X_OK), "Installed helper is not executable")
    source = Path(__file__).resolve().parent / "adapters/opencode-si-notch.js"
    report = {
        "package": PACKAGE,
        "helper_sha256": hashlib.sha256(helper.read_bytes()).hexdigest(),
        "adapter_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "model_requests_sent": 0,
        "production_socket_used": False,
    }
    root = Path(tempfile.mkdtemp(prefix="si-notch-opencode-", dir="/tmp")).resolve()
    os.chmod(root, 0o700)
    endpoint = root / "events.sock"
    process = installer = version_process = fixture = None
    failure = None
    logs = []
    try:
        env = environment(root, helper, endpoint)
        work = root / "work"
        plugin_directory = work / ".opencode/plugins"
        plugin_directory.mkdir(parents=True)
        shutil.copyfile(source, plugin_directory / "si-notch.js")
        install = root / "install"
        install.mkdir()
        fixture = AckFixture(endpoint, helper)
        progress("Private Unix ACK fixture ready; installing pinned OpenCode in isolated /tmp.")
        install_log = (root / "install.log").open("wb")
        logs.append(install_log)
        installer = subprocess.Popen([str(npm), "install", "--prefix", str(install),
                                      "--no-audit", "--no-fund", PACKAGE],
                                     cwd=work, env=env, stdout=install_log,
                                     stderr=subprocess.STDOUT, start_new_session=True)
        require(installer.wait(timeout=240) == 0, "Pinned npm installation failed")
        cli = install / "node_modules/.bin/opencode"
        require(cli.is_file(), "Installed OpenCode entrypoint is missing")
        version_process = subprocess.Popen([str(cli), "--version"], cwd=work, env=env,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           text=True, start_new_session=True)
        version_stdout, _ = version_process.communicate(timeout=30)
        require(version_process.returncode == 0 and VERSION in version_stdout,
                "Installed CLI version does not match the pin")
        report["cli_version"] = VERSION
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        server_log = (root / "server.log").open("wb")
        logs.append(server_log)
        process = subprocess.Popen([str(cli), "serve", "--hostname", "127.0.0.1", "--port", str(port)],
                                   cwd=work, env=env, stdin=subprocess.DEVNULL,
                                   stdout=server_log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        base = f"http://127.0.0.1:{port}"
        password = env["OPENCODE_SERVER_PASSWORD"]
        deadline = time.monotonic() + 45
        active = False
        startup_status = "No response"
        while time.monotonic() < deadline:
            require(process.poll() is None, "Isolated OpenCode server exited during startup")
            try:
                result = request(base, password, "GET", "/api/plugin")
                plugins = [item for item in dictionaries(result) if item.get("id") == "si-notch"]
                startup_status = json.dumps(plugins)[:1000]
                active = any(item.get("state", {}).get("status") == "active" for item in plugins)
                if active:
                    break
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
                startup_status = str(error)
            time.sleep(0.2)
        require(active, "OpenCode did not report the real plugin active: " + startup_status)
        report["plugin_active"] = True
        progress("OpenCode 2.0.32 reports si-notch active; testing real lifecycle delivery.")
        created = request(base, password, "POST", "/api/session", {})
        candidates = [item["id"] for item in dictionaries(created)
                      if isinstance(item.get("id"), str) and item["id"].startswith("ses_")]
        require(len(set(candidates)) == 1, "Session creation did not return one session ID")
        session_id = candidates[0]
        started = fixture.wait_event("session.start", session_id)
        request(base, password, "DELETE", "/api/session/" + session_id)
        ended = fixture.wait_event("session.end", session_id)
        require(started.get("sequence") == 1 and ended.get("sequence") == 2,
                "Unexpected lifecycle event ordering")
        require(started.get("cwd") == str(work) and ended.get("cwd") == str(work),
                "Plugin did not use the isolated project")
        require([event.get("event") for event in fixture.events] == ["session.start", "session.end"],
                "Unexpected model, tool, or permission event in lifecycle-only test")
        report.update({"events": ["session.start", "session.end"], "sequences": [1, 2],
                       "acknowledgements": 2, "socket_peer_was_installed_helper": True,
                       "helper_closed_after_each_ack": True, "result": "passed"})
    except BaseException as error:
        failure = error
        report["result"] = "failed"
        report["error"] = f"{type(error).__name__}: {error}"
        for name in ("install.log", "server.log"):
            log_path = root / name
            if log_path.exists():
                tail = log_path.read_text(errors="replace")[-4000:].replace(str(root), "<fixture>")
                report[name + "_tail"] = re.sub(r"(?im)(server password )[^\r\n]+", r"\1<redacted>", tail)
    finally:
        cleanup_errors = []
        for child in (process, installer, version_process):
            try:
                terminate_owned(child)
            except Exception as error:
                cleanup_errors.append(str(error))
        if fixture is not None:
            try:
                fixture.close()
            except Exception as error:
                cleanup_errors.append(str(error))
            if fixture.errors:
                report["fixture_errors"] = fixture.errors
                cleanup_errors.extend(fixture.errors)
        for log in logs:
            log.close()
        try:
            shutil.rmtree(root)
        except Exception as error:
            cleanup_errors.append(str(error))
        report["cleanup"] = {"temporary_root_removed": not root.exists(),
                             "socket_removed": not endpoint.exists(),
                             "server_reaped": process is None or process.poll() is not None,
                             "installer_reaped": installer is None or installer.poll() is not None}
        if cleanup_errors:
            report["cleanup_errors"] = cleanup_errors
            report["result"] = "failed"
            failure = failure or RuntimeError("Fixture cleanup failed")
    print(json.dumps(report, indent=2), flush=True)
    if failure:
        raise SystemExit(1)


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"Interrupted by signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path,
                        default=Path.home() / "Applications/si-notch.app/Contents/Helpers/si-notchctl")
    parser.add_argument("--npm", type=Path, default=Path(shutil.which("npm") or "/opt/homebrew/bin/npm"))
    args = parser.parse_args()
    run(args.helper, args.npm)
