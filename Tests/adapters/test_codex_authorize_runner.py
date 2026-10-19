import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class CodexAuthorizeRunnerTests(unittest.TestCase):
    def test_exact_hash_authorization_uses_mock_app_server_only(self):
        if shutil.which("swiftc") is None:
            self.skipTest("Swift compiler unavailable")
        with tempfile.TemporaryDirectory(prefix="si-notch-codex-auth-fixture-") as name:
            directory = pathlib.Path(name)
            runner = directory / "runner"
            env = {**os.environ,
                   "CLANG_MODULE_CACHE_PATH": str(directory / "clang-cache"),
                   "SWIFT_MODULE_CACHE_PATH": str(directory / "swift-cache")}
            compilation = subprocess.run([
                "swiftc", str(ROOT / "Sources/SINotch/CodexHookSetup.swift"),
                str(ROOT / "Sources/SINotch/CodexHookAuthorization.swift"),
                str(ROOT / "scripts/adapters/codex-authorize-runner.swift"),
                "-o", str(runner),
            ], env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(compilation.returncode, 0, compilation.stderr)

            adapter = directory / "codex-hook.py"
            adapter.write_text("# fixture\n")
            helper = directory / "si-notchctl"
            helper.write_text("#!/bin/sh\nexit 0\n")
            helper.chmod(0o700)
            hooks = directory / "hooks.json"
            command = f"/usr/bin/python3 '{adapter}' --cli '{helper}'"
            names = ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                     "PermissionRequest", "Stop", "Interrupt", "SessionEnd")
            hooks.write_text(json.dumps({"hooks": {name: [{"hooks": [
                {"type": "command", "command": command, "timeout": 80 if name == "PermissionRequest" else 3}
            ]}] for name in names}}))
            state = directory / "state"
            state.write_text("untrusted")
            requests = directory / "requests.jsonl"
            mock = directory / "codex-mock"
            mock.write_text(f"#!{sys.executable}\n" + '''
import json, os, sys
names = ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
         "PermissionRequest", "Stop", "Interrupt", "SessionEnd")
for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method = request["method"]
    if method == "initialize":
        result = {}
    elif method == "hooks/list":
        status = open(os.environ["FAKE_STATE"]).read().strip()
        hooks = [{"eventName": name[:1].lower() + name[1:],
                  "key": f"file:{os.environ['FAKE_HOOKS']}:event:{i}:0",
                  "currentHash": "sha256:fixture", "trustStatus": status,
                  "enabled": True, "isManaged": False, "source": "user",
                  "sourcePath": os.environ["FAKE_HOOKS"],
                  "command": os.environ["FAKE_COMMAND"]}
                 for i, name in enumerate(names)]
        result = {"data": [{"cwd": os.environ["HOME"], "hooks": hooks,
                            "warnings": [], "errors": []}]}
    elif method == "config/batchWrite":
        with open(os.environ["FAKE_REQUESTS"], "a") as out:
            out.write(json.dumps(request) + "\\n")
        with open(os.environ["FAKE_STATE"], "w") as out:
            out.write("trusted")
        result = {"status": "ok", "version": "v2", "filePath": "/fixture/config.toml"}
    else:
        raise RuntimeError(method)
    sys.stdout.write(json.dumps({"id": request["id"], "result": result}) + "\\n")
    sys.stdout.flush()
''')
            mock.chmod(0o700)
            env.update({"FAKE_STATE": str(state), "FAKE_HOOKS": str(hooks),
                        "FAKE_COMMAND": command, "FAKE_REQUESTS": str(requests)})
            base = [str(runner), "preview", str(mock), str(adapter), str(helper), str(hooks)]
            preview = subprocess.run(base, check=True, capture_output=True, text=True,
                                     env=env, timeout=15)
            self.assertIn("Pending definitions: 8", preview.stdout)
            digest = next(line.split(": ", 1)[1] for line in preview.stdout.splitlines()
                          if line.startswith("Review SHA-256: "))
            apply = [str(runner), "apply", str(mock), str(adapter), str(helper), str(hooks)]
            bad = subprocess.run(apply, capture_output=True, text=True,
                                 env={**env, "SI_NOTCH_REVIEWED_HOOKS_SHA256": "0" * 64}, timeout=15)
            self.assertNotEqual(bad.returncode, 0)
            self.assertFalse(requests.exists())
            subprocess.run(apply, check=True, capture_output=True, text=True,
                           env={**env, "SI_NOTCH_REVIEWED_HOOKS_SHA256": digest}, timeout=15)
            self.assertEqual(state.read_text(), "trusted")
            writes = [json.loads(line) for line in requests.read_text().splitlines()]
            self.assertEqual(len(writes), 1)
            self.assertEqual(writes[0]["method"], "config/batchWrite")
            edit = writes[0]["params"]["edits"][0]
            self.assertEqual(edit["keyPath"], "hooks.state")
            self.assertEqual(edit["mergeStrategy"], "upsert")
            self.assertEqual(len(edit["value"]), 8)
            self.assertTrue(all(value == {"trusted_hash": "sha256:fixture"}
                                for value in edit["value"].values()))

            # A server that rejects initialize but stays alive must be reaped
            # even though the transport initializer itself throws.
            pid_file = directory / "rejected.pid"
            rejector = directory / "codex-rejector"
            rejector.write_text(f"#!{sys.executable}\n" + '''
import json, os, sys, time
open(os.environ["FAKE_PID_FILE"], "w").write(str(os.getpid()))
for line in sys.stdin:
    request = json.loads(line)
    if request.get("method") == "initialize":
        sys.stdout.write(json.dumps({"id": request["id"], "error": {"code": -1, "message": "rejected"}}) + "\\n")
        sys.stdout.flush()
        break
time.sleep(30)
''')
            rejector.chmod(0o700)
            rejected = subprocess.run([str(runner), "preview", str(rejector), str(adapter),
                                       str(helper), str(hooks)], capture_output=True, text=True,
                                      env={**env, "FAKE_PID_FILE": str(pid_file)}, timeout=15)
            self.assertNotEqual(rejected.returncode, 0)
            pid = int(pid_file.read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)


if __name__ == "__main__":
    unittest.main()
