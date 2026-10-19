#!/usr/bin/env python3
"""Preserve an unused private Unix socket before retrying SSH forwarding."""
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import sys
import uuid


def recover(value):
    if (not isinstance(value, str) or not value.startswith("/") or len(os.fsencode(value)) > 100
            or ":" in value or any(ord(c) < 32 or ord(c) == 127 for c in value)
            or any(part in (".", "..") for part in value.split("/"))):
        raise ValueError("Unsupported Unix socket path")
    path = Path(value)
    for ancestor in [*reversed(path.parents), path]:
        if ancestor.is_symlink():
            raise ValueError("Socket paths must not contain symlinks")
    for ancestor in [*reversed(path.parent.parents), path.parent]:
        info = ancestor.stat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.getuid())
                or (info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX)):
            raise ValueError("Unsafe socket directory ancestor")
    parent = path.parent.stat()
    if parent.st_uid != os.getuid() or parent.st_mode & 0o077:
        raise ValueError("Socket directory must be owned by this user with mode 0700")
    try:
        before = path.lstat()
    except FileNotFoundError:
        return {"state": "absent"}
    if not stat.S_ISSOCK(before.st_mode) or before.st_uid != os.getuid() or before.st_mode & 0o077:
        raise ValueError("Expected this user's private Unix socket")
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(2)
        try:
            client.connect(str(path))
        except ConnectionRefusedError:
            pass
        else:
            raise ValueError("Socket is active; disconnect its existing connection first")
    lsof = shutil.which("lsof")
    if lsof is None:
        raise ValueError("lsof is required to verify socket ownership")
    holders = subprocess.run([lsof, "-nP", "-Fpfnt", "--", str(path)], capture_output=True, timeout=5)
    if holders.returncode != 1 or holders.stdout.strip() or holders.stderr.strip():
        raise ValueError("Socket may be held by another process")
    current = path.lstat()
    if (before.st_dev, before.st_ino, before.st_mtime_ns) != (current.st_dev, current.st_ino, current.st_mtime_ns):
        raise ValueError("Socket changed during inspection")
    backup = path.with_name(path.name + ".stale-" + uuid.uuid4().hex)
    path.rename(backup)
    return {"state": "preserved", "backup": str(backup)}


if __name__ == "__main__":
    try:
        print(json.dumps({"ok": True, "data": recover(json.load(sys.stdin)["socket_path"])}))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(json.dumps({"ok": False, "error": str(error)[:500]}))
        sys.exit(1)
