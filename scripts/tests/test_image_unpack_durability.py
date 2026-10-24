"""Evaluate actual HCL defaults/compatibility and merge patches with the locked Talos provider."""
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
SOURCE=(ROOT/'templates/machine-config-locals.template.tf').read_text()
LOCALS=SOURCE[:SOURCE.index('  controlplane_machine_config =')]+'}\n'

@unittest.skipUnless(shutil.which('tofu'),'OpenTofu is required')
class DurabilityCompatibilityTest(unittest.TestCase):
    def evaluate(self,version,enabled=None):
        constants={'talos':{'version':version}}
        if enabled is not None:constants['talos']['image_unpack_sync_fs']=enabled
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp,'main.tf').write_text('variable "constants" { default = '+json.dumps(constants)+' }\n'+LOCALS)
            subprocess.run(['tofu','init','-backend=false','-input=false','-no-color'],cwd=tmp,check=True,capture_output=True,text=True)
            r=subprocess.run(['tofu','console','-no-color'],input='jsonencode({enabled=local.image_unpack_sync_fs,supported=local.image_unpack_sync_fs_supported,patch=local.image_unpack_sync_fs_patch})\n',cwd=tmp,check=True,capture_output=True,text=True)
            return json.loads(json.loads(r.stdout))

    def test_omitted_setting_keeps_old_and_new_clusters_unchanged(self):
        for version in ('v1.8.4','v1.10.5','v1.13.2','v1.14.4'):
            with self.subTest(version=version):self.assertEqual(self.evaluate(version)['patch'],'')

    def test_supported_legacy_and_modern_versions_use_the_supported_customization_path(self):
        for version in ('v1.10.5','v1.13.2','v1.14.4'):
            with self.subTest(version=version):
                result=self.evaluate(version,'true');self.assertTrue(result['supported'])
                self.assertIn('20-customization.part',result['patch']);self.assertIn('sync_fs = true',result['patch'])
                self.assertNotIn('CRICustomizationConfig',result['patch'])

    def test_older_unsupported_opt_in_is_identified(self):self.assertFalse(self.evaluate('v1.8.4',True)['supported'])

    def test_pinned_provider_preserves_other_machine_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory=Path(tmp)
            (directory/'patches').mkdir()
            (directory/'patches/machine-fixture.yaml').write_text('machine: {}\n')
            shutil.copy(ROOT/'.terraform.lock.hcl',directory/'.terraform.lock.hcl')
            config='''terraform {
  required_providers {
    talos = { source = "siderolabs/talos", version = "__LOCKED_TALOS_VERSION__" }
  }
}
variable "constants" { default = {talos={version="v1.14.4",image_unpack_sync_fs="true"}} }
'''+LOCALS+'''
resource "talos_machine_secrets" "test" {}
data "talos_machine_configuration" "test" {
  cluster_name="test"
  cluster_endpoint="https://192.0.2.1:6443"
  machine_type="worker"
  kubernetes_version="v1.32.0"
  machine_secrets=talos_machine_secrets.test.machine_secrets
  config_patches=[local.image_unpack_sync_fs_patch,jsonencode({machine={files=[{path="/etc/example-existing",op="overwrite",content="preserve"}]}})]
}
output "files" {
  value=yamldecode(split("\\n---\\n",data.talos_machine_configuration.test.machine_configuration)[0]).machine.files
  sensitive=true
}
'''
            version=re.search(r'provider "[^"]*siderolabs/talos" \{\s*version\s*=\s*"([^"]+)"',(ROOT/'.terraform.lock.hcl').read_text())[1]
            guard=(ROOT/'templates/controlplane-data.template.tf').read_text().split('  lifecycle {',1)[1].split('  cluster_name',1)[0]
            guard=guard.replace('__NAME__','fixture')
            config=config.replace('data \"talos_machine_configuration\" \"test\" {','data \"talos_machine_configuration\" \"test\" {\n  lifecycle {'+guard)
            config=config.replace('__LOCKED_TALOS_VERSION__',version)
            (directory/'main.tf').write_text(config)
            env=dict(os.environ)
            # An optional caller-provided provider cache also works in clean CI.
            if 'TF_PLUGIN_CACHE_DIR' not in env and (ROOT/'.terraform/providers').is_dir():env['TF_PLUGIN_CACHE_DIR']=str(ROOT/'.terraform/providers')
            subprocess.run(['tofu','init','-backend=false','-input=false','-no-color'],cwd=tmp,env=env,check=True,capture_output=True,text=True)
            applied=subprocess.run(['tofu','apply','-auto-approve','-input=false','-no-color'],cwd=tmp,env=env,capture_output=True,text=True)
            if applied.returncode:
                raise AssertionError(applied.stderr)

            r=subprocess.run(['tofu','output','-json','files'],cwd=tmp,env=env,check=True,capture_output=True,text=True)
            files={f['path']:f for f in json.loads(r.stdout)}
            self.assertEqual(files['/etc/example-existing']['content'],'preserve')
            durable=files['/etc/cri/conf.d/20-customization.part']
            self.assertIn('sync_fs = true',durable['content'])
            self.assertEqual(durable['op'],'create')
            self.assertEqual(durable['permissions'],384)
            # A user customization must never be overwritten by the opt-in.
            (directory/'patches/machine-fixture.yaml').write_text('machine:\n  files:\n    - path: /etc/cri/conf.d/20-customization.part\n      op: create\n      content: preserve\n')
            conflict=subprocess.run(['tofu','plan','-input=false','-no-color'],cwd=tmp,env=env,capture_output=True,text=True)
            self.assertNotEqual(conflict.returncode,0)
            self.assertIn('cannot replace an existing CRI customization',conflict.stdout+conflict.stderr)


if __name__=='__main__':unittest.main()
