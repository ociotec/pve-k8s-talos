"""Detect changed configuration consumed by both generations of Rook CSI."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1].joinpath('deploy.sh').read_text()
FUNCTION = re.search(r'^rook_external_csi_configuration_sha256\(\) \{\n.*?^\}', SOURCE, re.M | re.S)[0]


class ExternalCsiConfigTest(unittest.TestCase):
    def test_failed_hash_read_cannot_create_a_successful_retry_baseline(self):
        begin=re.search(r'^begin_external_csi_reconciliation\(\) \{\n.*?^\}',SOURCE,re.M|re.S)[0]
        harness='set -euo pipefail\nerror() { echo "$*" >&2; }\nrook_external_csi_configuration_sha256() { return 1; }\n'
        with tempfile.TemporaryDirectory() as directory:
            result=subprocess.run(['bash','-c',harness+begin+'\nvalue="$(begin_external_csi_reconciliation)"'],
                env={**os.environ,'cluster_git_dir':directory},capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('Cannot read the external CSI configuration',result.stderr)
            self.assertFalse(Path(directory,'pve-k8s-talos-csi-rollout-pending').exists())

    def test_interrupted_rollout_retries_refresh_after_configmaps_already_changed(self):
        begin = re.search(r'^begin_external_csi_reconciliation\(\) \{\n.*?^\}', SOURCE, re.M | re.S)[0]
        block = SOURCE.split('    external_csi_config_hash_after="$(rook_external_csi_configuration_sha256)"',1)[1]
        block = block.split('\n  fi\n  kubectl -n rook-ceph get storageclasses',1)[0]
        harness = '''set -euo pipefail
message() { :; }
error() { echo "$*" >&2; }
rook_external_csi_configuration_sha256() { printf '%s' "$LIVE_HASH"; }
kubernetes_resource_changed() { [[ "$1" != "$2" ]]; }
kubectl() { echo "$*" >> "$cluster_git_dir/actions"; }
wait_for_rollout_ready() { [[ "$FAIL_ROLLOUT" != true ]]; }
rook_csi_namespace=rook-ceph
rook_csi_workloads=(deploy/csi-rbdplugin-provisioner)
csi_addons_enabled=true
'''
        command = harness + begin + '\nexternal_csi_config_hash_before="$(begin_external_csi_reconciliation)"\nexternal_csi_config_hash_after="' + 'b'*64 + '"\n' + block
        with tempfile.TemporaryDirectory() as directory:
            env={**os.environ,'cluster_git_dir':directory,'LIVE_HASH':'a'*64,'FAIL_ROLLOUT':'true'}
            failed=subprocess.run(['bash','-c',command],env=env,capture_output=True,text=True)
            self.assertNotEqual(failed.returncode,0)
            marker=Path(directory,'pve-k8s-talos-csi-rollout-pending')
            self.assertEqual(marker.read_text().strip(),'a'*64)
            self.assertNotIn('csi-addons-controller-manager',Path(directory,'actions').read_text())
            env.update(LIVE_HASH='b'*64,FAIL_ROLLOUT='false')
            retried=subprocess.run(['bash','-c',command],env=env,capture_output=True,text=True)
            self.assertEqual(retried.returncode,0,retried.stderr)
            self.assertIn('csi-addons-controller-manager',Path(directory,'actions').read_text())
            self.assertFalse(marker.exists())

    def fingerprint(self, monitors):
        objects = {'items': [
            {'kind':'ConfigMap','metadata':{'name':'rook-ceph-csi-config'},
             'data':{'csi-cluster-config-json':'[]'}},
            {'kind':'ConfigMap','metadata':{'name':'ceph-csi-config'},
             'data':{'config.json':json.dumps([{'clusterID':'rook-ceph','monitors':monitors}])}},
        ]}
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory, 'objects.json'); fixture.write_text(json.dumps(objects))
            harness = 'set -euo pipefail\nkubectl() { if [[ "$*" == *"get namespace"* ]]; then return 0; fi; cat "$FIXTURE"; }\n'
            result = subprocess.run(['bash','-c',harness+FUNCTION+'\nrook_external_csi_configuration_sha256'],
                env={**os.environ,'FIXTURE':str(fixture)},capture_output=True,text=True,check=True)
            return result.stdout.strip()

    def test_modern_config_change_is_detected_when_legacy_config_stays_empty(self):
        self.assertNotEqual(self.fingerprint(['192.0.2.11:6789']),
                            self.fingerprint(['198.51.100.11:6789']))

    def test_unchanged_modern_configuration_is_stable(self):
        self.assertEqual(self.fingerprint(['192.0.2.11:6789']),
                         self.fingerprint(['192.0.2.11:6789']))


if __name__ == '__main__': unittest.main()
