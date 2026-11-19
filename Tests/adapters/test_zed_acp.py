import importlib.util
import io
import json
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[2] / "scripts/adapters/zed-acp.py"
SPEC = importlib.util.spec_from_file_location("zed_acp", SOURCE)
BRIDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRIDGE)


class ZedACPTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.observer = BRIDGE.Observer(self.events.append)
        self.sid = "canonical-session"

    def request(self, identifier, method, **params):
        self.observer.frontend({"id": identifier, "method": method, "params": params})

    def reply(self, identifier, **result):
        self.observer.backend({"id": identifier, "result": result})

    def update(self, tag, **fields):
        self.observer.backend({"method": "session/update", "params": {
            "sessionId": self.sid, "update": {"sessionUpdate": tag, **fields}}})

    def test_v2_acknowledgement_keeps_turn_active_and_child_keeps_identity(self):
        self.request(1, "initialize")
        self.reply(1, protocolVersion=2)
        self.request(2, "session/new", cwd="/test")
        self.reply(2, sessionId=self.sid)
        self.request(3, "session/prompt", sessionId=self.sid, prompt=[{"text": "private-prompt"}])
        self.reply(3, messageId="accepted")
        self.assertEqual(self.events[-1]["event"], "agent.working")
        self.update("_subagent_update", subagentSessionId="child", name="Worker", task="private-task")
        self.update("state_update", state="idle", stopReason="end_turn")
        self.update("_subagent_update", subagentSessionId="child", state="completed")
        self.assertEqual(self.events[-1]["subagent"], {
            "id": "child", "sessionID": "child", "name": "Worker", "status": "completed"})
        self.assertEqual({(x["provider"], x["session_id"]) for x in self.events}, {("codex", self.sid)})
        self.assertNotIn("private-", json.dumps(self.events))

    def test_resume_replay_and_unknown_idle_do_not_claim_success(self):
        self.request(1, "session/load", sessionId=self.sid, cwd="/test")
        self.update("state_update", state="running")
        self.update("subagent_spawned", subagentSessionId="historical", name="Old")
        self.reply(1)
        self.assertEqual(self.events, [])
        self.request(2, "session/prompt", sessionId=self.sid)
        self.update("state_update", state="idle")
        self.assertEqual(self.events[-1]["event"], "session.end")
        self.request(3, "session/prompt", sessionId=self.sid)
        self.assertEqual([x["event"] for x in self.events[-2:]], ["session.start", "agent.working"])

    def test_oversize_and_unknown_messages_pass_through_without_observer_input(self):
        raw = b"x" * (BRIDGE.MAX_FRAME * 2 + 15) + b'\n{"unknown": "forwarded"}\n'
        output = io.BytesIO()
        seen = []
        BRIDGE.copy_frames(io.BytesIO(raw), output, seen.append)
        self.assertEqual(output.getvalue(), raw)
        self.assertEqual(seen, [{"unknown": "forwarded"}])

    def test_negotiation_adds_only_child_reporting_capability(self):
        params = {"protocolVersion": 2, "capabilities": {"fs": {"readTextFile": True}}}
        frame = {"id": 1, "method": "initialize", "params": params}
        new = BRIDGE.report_children_request(frame)
        reported = new["params"]["capabilities"].pop("_meta")
        self.assertEqual(new, frame)
        self.assertEqual(reported["jetbrains"]["air"]["capabilities"], ["nativeSubagentSessions"])
        self.assertIsNone(BRIDGE.report_children_request({"method": "session/request_permission"}))
