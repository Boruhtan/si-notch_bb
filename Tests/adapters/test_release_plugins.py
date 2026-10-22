"""Release producer and app reader must agree on plugin announcement bounds."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('release_manifest', Path(__file__).resolve().parents[2] / 'scripts/release-manifest.py')
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)

class PluginManifestTests(unittest.TestCase):
    def plugin(self, **changes):
        return dict(id='hermes', name='Hermes', version='1.10', change='updated',
                    installURL='https://github.com/owner/repo/tree/v1/plugins/hermes#native-hermes-installation', **changes)

    def test_legacy_and_new_metadata(self):
        manifest.validate_plugins([])
        manifest.validate_plugins([self.plugin()])
        item = self.plugin(); item.update(id='new-plugin', change='added')
        manifest.validate_plugins([self.plugin(), item])

    def test_reject_duplicate_ids_and_invalid_installation_pages(self):
        with self.assertRaises(ValueError): manifest.validate_plugins([self.plugin(), self.plugin()])
        for url in ('http://github.com/owner/repo', 'https://example.com/owner/repo',
                    'https://user@github.com/owner/repo', 'https://github.com:443/owner/repo',
                    'https://github.com/owner', 'https://github.com/owner/repo?redirect=x',
                    'https://github.com/owner/repo/%2e%2e/file'):
            item = self.plugin(); item['installURL'] = url
            with self.subTest(url=url), self.assertRaises(ValueError): manifest.validate_plugins([item])

    def test_manifest_bound_to_actual_plugin_version(self):
        import json
        root = Path(__file__).resolve().parents[2]
        config = json.loads((root / 'release.json').read_text())
        manifest.validate_plugins(config.get('pluginUpdates', []))
        for item in config.get('pluginUpdates', []):
            if item['id'] == 'hermes':
                self.assertIn('version: "' + item['version'] + '"', (root / 'plugins/hermes/plugin.yaml').read_text())
