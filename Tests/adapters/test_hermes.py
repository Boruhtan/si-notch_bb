"""Contract tests for our Hermes observer; no Hermes installation is required."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


PLUGIN = Path(__file__).resolve().parents[2] / "plugins/hermes/__init__.py"
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
        plugin._TASK_TITLES.clear()
        plugin._METADATA.clear()
        plugin._TODO_IDS.clear()
        plugin._CONTEXT = None
        plugin._DISABLED_UNTIL = 0

    def test_native_task_id_alias_and_failure_flags_never_forward_result_content(self):
        output=[]
        with mock.patch.object(plugin,"_send",side_effect=lambda event: output.append(event) or True):
            plugin.pre_llm_call(session_id="native-session",user_message="Test")
            plugin.pre_tool_call(task_id="native-session",tool_name="terminal")
            plugin.post_tool_call(task_id="native-session",tool_name="terminal",result='{"success":false,"error":"PRIVATE ERROR","output":"PRIVATE RESULT"}')
        self.assertEqual(output[-1]["event"],"tool.failed")
        self.assertEqual(output[-1]["session_id"],output[0]["session_id"])
        self.assertEqual(output[-2]["event"],"tool.start")
        self.assertNotIn("PRIVATE",json.dumps(output))

    def test_subdirectory_install_falls_back_to_the_bundled_relay(self):
        with mock.patch.object(plugin,"_helper_path",return_value=None), \
             mock.patch.object(plugin,"_settings",return_value={}), \
             mock.patch.dict(os.environ,{},clear=True), \
             mock.patch.object(plugin.subprocess,"run") as run:
            run.return_value.returncode=0
            self.assertTrue(plugin._send({"event":"agent.working"}))
            self.assertEqual(run.call_args.args[0][:2],[plugin.sys.executable,str(PLUGIN.parent/"relay.py")])

    def test_custom_tools_remain_visible_without_their_arguments_and_custom_socket_is_child_only(self):
        output = []
        with mock.patch.object(plugin, "_send", side_effect=lambda value: output.append(value) or True):
            plugin.pre_tool_call(session_id="s", tool_name="mcp_custom_search", args={"secret": "PRIVATE"})
            plugin.post_tool_call(session_id="s", tool_name="mcp_custom_search", result="PRIVATE")
        self.assertEqual(output[-1]["tool_name"], "mcp_custom_search")
        self.assertNotIn("PRIVATE", json.dumps(output))
        with tempfile.TemporaryDirectory() as directory:
            helper = Path(directory) / "helper"
            helper.write_text("fixture")
            helper.chmod(0o700)
            with mock.patch.object(plugin, "_helper_path", return_value=helper), \
                 mock.patch.object(plugin, "_settings", return_value={"socketPath": "/remote/private/events.sock"}), \
                 mock.patch.object(plugin.subprocess, "run") as run:
                run.return_value.returncode = 0
                plugin._send({"event": "agent.working"})
                self.assertEqual(run.call_args.kwargs["env"]["SI_NOTCH_SOCKET"], "/remote/private/events.sock")
                self.assertNotEqual(os.environ.get("SI_NOTCH_SOCKET"), "/remote/private/events.sock")

    def test_official_observer_contract_and_lifecycle(self):
        ctx = Context()
        plugin.register(ctx)
        self.assertEqual(set(ctx.hooks), {
            "on_session_start", "pre_llm_call", "pre_api_request", "pre_tool_call", "post_tool_call",
            "on_interim_message", "post_llm_call",
            "on_human_input_request", "on_human_input_resolved",
            "on_session_end", "on_session_finalize",
            "subagent_start", "subagent_stop",
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

    def test_model_and_effort_follow_actual_requests_without_forwarding_request_content(self):
        output = []
        with mock.patch.object(plugin, "_send", side_effect=lambda event: output.append(event) or True):
            plugin.on_session_start(session_id="s", model="configured-alias")
            plugin.pre_api_request(session_id="s", model="configured-alias", request={"method": "POST", "body": {
                "model": "actual-model", "reasoning": {"effort": "high"},
                "messages": [{"content": "PRIVATE PROMPT"}], "api_key": "PRIVATE KEY"}})
            plugin.pre_tool_call(session_id="s", tool_name="terminal")
            self.assertEqual(output[-1]["model"], "actual-model")
            self.assertEqual(output[-1]["reasoning_effort"], "high")
            plugin.pre_api_request(session_id="s", request={"body": {"model": "actual-model"}})
            self.assertEqual(output[-1]["reasoning_effort"], "")
            plugin.pre_api_request(session_id="s", request={"body": {
                "model": "fallback-model", "extra_body": {"reasoning_effort": "low"}}})
            self.assertEqual(output[-1]["model"], "fallback-model")
            self.assertEqual(output[-1]["reasoning_effort"], "low")
            plugin.on_session_finalize(session_id="s")
        self.assertFalse(plugin._METADATA)
        self.assertNotIn("PRIVATE", json.dumps(output))

    def test_reasoning_metadata_rejects_text_and_handles_native_thinking_settings(self):
        self.assertIsNone(plugin._reasoning({"reasoning": "PRIVATE THOUGHTS", "reasoning_effort": "PRIVATE THOUGHTS"}))
        self.assertEqual(plugin._reasoning({"thinking": {"type": "enabled", "budget_tokens": 8192}}), "8192 tokens")
        self.assertEqual(plugin._reasoning({"thinking": {"type": "disabled"}}), "off")
        self.assertEqual(plugin._reasoning({"thinking": {"type": "adaptive"}}), "adaptive")
        self.assertIsNone(plugin._metadata_text("bad\nmodel"))
        self.assertIsNone(plugin._metadata_text("я" * 129))

    def test_native_context_supplies_session_project_without_using_process_cwd(self):
        output = []
        ctx = Context()
        ctx.session_cwd = lambda: "/work/session-project"
        plugin.register(ctx)
        with mock.patch.object(plugin, "_send", side_effect=lambda event: output.append(event) or True):
            plugin.pre_llm_call(session_id="s", model="model")
        self.assertEqual(output[-1]["cwd"], "/work/session-project")
        self.assertEqual(output[-1]["model"], "model")

    def test_native_todos_sync_titles_status_and_removals_without_other_tool_content(self):
        output = []
        settings = {"showSessionText": True}
        with mock.patch.object(plugin, "_settings", return_value=settings), \
             mock.patch.object(plugin, "_send", side_effect=lambda event: output.append(event) or True):
            plugin.post_tool_call(session_id="s", tool_name="todo_list", result=json.dumps({"todos": [
                {"id": "one", "content": "Check metadata", "status": "in_progress"},
                {"id": "two", "content": "Check settings", "status": "completed"}], "output": "PRIVATE OUTPUT"}))
            tasks = [event["task"] for event in output if "task" in event]
            self.assertEqual([task["title"] for task in tasks], ["Check metadata", "Check settings"])
            self.assertEqual([task["status"] for task in tasks], ["working", "completed"])
            plugin.post_tool_call(session_id="s", tool_name="todo", result='{"todos":[]}')
            self.assertEqual([event["task"]["status"] for event in output if "task" in event][-2:], ["ended", "ended"])
            settings["showSessionText"] = False
            plugin.post_tool_call(session_id="s", tool_name="todo", result='{"todos":[{"id":"three","content":"PRIVATE TASK","status":"pending"}]}')
            self.assertEqual(output[-1]["task"]["title"], "Task 1")
        self.assertNotIn("PRIVATE", json.dumps(output))

    def test_native_subagent_lifecycle_updates_parent_and_excludes_child_content(self):
        output = []
        with mock.patch.object(plugin, "_send", side_effect=lambda event: output.append(event) or True):
            plugin.subagent_start(parent_session_id="parent", child_session_id="child", child_role="reviewer", child_goal="PRIVATE GOAL")
            plugin.subagent_stop(parent_session_id="parent", child_session_id="child", child_role="reviewer", child_status="failed", child_summary="PRIVATE SUMMARY")
        self.assertEqual([event["event"] for event in output], ["subagent.start", "subagent.end"])
        self.assertEqual(output[0]["session_id"], output[1]["session_id"])
        self.assertEqual(output[0]["subagent"]["id"], output[1]["subagent"]["id"])
        self.assertEqual(output[1]["subagent"]["status"], "failed")
        self.assertNotIn("PRIVATE", json.dumps(output))

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
                                               "SI_NOTCH_TEST_OUTPUT": str(output)}), \
                 mock.patch.object(plugin, "_TIMEOUT_SECONDS", 5):
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

    def test_configured_name_is_sent_without_session_content(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            (folder / "si-notch.json").write_text(json.dumps({"displayName": "Lane"}))
            output = []
            with mock.patch.object(plugin, "__file__", str(folder / "__init__.py")), \
                 mock.patch.object(plugin, "_send", side_effect=lambda event: output.append(event) or True):
                plugin.pre_api_request(session_id="private-session", user_message="PRIVATE PROMPT")
                plugin.on_session_end(session_id="private-session", completed=True, output="PRIVATE RESULT")
            self.assertEqual([event["title"] for event in output], ["Lane"] * 3)
            self.assertNotIn("PRIVATE", json.dumps(output))

    def test_invalid_names_and_symlinked_settings_keep_default(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            config = folder / "si-notch.json"
            with mock.patch.object(plugin, "__file__", str(folder / "__init__.py")):
                for name in (None, False, [], "", " " * 5, "x" * 129, "Lane\nremote", "Lane\x7f"):
                    with self.subTest(name=name):
                        config.write_text(json.dumps({"displayName": name}))
                        self.assertEqual(plugin._display_name(), "Hermes Agent")
                config.write_text("{invalid")
                self.assertEqual(plugin._display_name(), "Hermes Agent")
                config.rename(folder / "other.json")
                config.symlink_to(folder / "other.json")
                (folder / "other.json").write_text(json.dumps({"displayName": "Untrusted"}))
                self.assertEqual(plugin._display_name(), "Hermes Agent")

    def test_session_text_is_opt_in_and_tool_observer_never_returns_a_directive(self):
        output = []
        with mock.patch.object(plugin, "_settings", return_value={}), \
             mock.patch.object(plugin, "_send", side_effect=lambda event: output.append(event) or True):
            plugin.pre_llm_call(session_id="s", user_message="PRIVATE PROMPT")
            result = plugin.pre_tool_call(session_id="s", tool_name="terminal", args={"token": "PRIVATE TOKEN"})
            plugin.on_interim_message(session_id="s", text="PRIVATE UPDATE")
            plugin.post_llm_call(session_id="s", assistant_response="PRIVATE ANSWER")
        self.assertIsNone(result)
        self.assertNotIn("PRIVATE", json.dumps(output))
        self.assertEqual(output[-1]["event"], "tool.start")

    def test_opted_in_task_progress_and_answer_exclude_other_hook_content(self):
        output = []
        with mock.patch.object(plugin, "_settings", return_value={"showSessionText": True}), \
             mock.patch.object(plugin, "_send", side_effect=lambda event: output.append(event) or True):
            plugin.pre_llm_call(session_id="s", turn_id="t", user_message="message:\nCheck SSH\n\nPRIVATE INSTRUCTIONS",
                                conversation_history=["PRIVATE HISTORY"])
            plugin.pre_tool_call(session_id="s", turn_id="t", tool_name="terminal", args={"token": "PRIVATE TOKEN"})
            plugin.post_tool_call(session_id="s", turn_id="t", tool_name="terminal", status="ok", result="PRIVATE RESULT")
            plugin.on_interim_message(session_id="s", turn_id="t", text="Checking connection", reasoning="PRIVATE REASONING")
            plugin.post_llm_call(session_id="s", turn_id="t", assistant_response="Connection verified",
                                 conversation_history=["PRIVATE HISTORY"])
            plugin.on_session_end(session_id="s", turn_id="t", completed=True)
        self.assertEqual(output[1]["first_prompt"], "Check SSH")
        self.assertTrue(all(event["title"] == "Hermes Agent · Check SSH" for event in output))
        self.assertEqual(output[-3]["message"], "Checking connection")
        self.assertEqual(output[-2]["message"], "Connection verified")
        self.assertEqual(output[-1]["event"], "agent.completed")
        self.assertNotIn("PRIVATE", json.dumps(output))
        self.assertEqual(len({event["turn_id"] for event in output[1:]}), 1)

    def test_visible_text_is_bounded_and_requires_a_boolean_opt_in(self):
        with mock.patch.object(plugin, "_settings", return_value={"showSessionText": "true"}):
            self.assertIsNone(plugin._session_text("private"))
        with mock.patch.object(plugin, "_settings", return_value={"showSessionText": True}):
            self.assertEqual(plugin._session_text("\x00ready\x7f"), "ready")
            self.assertEqual(len(plugin._session_text("x" * 5000)), 4000)
            self.assertEqual(len(plugin._session_text("x" * 2000, prompt=True)), 1600)

    def test_task_title_follows_new_turn_and_is_removed_when_text_is_disabled(self):
        output = []
        settings = {"showSessionText": True, "displayName": "Lane"}
        with mock.patch.object(plugin, "_settings", return_value=settings), \
             mock.patch.object(plugin, "_send", side_effect=lambda event: output.append(event) or True):
            plugin.pre_llm_call(session_id="s", user_message="Check SSH")
            plugin.pre_tool_call(session_id="s", tool_name="terminal")
            self.assertEqual(output[-1]["title"], "Lane · Check SSH")
            plugin.pre_llm_call(session_id="s", user_message="Check delivery")
            self.assertEqual(output[-1]["title"], "Lane · Check delivery")
            settings["showSessionText"] = False
            plugin.pre_api_request(session_id="s")
            self.assertEqual(output[-1]["title"], "Lane")
            plugin.on_session_finalize(session_id="s")
            self.assertEqual(plugin._TASK_TITLES, {})

    def test_profile_identity_scopes_sessions_and_announces_presence(self):
        output = []
        with mock.patch.object(plugin, "_settings", return_value={"instanceId": "host:architect", "displayName": "Architect"}), \
             mock.patch.object(plugin, "_send", side_effect=lambda event: output.append(event) or True):
            plugin.register(Context())
            plugin.pre_api_request(session_id="shared-native-id")
            first = output[-1]
        with mock.patch.object(plugin, "_settings", return_value={"instanceId": "host:researcher", "displayName": "Researcher"}), \
             mock.patch.object(plugin, "_send", side_effect=lambda event: output.append(event) or True):
            plugin.pre_api_request(session_id="shared-native-id")
        self.assertEqual(output[0]["event"], "agent.presence")
        self.assertEqual(first["connection_name"], "Architect")
        self.assertNotEqual(first["connection_id"], output[-1]["connection_id"])
        self.assertNotEqual(first["session_id"], output[-1]["session_id"])
        self.assertNotIn("shared-native-id", json.dumps(output))


if __name__ == "__main__":
    unittest.main()
