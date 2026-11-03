import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[2] / "scripts/install-local-hermes-profiles.py"
spec = importlib.util.spec_from_file_location("local_profile_installer", SOURCE)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class LocalProfileInstallerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "hermes"
        self.root.mkdir()
        self.executable = Path(temporary.name) / "helper"
        self.executable.write_text("#!/bin/sh\nexit 0\n")
        self.executable.chmod(0o700)
        self.backup = Path(temporary.name) / "backups"

    def invoke(self, apply=False):
        command = [str(SOURCE), "--root", str(self.root), "--helper", str(self.executable),
                   "--hermes", str(self.executable), "--backup-root", str(self.backup)]
        if apply:
            command.append("--apply")
        output = io.StringIO()
        with mock.patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run, \
                mock.patch("sys.argv", command), contextlib.redirect_stdout(output):
            installer.main()
        return [json.loads(line) for line in output.getvalue().splitlines()], run

    def settings(self, profile, **values):
        home = self.root if profile == "default" else self.root / "profiles" / profile
        plugin = home / "plugins/si-notch"
        plugin.mkdir(parents=True, exist_ok=True)
        file = plugin / "si-notch.json"
        file.write_text(json.dumps(values))
        return file

    def testDryRunListsProfilesWithoutWritesOrCliExecution(self):
        (self.root / "profiles/coder").mkdir(parents=True)
        (self.root / "profiles/legal").mkdir()
        before = set(self.root.rglob("*"))
        result, run = self.invoke()
        self.assertEqual(result[0]["profiles"], ["default", "coder", "legal"])
        self.assertEqual(result[0]["unique_identities"], 3)
        self.assertEqual(before, set(self.root.rglob("*")))
        self.assertFalse(self.backup.exists())
        run.assert_not_called()

    def testApplyPreservesIdentityPrivateSettingsAndBackup(self):
        file = self.settings("default", instanceId="existing", displayName="Main", showSessionText=True)
        original = file.read_bytes()
        config = self.root / "config.yaml"
        config.write_text("unrelated: keep\n")
        result, run = self.invoke(apply=True)
        current = json.loads(file.read_text())
        self.assertEqual(current["instanceId"], "existing")
        self.assertTrue(current["showSessionText"])
        saved = Path(result[-1]["backup"])
        self.assertEqual((saved / "default/si-notch/si-notch.json").read_bytes(), original)
        self.assertEqual(config.read_text(), "unrelated: keep\n")
        self.assertEqual(os.stat(file).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(saved).st_mode & 0o777, 0o700)
        self.assertEqual(run.call_args.args[0][-3:], ["plugins", "enable", "si-notch"])

    def testCloneGetsDistinctIdentityUnlessUsageIsPending(self):
        self.settings("default", instanceId="shared", displayName="Main")
        clone = self.settings("coder", instanceId="shared", displayName="Coder")
        result, _ = self.invoke(apply=True)
        self.assertEqual(result[0]["unique_identities"], 2)
        self.assertNotEqual(json.loads(clone.read_text())["instanceId"], "shared")
        self.settings("coder", instanceId="shared", displayName="Coder")
        pending = clone.parent / "usage-outbox"
        pending.mkdir()
        (pending / "pending.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "pending usage"):
            self.invoke(apply=True)

    def testSharedSymlinkAndInvalidDisplayNameFailBeforeWriting(self):
        file = self.settings("default", instanceId="stable", displayName="bad\nlabel")
        with self.assertRaisesRegex(ValueError, "display name"):
            self.invoke(apply=True)
        file.unlink()
        file.symlink_to(self.executable)
        with self.assertRaisesRegex(ValueError, "symlinked"):
            self.invoke(apply=True)
        self.assertFalse(self.backup.exists())


if __name__ == "__main__":
    unittest.main()
