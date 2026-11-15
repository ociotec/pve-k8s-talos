"""Exercise production sizing and scheduler fit without changing infrastructure."""
import importlib.util
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('headroom', ROOT / 'scripts/worker-headroom.py')
HEADROOM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HEADROOM)


def node(name='worker', cpu='31', memory='63963136Ki', control_plane=False):
    return {'metadata': {'name': name, 'labels': {'node-role.kubernetes.io/control-plane': ''} if control_plane else {}},
            'status': {'allocatable': {'cpu': cpu, 'memory': memory, 'pods': '250'}}}


class SizingTest(unittest.TestCase):
    def sizing(self, settings=None, nodes=None):
        source = (ROOT / 'k8s-net/worker-headroom.tf').read_text().split('data "kubernetes_resources"', 1)[0]
        source = source.replace('data.kubernetes_resources.worker_headroom_nodes[0].objects', 'var.test_nodes')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'main.tf').write_text(source + '\nvariable "test_nodes" { type = any }\n')
            (path / 'inputs.auto.tfvars.json').write_text(json.dumps({'constants': {'k8s': settings or {}}, 'test_nodes': nodes or [node()]}))
            r = subprocess.run(['tofu', '-chdir=' + directory, 'console', '-no-color'],
                input='jsonencode({enabled=local.worker_headroom_enabled, nodes=local.worker_headroom_budgets})\n',
                capture_output=True, text=True, check=True)
            return json.loads(json.loads(r.stdout))

    def test_absent_settings_keep_residual_resources(self):
        result = self.sizing()
        self.assertTrue(result['enabled'])
        budget = result['nodes']['worker']
        self.assertEqual((budget['cpu_request_m'], budget['cpu_limit_m'], budget['memory_mib']), (1, 10, 8))

    def test_percentages_are_independent_and_round_up(self):
        values = self.sizing({'headroom_cpu_percent': 10, 'headroom_memory_percent': 20})['nodes']['worker']
        self.assertEqual(values['cpu_request_m'], 3100)
        self.assertGreater(values['cpu_limit_m'], values['cpu_request_m'])
        self.assertEqual(values['memory_mib'], 12493)
        only_memory = self.sizing({'headroom_memory_percent': 20})['nodes']['worker']
        self.assertEqual(only_memory['cpu_request_m'], 1)
        self.assertEqual(only_memory['memory_mib'], values['memory_mib'])

    def test_small_percentages_keep_minimums(self):
        budget = self.sizing({'headroom_cpu_percent': .01, 'headroom_memory_percent': .01},
                             [node(cpu='500m', memory='256Mi')])['nodes']['worker']
        self.assertEqual((budget['cpu_request_m'], budget['cpu_limit_m'], budget['memory_mib']), (1, 10, 8))

    def test_heterogeneous_workers_and_control_plane_exclusion(self):
        result = self.sizing({'headroom_cpu_percent': 10, 'headroom_memory_percent': 20},
            [node('small', '3500m', '4Gi'), node('large', '31', '64Gi'), node('cp', control_plane=True)])
        self.assertEqual(set(result['nodes']), {'small', 'large'})
        self.assertEqual(result['nodes']['small']['cpu_request_m'], 350)
        self.assertEqual(result['nodes']['large']['memory_mib'], 13108)
        self.assertNotEqual(result['nodes']['small']['daemonset'], result['nodes']['large']['daemonset'])

    def test_explicit_disable_removes_all_reservations(self):
        self.assertEqual(self.sizing({'headroom_enabled': False})['nodes'], {})


