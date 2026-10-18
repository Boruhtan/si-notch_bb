import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("hermes_configure", ROOT / "plugins/hermes/configure.py")
configure = importlib.util.module_from_spec(spec); spec.loader.exec_module(configure)


class ConfigureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.plugin = self.root / "plugin"; self.plugin.mkdir(mode=0o700)
        (self.plugin / 'relay.py').write_bytes((ROOT / 'plugins/hermes/relay.py').read_bytes())
        self.endpoint = self.root / "run/events.sock"
        patcher = mock.patch.object(configure, "PLUGIN", self.plugin)
        patcher.start(); self.addCleanup(patcher.stop)
        patcher = mock.patch.dict(os.environ, {}, clear=True)
        patcher.start(); self.addCleanup(patcher.stop)

    def call(self, *args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output): code = configure.main(list(args))
        return code, json.loads(output.getvalue())

    def setup_plugin(self):
        return self.call('setup', '--name', 'Remote test', '--socket', str(self.endpoint))

    def test_setup_is_idempotent_and_preserves_extras_with_exact_backup(self):
        self.root.chmod(0o755)  # Ordinary non-private home ancestor is supported.
        code, first = self.setup_plugin(); self.assertEqual(code, 0)
        config_path = self.plugin / 'si-notch.json'
        original = json.loads(config_path.read_text())
        self.assertFalse(original['showSessionText'])
        self.assertEqual(self.endpoint.parent.stat().st_mode & 0o777, 0o700)
        original.update(extra={'keep': True}, helperPath='/explicit/helper')
        config_path.write_text(json.dumps(original)); before = config_path.read_bytes()
        code, change = self.call('setup','--name','Renamed','--socket',str(self.endpoint),'--show-text')
        actual = json.loads(config_path.read_text())
        self.assertEqual(actual['extra'], {'keep':True})
        self.assertEqual(actual['helperPath'], '/explicit/helper')
        self.assertEqual(actual['instanceId'], original['instanceId'])
        self.assertEqual(Path(change['backup']).read_bytes(), before)
        self.assertTrue(actual['showSessionText'])
        code, repeat = self.call('setup','--name','Renamed','--socket',str(self.endpoint))
        self.assertEqual(code, 0); self.assertFalse(repeat['changed'])
        self.assertEqual(config_path.stat().st_mode & 0o777, 0o600)

    def test_invalid_paths_symlink_and_loose_directory_are_not_mutated(self):
        for endpoint in ['relative', '/private/tmp/../events.sock', '/tmp/a:b', '/tmp/bad\npath']:
            code, _ = self.call('setup','--name','Test','--socket',endpoint)
            self.assertEqual(code,1)
        self.assertFalse((self.plugin/'si-notch.json').exists())
        self.endpoint.parent.mkdir(mode=0o755)
        code, _ = self.setup_plugin(); self.assertEqual(code,1)
        self.assertEqual(self.endpoint.parent.stat().st_mode & 0o777,0o755)
        (self.plugin/'si-notch.json').symlink_to(self.root/'absent')
        code, _ = self.setup_plugin(); self.assertEqual(code,1)

    def test_check_missing_socket_is_read_only_and_explains_connect(self):
        before = set(self.root.rglob('*'))
        code, result = self.call('check','--socket',str(self.endpoint))
        self.assertEqual(code,1); self.assertEqual(result['state'],'not_connected')
        self.assertEqual(set(self.root.rglob('*')),before)

    def test_presence_check_uses_bundled_python_relay_without_executable_bit(self):
        self.setup_plugin()
        server = socket.socket(socket.AF_UNIX); server.bind(str(self.endpoint)); self.endpoint.chmod(0o600); server.listen(2)
        self.addCleanup(server.close)
        seen=[]
        def serve():
            # First connection probes reachability without sending an event.
            probe,_=server.accept(); probe.close()
            connection,_=server.accept()
            with connection:
                value=b''
                while b'\n' not in value:value+=connection.recv(8192)
                seen.append(json.loads(value));connection.sendall(b'{"ok":true}\n')
        thread=threading.Thread(target=serve,daemon=True);thread.start()
        code, result = self.call('check'); thread.join(3)
        self.assertEqual(code,0); self.assertEqual(result['state'],'delivered')
        self.assertEqual(seen[0]['event'],'agent.presence')
        self.assertFalse((self.plugin/'relay.py').stat().st_mode & 0o111)
        self.assertNotIn('message', seen[0])

    def test_repair_requires_explicit_apply_and_keeps_the_stale_socket(self):
        self.setup_plugin()
        server=socket.socket(socket.AF_UNIX);server.bind(str(self.endpoint));server.close();self.endpoint.chmod(0o600)
        unused=subprocess.CompletedProcess([],1,stdout=b'',stderr=b'')
        with mock.patch.object(configure.shutil,'which',return_value='/fixture/lsof'), \
             mock.patch.object(configure.subprocess,'run',return_value=unused):
            code, preview=self.call('repair-socket')
            self.assertEqual(code,0);self.assertEqual(preview['state'],'repair_preview');self.assertTrue(self.endpoint.exists())
            code, result=self.call('repair-socket','--apply')
            self.assertEqual(code,0);self.assertTrue(Path(result['backup']).is_socket());self.assertFalse(self.endpoint.exists())

    def test_repair_refuses_a_live_or_held_socket(self):
        self.setup_plugin()
        server=socket.socket(socket.AF_UNIX);server.bind(str(self.endpoint));self.endpoint.chmod(0o600);server.listen(1)
        code,result=self.call('repair-socket','--apply');self.assertEqual(code,1);self.assertTrue(self.endpoint.exists())
        server.close()
        with mock.patch.object(configure.shutil,'which',return_value='/fixture/lsof'), \
             mock.patch.object(configure.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout=b'p123',stderr=b'')):
            code,_=self.call('repair-socket','--apply');self.assertEqual(code,1);self.assertTrue(self.endpoint.exists())


if __name__=='__main__':unittest.main()
