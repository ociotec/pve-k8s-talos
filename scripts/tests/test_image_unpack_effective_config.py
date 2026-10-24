import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('durability',Path(__file__).resolve().parents[1]/'check-image-unpack-durability.py')
M=importlib.util.module_from_spec(spec);spec.loader.exec_module(M)

class EffectiveDurabilityTest(unittest.TestCase):
    def test_old_and_merged_import_layouts(self):
        self.assertEqual(M.imported_config('imports = ["/etc/cri/conf.d/*.part"]'),M.FRAGMENT)
        self.assertEqual(M.imported_config('imports = ["/etc/cri/conf.d/cri.toml"]'),M.MERGED)

    def test_unimported_file_does_not_prove_effective_configuration(self):
        with self.assertRaisesRegex(ValueError,'does not import'):M.imported_config('imports = []')

    def test_only_the_global_diff_service_switch_is_accepted(self):
        for quote in ('"',"'"):
            self.assertTrue(M.global_sync_enabled('[plugins.'+quote+'io.containerd.service.v1.diff-service'+quote+']\n  sync_fs = true\n'))
        self.assertFalse(M.global_sync_enabled('[plugins."io.containerd.cri.v1.images"]\n image_pull_with_sync_fs = true\n'))
        self.assertFalse(M.global_sync_enabled('[plugins."io.containerd.service.v1.diff-service"]\n sync_fs = false\n'))
        self.assertFalse(M.global_sync_enabled('[plugins."io.containerd.service.v1.diff-service"]\n[unrelated]\n sync_fs = true\n'))

if __name__=='__main__':unittest.main()
