import importlib.util
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[2] / "scripts/remote-socket-recovery.py"
spec = importlib.util.spec_from_file_location("remote_socket_recovery", SOURCE)
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class RemoteSocketRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="notch-recovery-", dir="/private/tmp")
        self.path = Path(self.directory.name) / "events.sock"

    def tearDown(self):
        self.directory.cleanup()

    def bind(self, listen=False):
        connection = socket.socket(socket.AF_UNIX)
        connection.bind(str(self.path))
        os.chmod(self.path, 0o600)
        if listen:
            connection.listen(2)
        return connection

    def test_absent_socket_needs_no_change(self):
        self.assertEqual(recovery.recover(str(self.path)), {"state": "absent"})

    def test_stale_socket_is_preserved_and_rebind_succeeds_repeatedly(self):
        for _ in range(2):
            connection = self.bind()
            connection.close()
            inode = self.path.stat().st_ino
            result = recovery.recover(str(self.path))
            self.assertEqual(result["state"], "preserved")
            self.assertFalse(self.path.exists())
            self.assertEqual(Path(result["backup"]).stat().st_ino, inode)

    def test_listening_socket_is_untouched(self):
        with self.bind(listen=True):
            inode = self.path.stat().st_ino
            with self.assertRaisesRegex(ValueError, "active"):
                recovery.recover(str(self.path))
            self.assertEqual(self.path.stat().st_ino, inode)

    def test_bound_non_listening_socket_is_not_moved(self):
        with self.bind():
            with self.assertRaisesRegex(ValueError, "held"):
                recovery.recover(str(self.path))
            self.assertTrue(self.path.exists())

    def test_unsafe_paths_and_permissions_are_untouched(self):
        self.path.write_text("not a socket")
        with self.assertRaises(ValueError):
            recovery.recover(str(self.path))
        self.path.unlink()
        self.path.symlink_to("missing")
        with self.assertRaises(ValueError):
            recovery.recover(str(self.path))
        self.path.unlink()
        self.bind().close()
        os.chmod(self.path, 0o666)
        with self.assertRaises(ValueError):
            recovery.recover(str(self.path))
        os.chmod(self.path, 0o600)
        os.chmod(self.path.parent, 0o755)
        with self.assertRaises(ValueError):
            recovery.recover(str(self.path))

    def test_missing_lsof_and_changed_inode_prevent_recovery(self):
        self.bind().close()
        with patch.object(recovery.shutil, "which", return_value=None):
            with self.assertRaisesRegex(ValueError, "lsof"):
                recovery.recover(str(self.path))
        def replace_socket(*args, **kwargs):
            self.path.rename(self.path.with_name("original.sock"))
            self.bind().close()
            return subprocess.CompletedProcess(args[0], 1, b"", b"")
        with patch.object(recovery.subprocess, "run", side_effect=replace_socket):
            with self.assertRaisesRegex(ValueError, "changed"):
                recovery.recover(str(self.path))
        self.assertTrue(self.path.exists())
