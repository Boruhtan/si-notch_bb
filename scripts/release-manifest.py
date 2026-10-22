#!/usr/bin/env python3
"""Sign a si-notch update feed with an existing Ed25519 PEM private key.

The signing key stays outside the repository. This tool never creates keys or
publishes the output; the release operator supplies both paths explicitly.
"""

import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import urlparse


def validate(feed):
    if not isinstance(feed, dict) or feed.get("feedVersion") != 1:
        raise ValueError("feedVersion must be 1")
    releases = feed.get("releases")
    if not isinstance(releases, list) or not 1 <= len(releases) <= 100:
        raise ValueError("releases must contain 1–100 items")
    for release in releases:
        if not isinstance(release, dict) or set(release) - {"pluginUpdates"} != {"version", "bundleVersion", "bundleBuild", "channel", "notes", "url", "sha256", "size"}:
            raise ValueError("release fields do not match the feed schema")
        validate_plugins(release.get("pluginUpdates", []))
        number = r"(?:0|[1-9][0-9]*)"
        pattern = rf"{number}\.{number}\.{number}(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?"
        if not isinstance(release["version"], str) or not re.fullmatch(pattern, release["version"]):
            raise ValueError("invalid release version")
        if not isinstance(release["bundleVersion"], str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", release["bundleVersion"]):
            raise ValueError("bundleVersion must match CFBundleShortVersionString")
        if not isinstance(release["bundleBuild"], str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", release["bundleBuild"]):
            raise ValueError("bundleBuild must match CFBundleVersion")
        if release["channel"] not in ("stable", "beta"):
            raise ValueError("channel must be stable or beta")
        if not isinstance(release["notes"], str) or len(release["notes"].encode()) > 64_000:
            raise ValueError("release notes are too large")
        url = urlparse(release["url"])
        if url.scheme != "https" or not url.hostname:
            raise ValueError("archive URL must use HTTPS")
        if not re.fullmatch(r"[0-9a-f]{64}", release["sha256"]):
            raise ValueError("sha256 must be 64 lowercase hex characters")
        if type(release["size"]) is not int or not 1 <= release["size"] <= 250 * 1024 * 1024:
            raise ValueError("archive size is out of bounds")


def validate_plugins(plugins):
    if not isinstance(plugins, list) or len(plugins) > 20:
        raise ValueError("pluginUpdates must contain at most 20 items")
    ids = set()
    for plugin in plugins:
        if not isinstance(plugin, dict) or set(plugin) != {"id", "name", "version", "change", "installURL"}:
            raise ValueError("invalid plugin fields")
        if not isinstance(plugin["id"], str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", plugin["id"]) or plugin["id"] in ids:
            raise ValueError("invalid or duplicate plugin id")
        ids.add(plugin["id"])
        name = plugin["name"]
        if not isinstance(name, str) or not 1 <= len(name) <= 80 or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in name):
            raise ValueError("invalid plugin name")
        if not isinstance(plugin["version"], str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}(?:-[A-Za-z0-9.-]+)?", plugin["version"]):
            raise ValueError("invalid plugin version")
        if plugin["change"] not in ("added", "updated"):
            raise ValueError("invalid plugin change")
        from urllib.parse import unquote
        link = plugin["installURL"]
        if not isinstance(link, str) or len(link.encode()) > 2048:
            raise ValueError("invalid plugin URL")
        url = urlparse(link)
        path = [p for p in unquote(url.path).split("/") if p]
        if (url.scheme != "https" or url.hostname != "github.com" or url.username is not None or
            url.password is not None or url.port is not None or url.query or len(path) < 2 or
            not re.fullmatch(r"[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+", "/".join(path[:2])) or
            any(p in (".", "..") for p in path)):
            raise ValueError("plugin installation URL must be a GitHub repository page")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--feed", required=True, type=Path, help="unsigned JSON feed")
    parser.add_argument("--private-key", required=True, type=Path, help="existing Ed25519 PEM private key")
    parser.add_argument("--output", required=True, type=Path, help="signed envelope JSON")
    args = parser.parse_args()
    if not args.private_key.is_file():
        parser.error("private key file does not exist")
    feed = json.loads(args.feed.read_text(encoding="utf-8"))
    validate(feed)
    payload = json.dumps(feed, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    if len(payload) > 512_000:
        parser.error("feed payload is too large")
    with tempfile.TemporaryDirectory(prefix="si-notch-sign-") as temp:
        payload_file = Path(temp) / "payload.json"
        signature_file = Path(temp) / "signature.bin"
        payload_file.write_bytes(payload)
        subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(args.private_key),
                        "-in", str(payload_file), "-out", str(signature_file)], check=True)
        signature = signature_file.read_bytes()
        if len(signature) != 64:
            raise ValueError("signing key must be Ed25519")
    envelope = json.dumps({"payload": base64.b64encode(payload).decode(),
                           "signature": base64.b64encode(signature).decode()}, separators=(",", ":")) + "\n"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".si-notch-feed-", dir=args.output.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(envelope)
        os.replace(temporary, args.output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(args.output)


if __name__ == "__main__":
    main()
