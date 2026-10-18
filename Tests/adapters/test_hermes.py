"""Contract tests for our Hermes observer; no Hermes installation is required."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


PLUGIN = Path(__file__).resolve().parents[2] / "scripts/adapters/hermes-si-notch/__init__.py"
spec = importlib.util.spec_from_file_location("si_notch_hermes_plugin", PLUGIN)
plugin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin)


class Context:
    def __init__(self):
        self.hooks = {}

    def register_hook(self, name, callback):
        self.hooks[name] = callback


class HermesPluginTests(unittest.TestCase):
    def setUp(self):
        plugin._STARTED.clear()
        plugin._SEQUENCES.clear()
        plugin._DISABLED_UNTIL = 0

    def test_official_observer_contract_and_lifecycle(self):
        ctx = Context()
        plugin.register(ctx)
        self.assertEqual(set(ctx.hooks), {
            "on_session_start", "pre_api_request", "post_tool_call",
            "on_human_input_request", "on_human_input_resolved",
            "on_session_end", "on_session_finalize",
        })
        output = []
        with mock.patch.object(plugin, "_send", side_effect=lambda event: output.append(event) or True):
            secret = "DO-NOT-SEND-PROMPT-OR-RESULT"
            ctx.hooks["on_session_start"](session_id="private-session", model="model", platform="cli")
            ctx.hooks["pre_api_request"](session_id="private-session", user_message=secret,
                                          history=[secret], request={"secret": secret})
            ctx.hooks["post_tool_call"](session_id="private-session", tool_name="terminal",
                                         status="success", args={"password": secret}, result=secret)
            ctx.hooks["post_tool_call"](session_id="private-session", tool_name=secret,
                                         status="blocked", error_message=secret)
            ctx.hooks["on_human_input_request"](session_id="private-session", kind="approval",
                                                 request_id="secret-request", prompt=secret)
            ctx.hooks["on_human_input_resolved"](session_id="private-session", answer=secret)
            ctx.hooks["on_session_end"](session_id="private-session", completed=True,
                                        turn_exit_reason=secret)
            ctx.hooks["on_session_finalize"](session_id="private-session", reason=secret)
        self.assertEqual([event["event"] for event in output], [
            "session.start", "agent.working", "tool.finish", "tool.failed",
            "approval.request", "agent.working", "agent.completed", "session.end",
        ])
        self.assertNotIn(secret, json.dumps(output))
        self.assertNotIn("private-session", json.dumps(output))
        self.assertNotIn("secret-request", json.dumps(output))
        self.assertEqual([event["sequence"] for event in output], list(range(1, 9)))
        self.assertEqual(output[3]["tool_name"], "tool")
        self.assertTrue(output[4]["approval_id"].startswith("request-"))

    def test_turn_outcomes_do_not_end_durable_session(self):
        output = []
        with mock.patch.object(plugin, "_send", side_effect=lambda event: output.append(event) or True):
            plugin.on_session_end(session_id="s", failed=True)
            plugin.on_session_end(session_id="s", interrupted=True)
            plugin.on_session_end(session_id="s", completed=True)
        self.assertEqual([event["event"] for event in output],
                         ["agent.failed", "agent.waiting", "agent.completed"])

    def test_real_helper_process_receives_only_bounded_json(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / "events.jsonl"
            helper = root / "si-notchctl"
            helper.write_text("#!/bin/sh\nprintf '%s\\n' \"$2\" >> \"$SI_NOTCH_TEST_OUTPUT\"\n")
            helper.chmod(0o700)
            with mock.patch.dict(os.environ, {"SI_NOTCH_CLI": str(helper),
                                               "SI_NOTCH_TEST_OUTPUT": str(output)}):
                plugin.on_session_start(session_id="original-id", secret="never sent")
            event = json.loads(output.read_text().strip())
            self.assertEqual(event["event"], "session.start")
            self.assertEqual(event["provider"], "hermes")
            self.assertNotIn("original-id", output.read_text())
            self.assertNotIn("never sent", output.read_text())

    def test_invalid_helper_fails_open_without_running_process(self):
        with mock.patch.dict(os.environ, {"SI_NOTCH_CLI": "relative/helper"}):
            with mock.patch.object(plugin.subprocess, "run") as run:
                self.assertFalse(plugin._send({"event": "agent.working"}))
                run.assert_not_called()

    def test_system_app_install_is_supported(self):
        expected = Path("/Applications/si-notch.app/Contents/Helpers/si-notchctl")
        with mock.patch.dict(os.environ, {}, clear=True), \
             mock.patch.object(Path, "is_file", lambda path: path == expected), \
             mock.patch.object(plugin.os, "access", return_value=True):
            self.assertEqual(plugin._helper_path(), expected)

    def test_plugin_configuration_keeps_custom_app_path(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            helper = folder / "Custom App/si-notchctl"
            helper.parent.mkdir()
            helper.write_text("fixture; never executed")
            helper.chmod(0o700)
            (folder / "si-notch.json").write_text(json.dumps({"helperPath": str(helper)}))
            with mock.patch.dict(os.environ, {}, clear=True), \
                 mock.patch.object(plugin, "__file__", str(folder / "__init__.py")):
                self.assertEqual(plugin._helper_path(), helper)
                helper.chmod(0o600)
                self.assertIsNone(plugin._helper_path())

    def test_helper_timeout_is_bounded_and_fail_open(self):
        with tempfile.TemporaryDirectory() as temp:
            helper = Path(temp) / "si-notchctl"
            helper.write_text("#!/bin/sh\nexit 0\n")
            helper.chmod(0o700)
            with mock.patch.dict(os.environ, {"SI_NOTCH_CLI": str(helper)}):
                with mock.patch.object(plugin.subprocess, "run", side_effect=subprocess.TimeoutExpired(str(helper), 1.2)) as run:
                    self.assertFalse(plugin._send({"event": "agent.working"}))
                    self.assertEqual(run.call_args.kwargs["timeout"], 1.2)
                with mock.patch.object(plugin.subprocess, "run") as run:
                    self.assertFalse(plugin._send({"event": "agent.completed"}))
                    run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
