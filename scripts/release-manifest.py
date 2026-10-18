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
        if not isinstance(release, dict) or set(release) != {"version", "bundleVersion", "bundleBuild", "channel", "notes", "url", "sha256", "size"}:
            raise ValueError("release fields do not match the feed schema")
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
