"""Exercise the rollout gate through its CLI with actual Kubernetes workload payloads."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check-workload-health.py'


def workload(ready=1, managed=False):
    return {'kind': 'Deployment', 'metadata': {'name': 'example', 'namespace': 'example',
            'uid': 'stable-uid', 'generation': 1,
            'labels': {'app.kubernetes.io/managed-by': 'infrastructure'} if managed else {}},
            'spec': {'replicas': 1}, 'status': {'readyReplicas': ready, 'observedGeneration': 1}}


class RollingWorkloadGateTest(unittest.TestCase):
    def run_gate(self, directory, obj, capture=False, infrastructure_only=False):
        tool = directory / 'kubectl'
        tool.write_text('#!/usr/bin/env python3\nimport os\nprint(os.environ["WORKLOADS"])\n')
        tool.chmod(0o700)
        return subprocess.run(['python3', str(SCRIPT), '--kubeconfig', 'unused', '--timeout', '0',
                               '--baseline', str(directory / 'baseline.json')] + (['--capture'] if capture else [])
                              + (['--infrastructure-health-only'] if infrastructure_only else []),
                              env={**os.environ, 'PATH': str(directory) + os.pathsep + os.environ['PATH'],
                                   'WORKLOADS': json.dumps({'items': [obj]})}, capture_output=True, text=True)

    def test_new_application_degradation_blocks_next_node(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            self.assertEqual(self.run_gate(d, workload(), True).returncode, 0)
            self.assertEqual((d / 'baseline.json').stat().st_mode & 0o777, 0o600)
            result = self.run_gate(d, workload(0))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('example/example', result.stderr)

    def test_existing_application_degradation_is_tolerated(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            self.assertEqual(self.run_gate(d, workload(0), True).returncode, 0)
            self.assertEqual(self.run_gate(d, workload(0)).returncode, 0)

    def test_existing_infrastructure_degradation_blocks_before_drain(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_gate(Path(tmp), workload(0, managed=True), True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('before any drain', result.stderr)

    def test_explicit_infrastructure_scope_does_not_block_on_new_application_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            self.assertEqual(self.run_gate(d, workload(), True, True).returncode, 0)
            self.assertEqual(self.run_gate(d, workload(0), infrastructure_only=True).returncode, 0)

    def test_infrastructure_scope_still_blocks_unhealthy_infrastructure(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_gate(Path(tmp), workload(0, managed=True), True, True)
            self.assertNotEqual(result.returncode, 0)

    def test_csi_addons_namespace_is_always_infrastructure(self):
        with tempfile.TemporaryDirectory() as tmp:
            obj = workload(0); obj['metadata']['namespace'] = 'csi-addons-system'
            self.assertNotEqual(self.run_gate(Path(tmp), obj, True, True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
