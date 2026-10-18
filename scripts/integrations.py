#!/usr/bin/env python3
"""Print si-notch integration snippets; never read or modify agent settings."""

import argparse
import json
from pathlib import Path
import shlex
import sys


CLAUDE_EVENTS = (
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "PermissionRequest",
    "Notification",
    "SubagentStart",
    "SubagentStop",
    "PreCompact",
    "PostCompact",
    "Stop",
    "SessionEnd",
)


def absolute_cli(value):
    """Keep paths literal; do not expand a shell expression or inspect the file."""
    if not Path(value).is_absolute():
        raise argparse.ArgumentTypeError("--cli requires an absolute path")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise argparse.ArgumentTypeError("--cli must not contain control characters")
    return value


def claude_snippet(cli):
    command = shlex.join([cli, "hook", "--agent", "claude"])
    # An observer prints no permission decision and preserves the native flow.
    handler = {"type": "command", "command": command, "timeout": 3}
    return {"hooks": {event: [{"hooks": [dict(handler)]}] for event in CLAUDE_EVENTS}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", required=True, choices=("claude", "codex"))
    parser.add_argument("--cli", required=True, type=absolute_cli,
                        help="absolute installed si-notchctl path; not opened or executed")
    args = parser.parse_args()
    if args.provider == "claude":
        json.dump(claude_snippet(args.cli), sys.stdout, ensure_ascii=False, indent=2)
        print()
    else:
        # JSON basic string/array syntax is also valid TOML for these arguments.
        print("notify = " + json.dumps([args.cli, "notify"], ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
