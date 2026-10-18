#!/usr/bin/env python3
"""Run no-model CLI smoke checks and local hook/socket tests in an isolated home.

This script never installs agents or edits their user configuration. Supply paths to
already staged binaries. The local integration tests create and remove private
Unix sockets; they do not connect to an agent account or invoke a model.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def isolated_environment(root: Path) -> dict[str, str]:
    """Give child CLIs a disposable profile and withhold inherited credentials."""
    paths = {name: root / name for name in ("config", "cache", "data", "tmp")}
    for directory in paths.values():
        directory.mkdir(mode=0o700)
    return {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
        "HOME": str(root),
        "XDG_CONFIG_HOME": str(paths["config"]),
        "XDG_CACHE_HOME": str(paths["cache"]),
        "XDG_DATA_HOME": str(paths["data"]),
        "TMPDIR": str(paths["tmp"]),
        "NODE_COMPILE_CACHE": str(paths["cache"] / "node"),
        "AGENT_CLI_CREDENTIAL_STORE": "file",
        "DISABLE_AUTOUPDATER": "1",
        "CI": "1",
        "NO_COLOR": "1",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True, help="built si-notchctl")
    for name in ("gemini", "copilot", "claude", "cursor", "hermes"):
        parser.add_argument("--" + name, type=Path, help="optional staged CLI executable")
    args = parser.parse_args()
    helper = args.helper.resolve()
    if not helper.is_file() or not os.access(helper, os.X_OK):
        parser.error("--helper must be an executable file")

    with tempfile.TemporaryDirectory(prefix="si-notch-harness-check-", dir="/private/tmp") as temporary:
        scratch = Path(temporary)
        environment = isolated_environment(scratch)
        versions = {}
        for name in ("gemini", "copilot", "claude", "cursor", "hermes"):
            path = getattr(args, name)
            if path is None:
                continue
            binary = path.resolve()
            if not binary.is_file() or not os.access(binary, os.X_OK):
                versions[name] = {"exit": "missing"}
                continue
            try:
                result = subprocess.run([str(binary), "--version"], cwd=scratch,
                                        env=environment, text=True, capture_output=True,
                                        timeout=20, check=False)
                versions[name] = {"exit": result.returncode,
                                  "version": (result.stdout or result.stderr).strip().splitlines()[:1]}
            except (OSError, subprocess.TimeoutExpired) as error:
                versions[name] = {"exit": type(error).__name__}

        tests_env = environment | {"SI_NOTCH_HELPER": str(helper), "PYTHONDONTWRITEBYTECODE": "1"}
        tests = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s",
                                "Tests/adapters", "-p", "test_*.py", "-q"],
                               cwd=ROOT, env=tests_env, text=True, capture_output=True,
                               timeout=30, check=False)
        print(json.dumps({"cli_versions": versions, "hook_tests_exit": tests.returncode,
                          "hook_tests_output": (tests.stdout + tests.stderr).strip()[-1200:]},
                         ensure_ascii=False, indent=2))
        if tests.returncode != 0 or any(value["exit"] != 0 for value in versions.values()):
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
