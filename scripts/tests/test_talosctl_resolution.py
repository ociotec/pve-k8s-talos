import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

PATH=Path(__file__).resolve().parents[1]/'resolve-talosctl.py'
spec=importlib.util.spec_from_file_location('cli_resolution',PATH);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class CliResolutionTest(unittest.TestCase):
    def payload(self, version):return f'#!/bin/sh\nprintf "Client:\\n\\tTag:         {version}\\n"\n'.encode()
    def downloads(self, data, digest=None):
        checksum=digest or hashlib.sha256(data).hexdigest()
        def fetch(url):return io.BytesIO((checksum+'  talosctl-linux-amd64\n').encode() if url.endswith('sha256sum.txt') else data)
        return fetch

    def test_matching_old_release_uses_existing_cli_without_download(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary=Path(tmp)/'talosctl';binary.write_bytes(self.payload('v1.10.4'));binary.chmod(0o700)
            with patch.object(module.shutil,'which',return_value=str(binary)),patch.object(module,'fetch',side_effect=AssertionError('must not download')):
                self.assertEqual(module.resolve('v1.10.4',Path(tmp)/'cache'),str(binary))

    def test_matching_symlink_preserves_the_talosctl_path_entry(self):
        with tempfile.TemporaryDirectory() as tmp:
            target=Path(tmp)/'versioned-client';target.write_bytes(self.payload('v1.13.2'));target.chmod(0o700)
            entry=Path(tmp)/'bin'/'talosctl';entry.parent.mkdir();entry.symlink_to(target)
            with patch.object(module.shutil,'which',return_value=str(entry)),patch.object(module,'fetch',side_effect=AssertionError('must not download')):
                self.assertEqual(module.resolve('v1.13.2',Path(tmp)/'cache'),str(entry))

    def test_different_installed_release_resolves_exact_version_and_reuses_cache(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(module.shutil,'which',return_value=None),patch.object(module.platform,'system',return_value='Linux'),patch.object(module.platform,'machine',return_value='x86_64'):
            with patch.object(module,'fetch',side_effect=self.downloads(self.payload('v1.14.4'))):
                binary=module.resolve('v1.14.4',tmp)
            self.assertEqual(module.client_version(binary),'v1.14.4')
            with patch.object(module,'fetch',side_effect=AssertionError('must use verified cache')):
                self.assertEqual(module.resolve('v1.14.4',tmp),binary)

    def test_bad_checksum_never_executes_or_publishes_asset(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(module.shutil,'which',return_value=None),patch.object(module.platform,'system',return_value='Linux'),patch.object(module.platform,'machine',return_value='x86_64'),patch.object(module,'fetch',side_effect=self.downloads(b'not an executable',digest='0'*64)),patch.object(module,'client_version',side_effect=AssertionError('must not execute unchecked bytes')):
            with self.assertRaisesRegex(ValueError,'checksum mismatch'):module.resolve('v1.14.4',tmp)
            self.assertFalse(list(Path(tmp).rglob('talosctl')))

    def test_path_traversal_version_is_rejected(self):
        with self.assertRaises(ValueError):module.resolve('../../other','unused')

if __name__=='__main__':unittest.main()
