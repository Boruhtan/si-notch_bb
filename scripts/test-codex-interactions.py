#!/usr/bin/env python3
"""Disposable Desktop protocol fixture for --qa-interactions; executes no tools.

Prints the private socket and thread ID. Drive the app with computer use, then
read receipts.jsonl to verify the exact request IDs, choices and wire responses.
"""
import json
import os
from pathlib import Path
import socket
import struct
import tempfile
import uuid

directory = Path(tempfile.mkdtemp(prefix="si-notch-interaction-qa-", dir="/private/tmp"))
os.chmod(directory, 0o700)
socket_path = directory / "events.sock"
session = str(uuid.uuid4())
owner = str(uuid.uuid4())
turn = str(uuid.uuid4())
listener = socket.socket(socket.AF_UNIX)
listener.bind(str(socket_path))
os.chmod(socket_path, 0o600)
listener.listen(1)
print(json.dumps({"socket": str(socket_path), "session": session, "receipts": str(directory / "receipts.jsonl")}), flush=True)
connection, _ = listener.accept()
connection.settimeout(600)
client = None
stage = 0
revision = 1
accepted = []

def send(value):
    data = json.dumps(value).encode()
    connection.sendall(struct.pack("<I", len(data)) + data)

def receive():
    def read(size):
        data = b""
        while len(data) < size:
            part = connection.recv(size - len(data))
            if not part:
                raise EOFError()
            data += part
        return data
    size = struct.unpack("<I", read(4))[0]
    if size > 128 * 1024:
        raise ValueError("oversized fixture input")
    return json.loads(read(size))

def reply(frame, result):
    send({"type": "response", "requestId": frame["requestId"], "method": frame["method"],
          "resultType": "success", "handledByClientId": owner, "result": result})

def snapshot():
    requests = []
    items = [{"type": "userMessage", "content": [{"type": "text", "text": "Disposable interaction verification"}]}] + accepted
    flags = ["waitingOnUserInput"]
    if stage == 0:
        items.append({"type": "agentMessage", "id": "qa-async", "text": "Test question; no action is executed.",
                      "questions": [{"title": "QA: choose the second option", "options": ["First option", "Second option"]}]})
    elif stage in (1, 2, 3):
        flags = ["waitingOnApproval"]
        decisions = ["accept", "decline"]
        if stage == 3:
            decisions += [{"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["printf", "QA_ONLY"]}}]
        requests = [{"id": 40 + stage, "method": "item/commandExecution/requestApproval",
                     "params": {"threadId": session, "turnId": turn, "itemId": "qa-command",
                                "command": "printf QA_ONLY (fixture, never executed)",
                                "reason": ["", "QA: allow once", "QA: deny", "QA: allow the exact rule"][stage],
                                "proposedExecpolicyAmendment": ["printf", "QA_ONLY"], "availableDecisions": decisions}}]
    elif stage == 4:
        requests = [{"id": 44, "method": "item/tool/requestUserInput", "params": {"threadId": session, "turnId": turn,
            "questions": [{"id": "choice", "question": "QA: select Blue", "options": [{"label": "Blue"}, {"label": "Green"}]},
                          {"id": "free", "question": "QA: type verified"}]}}]
    else:
        flags = ["waitingOnApproval"]
        requests = [{"id": 45, "method": "item/permissions/requestApproval", "params": {"threadId": session, "turnId": turn,
                     "permissions": {"network": True}, "reason": "QA unsupported request: use Codex"}}]
    root = {"id": session, "title": "QA — approvals and choices", "cwd": "/private/tmp", "requests": requests,
            "threadRuntimeStatus": {"type": "active", "activeFlags": flags},
            "turns": [{"turnId": turn, "turnStartedAtMs": 1000, "status": "inProgress", "items": items}]}
    send({"type": "broadcast", "version": 11, "sourceClientId": owner, "targetClientIds": [client],
          "method": "thread-stream-state-changed", "params": {"hostId": "local", "conversationId": session,
          "change": {"type": "snapshot", "revision": revision, "conversationState": root}}})

try:
    while True:
        frame = receive()
        method = frame.get("method")
        params = frame.get("params", {})
        if method == "initialize":
            client = str(uuid.uuid4())
            reply(frame, {"clientId": client})
        elif method == "thread-stream-following-changed" and params.get("hostId") == "local" and params.get("following"):
            snapshot()
        elif method == "thread-owner-discovery":
            assert params == {"hostId": "local", "conversationId": session}
            assert frame.get("targetClientId") == owner
            reply(frame, {"supportsUntrustedAppInput": True})
        elif method and method.startswith("thread-follower-"):
            assert frame.get("targetClientId") == owner and params.get("conversationId") == session
            if stage == 0:
                assert method == "thread-follower-steer-turn"
                text = params["input"][0]["text"]
                value = json.loads(text.removeprefix("<send_user_message_question_reply>\n").removesuffix("\n</send_user_message_question_reply>"))
                assert value == [{"questionItemId": '["request_user_input_async","qa-async",0]',
                                  "question": "QA: choose the second option", "answer": "Second option"}], value
                accepted.append({"type": "steeringUserMessage", "status": "accepted", "input": params["input"]})
                result = {"result": {"turnId": turn}}
            elif stage in (1, 2, 3):
                assert method == "thread-follower-command-approval-decision" and params.get("requestId") == 40 + stage
                expected = {1: "accept", 2: "decline", 3: {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["printf", "QA_ONLY"]}}}[stage]
                assert params.get("decision") == expected, params
                result = {"ok": True}
            elif stage == 4:
                assert method == "thread-follower-submit-user-input" and params.get("requestId") == 44
                assert params.get("response") == {"answers": {"choice": {"answers": ["Blue"]}, "free": {"answers": ["verified"]}}}, params
                result = {"ok": True}
            else:
                raise AssertionError("Unsupported request must not be answered")
            with (directory / "receipts.jsonl").open("a") as output:
                output.write(json.dumps({"stage": stage, "method": method, "verified": True}) + "\n")
            reply(frame, result)
            stage += 1
            revision += 1
            snapshot()
except EOFError:
    pass
finally:
    connection.close()
    listener.close()
    socket_path.unlink(missing_ok=True)