class FitAndCoverageTest(unittest.TestCase):
    def pod(self, priority=0, memory='100Mi', cpu='100m'):
        return {'metadata': {'name': 'application', 'namespace': 'example'}, 'spec': {'nodeName': 'worker', 'priority': priority,
                'containers': [{'resources': {'requests': {'cpu': cpu, 'memory': memory}}}]}, 'status': {'phase': 'Running'}}

    def test_lower_priority_deficit_is_reported_and_does_not_block(self):
        config = {'nodes': {'worker': {'cpu_request_m': 100, 'memory_mib': 128}}}
        report = HEADROOM.fit_report(config, {'worker': node(cpu='1', memory='256Mi')}, [self.pod(memory='200Mi')], 700000)
        self.assertIn('72.00Mi RAM', report[0])
        self.assertIn('1 lower-priority', report[0])

    def test_protected_deficit_blocks_before_apply(self):
        config = {'nodes': {'worker': {'cpu_request_m': 100, 'memory_mib': 128}}}
        with self.assertRaisesRegex(RuntimeError, 'equal/higher-priority memory'):
            HEADROOM.fit_report(config, {'worker': node(cpu='1', memory='256Mi')}, [self.pod(700000, '200Mi')], 700000)

    def test_scheduler_sidecar_overhead_accounting_is_reused(self):
        pod = self.pod()
        pod['spec']['initContainers'] = [
            {'restartPolicy': 'Always', 'resources': {'requests': {'memory': '50Mi'}}},
            {'resources': {'requests': {'memory': '200Mi'}}}]
        pod['spec']['overhead'] = {'memory': '10Mi'}
        self.assertEqual(HEADROOM.pod_requests(pod, 'memory'), 260 * 1048576)

    def test_guaranteed_qos_is_rejected_even_with_matching_requests(self):
        budget = {'cpu_request_m': 1000, 'cpu_limit_m': 1001, 'memory_mib': 8}
        p = self.pod(700000)
        p['metadata']['labels'] = {'app.kubernetes.io/part-of': 'worker-headroom'}
        p['spec']['preemptionPolicy'] = 'PreemptLowerPriority'
        p['spec']['containers'][0]['resources'] = {
            'requests': {'cpu': '1', 'memory': '8Mi'}, 'limits': {'cpu': '1001m', 'memory': '8Mi'}}
        p['status'].update(conditions=[{'type': 'Ready', 'status': 'True'}], qosClass='Burstable')
        self.assertEqual(HEADROOM.pending_coverage({'nodes': {'worker': budget}}, [p], 700000), [])
        p['status']['qosClass'] = 'Guaranteed'
        self.assertTrue(HEADROOM.pending_coverage({'nodes': {'worker': budget}}, [p], 700000))

    def test_pending_or_duplicate_reservations_do_not_pass_coverage(self):
        config = {'nodes': {'worker': {'cpu_request_m': 1, 'cpu_limit_m': 10, 'memory_mib': 8}}}
        self.assertTrue(HEADROOM.pending_coverage(config, [], 700000))
        p = self.pod(700000)
        p['metadata']['labels'] = {'app.kubernetes.io/part-of': 'worker-headroom'}
        self.assertTrue(HEADROOM.pending_coverage(config, [p, p], 700000))


class DeploymentGateTest(unittest.TestCase):
    def test_failed_preflight_never_applies_the_saved_plan(self):
        self.check_gate(True)

    def test_successful_preflight_applies_the_exact_saved_plan_before_verification(self):
        self.check_gate(False)

    def check_gate(self, fail):
        source = (ROOT / 'scripts/deploy.sh').read_text()
        block = source[source.index('  headroom_plan="$(mktemp '):source.index('  validate_node_remediation_dedicated_proxmox_access', source.index('  headroom_plan="$(mktemp '))]
        with tempfile.TemporaryDirectory() as directory:
            harness = '\n'.join([
                'set -euo pipefail',
                'cluster_git_dir="$TEST_DIR"',
                'cluster_k8s_net_workspace=workspace',
                'cluster_kubeconfig_path=kubeconfig',
                'script_dir=scripts',
                'skip_ceph=true',
                'cluster_name=example',
                'node_remediation_pool=example',
                'run() { printf "%s\\n" "$*" >> "$TEST_DIR/events"; }',
                'python3() { printf "%s\\n" "$*" >> "$TEST_DIR/events"; if [[ "$*" == *preflight* && "$FAIL" == true ]]; then return 1; fi; }',
            ])
            result = subprocess.run(['bash', '-c', harness + '\n' + block],
                env={**os.environ, 'TEST_DIR': directory, 'FAIL': str(fail).lower()}, capture_output=True, text=True)
            events = (Path(directory) / 'events').read_text().splitlines()
            if fail:
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(' apply ' in e for e in events))
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(events), 4)
                plan = re.search(r'-out=(\S+)', events[0])[1]
                self.assertIn('--plan ' + plan, events[1])
                self.assertTrue(events[2].endswith(plan))
                self.assertIn(' verify ', events[3])


if __name__ == '__main__':
    unittest.main()
