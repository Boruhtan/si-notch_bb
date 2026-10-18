#!/usr/bin/env python3
"""Exercise all provider cards through the running app; remove only our fixtures."""
import argparse
import json
from pathlib import Path
import subprocess
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    args = parser.parse_args()
    helper = str(args.helper.resolve())
    providers = ["codex", "pi", "claude", "opencode", "hermes", "gemini", "copilot", "cursor", "custom"]
    prefix = "si-notch-check-" + uuid.uuid4().hex
    ids = {p: prefix + "-" + p for p in providers}
    def invoke(*arguments):
        output = subprocess.check_output([helper, *arguments], text=True, timeout=4)
        return json.loads(output) if output.strip() else {"ok": True}
    def send(provider, event, sequence, **fields):
        result = invoke("emit", json.dumps(dict(event=event, provider=provider, session_id=ids[provider],
                                                id=f"{prefix}-{provider}-{sequence}", sequence=sequence, **fields)))
        assert result.get("ok"), result
    try:
        for provider in providers:
            send(provider, "agent.working", 1, title=f"Fixture: check {provider}",
                 first_prompt="Check a long task title and keep each provider session separate.",
                 message="Starting the local display check.")
        status = invoke("status")
        found = {s["id"]: s for s in status["sessions"]}
        assert all(found[ids[p]]["provider"] == p and found[ids[p]]["status"] == "working" for p in providers)
        for provider in providers:
            send(provider, "tool.start", 2, tool_name="read_file")
            send(provider, "tool.finish", 3, tool_name="read_file")
            send(provider, "agent.completed", 4, message="Local display check complete.")
        found = {s["id"]: s for s in invoke("status")["sessions"]}
        assert all(found[ids[p]]["status"] == "completed" for p in providers)
        print(json.dumps({"result": "passed", "providers": providers, "events": 36,
                          "scope": "real helper and GUI; synthetic provider events"}))
    finally:
        for provider in providers:
            send(provider, "session.end", 5)
        remaining = {s["id"] for s in invoke("status")["sessions"]}
        assert not remaining.intersection(ids.values()), "fixture cleanup failed"
        print("Fixture sessions removed; existing user sessions preserved.")


if __name__ == "__main__":
    main()
