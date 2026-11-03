#!/usr/bin/env python3
"""Configure distinct si-notch observers in existing local Hermes profiles.

Dry-run by default. Backups stay outside the repository; Hermes owns config edits.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--root", type=Path, default=Path.home() / ".hermes")
    parser.add_argument("--hermes", type=Path, default=Path.home() / ".local/bin/hermes")
    parser.add_argument("--helper", type=Path, default=Path.home() / "Applications/si-notch.app/Contents/Helpers/si-notchctl")
    parser.add_argument("--backup-root", type=Path, default=Path.home() / ".local/share/si-notch/backups")
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1] / "plugins/hermes"
    root = args.root.absolute()
    profiles = [("default", root)] + [(p.name, p) for p in sorted((root / "profiles").iterdir() if (root / "profiles").is_dir() else [])
        if p.is_dir() and not p.is_symlink() and re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]*", p.name)]
    plan, identities = [], set()
    for name, home in profiles:
        plugin = home / "plugins/si-notch"
        settings = plugin / "si-notch.json"
        if plugin.is_symlink() or settings.is_symlink():
            raise ValueError("Refusing shared/symlinked observer for profile " + name)
        if settings.exists() and settings.stat().st_size > 8192:
            raise ValueError("Oversized observer settings for " + name)
        before = json.loads(settings.read_text()) if settings.exists() else {}
        if not isinstance(before, dict):
            raise ValueError("Invalid observer settings for " + name)
        instance = before.get("instanceId")
        if not isinstance(instance, str) or not instance or instance in identities:
            # Only the observer identity changes; model/credential/history files are untouched.
            if (plugin / "usage-outbox").exists() and any((plugin / "usage-outbox").iterdir()):
                raise ValueError("Deliver pending usage before changing cloned identity for " + name)
            instance = uuid.uuid4().hex
        identities.add(instance)
        value = dict(before)
        value.update(instanceId=instance, displayName=before.get("displayName") or ("Hermes" if name == "default" else name),
                     helperPath=str(args.helper), socketPath=str(Path.home() / ".si-notch/run/events.sock"))
        label = value["displayName"]
        if not isinstance(label, str) or not 1 <= len(label.strip()) <= 128 or any(ord(c) < 32 or ord(c) == 127 for c in label):
            raise ValueError("Invalid display name for " + name)
        value["displayName"] = label.strip()
        value.setdefault("showSessionText", False)
        plan.append((name, home, plugin, value))
    print(json.dumps({"apply": args.apply, "profiles": [p[0] for p in plan], "unique_identities": len(identities)}))
    if not args.apply:
        return
    if not args.hermes.is_file() or not args.helper.is_file():
        raise ValueError("Hermes CLI and native si-notch helper must exist")
    backup = args.backup_root / ("local-profiles-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8])
    backup.mkdir(mode=0o700, parents=True)
    env = dict(os.environ)
    env.pop("HERMES_HOME", None)
    env.pop("HERMES_PROFILE", None)
    for name, home, plugin, value in plan:
        saved = backup / name
        saved.mkdir(mode=0o700)
        config = home / "config.yaml"
        if config.exists():
            shutil.copy2(config, saved / "config.yaml")
            os.chmod(saved / "config.yaml", 0o600)
        if plugin.exists():
            shutil.copytree(plugin, saved / "si-notch")
        plugin.mkdir(parents=True, exist_ok=True)
        for filename in ("__init__.py", "plugin.yaml", "relay.py", "configure.py"):
            shutil.copy2(source / filename, plugin / filename)
        descriptor, temporary = tempfile.mkstemp(dir=plugin, prefix=".si-notch-settings-")
        try:
            with os.fdopen(descriptor, "w") as stream:
                json.dump(value, stream, ensure_ascii=False, indent=2)
                stream.write("\n")
            os.chmod(temporary, 0o600)
            os.replace(temporary, plugin / "si-notch.json")
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        command = [str(args.hermes)] + ([] if name == "default" else ["-p", name]) + ["plugins", "enable", "si-notch"]
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=90)
        if result.returncode:
            (saved / "enable-error.log").write_text(result.stderr + result.stdout)
            os.chmod(saved / "enable-error.log", 0o600)
            raise RuntimeError("Enable failed for " + name + "; local backup: " + str(saved))
        print(json.dumps({"profile": name, "configured": True,
            "connection_id": "hermes-instance-" + hashlib.sha256(value["instanceId"].encode()).hexdigest()[:32]}))
    print(json.dumps({"ok": True, "backup": str(backup)}))


if __name__ == "__main__":
    main()
