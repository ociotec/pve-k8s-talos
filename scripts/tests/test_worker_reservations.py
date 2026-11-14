"""Verify calculated host budgets, Talos merge contracts and live rollout safety."""
import copy
import importlib.util
import io
import json
import os
from contextlib import redirect_stderr
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('worker_reservations', ROOT / 'scripts/worker-reservations.py')
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


def hcl(value):
    if isinstance(value, dict):
        return '{\n' + '\n'.join(json.dumps(k) + ' = ' + hcl(v) for k, v in value.items()) + '\n}'
    if isinstance(value, list):
        return '[' + ', '.join(hcl(v) for v in value) + ']'
    return json.dumps(value)


def evaluate(path, pods='250', memory=65536, cpu=32, **settings):
    inputs = {
        'constants': {'talos': {'version': 'v1.13.0', 'max_pods': pods, **settings}},
        'vms': {'worker': {'node_name': 'host', 'vm_id': 100, 'ip': '192.0.2.10', 'type': 'worker'},
                'cp': {'node_name': 'host', 'vm_id': 101, 'ip': '192.0.2.11', 'type': 'cp'}},
        'resources': {'worker': {'vcpus': cpu, 'memory': memory, 'k8s_node': 'worker', 'disks': []},
                      'cp': {'vcpus': 4, 'memory': 8192, 'k8s_node': 'controlplane', 'disks': []}},
    }
    for name, value in inputs.items():
        (path / f'{name}.auto.tfvars').write_text(f'{name} = {hcl(value)}\n')
    return M.evaluate(path)


class Calculation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)

    def test_reference_and_density(self):
        for pods, cpu, ram in [('110', 750, 1792), ('250', 1000, 2304), ('500', 1500, 3584)]:
            with self.subTest(pods=pods):
                report = evaluate(self.path, pods=pods)
                self.assertEqual(set(report['nodes']), {'worker'})
                node = report['nodes']['worker']
                self.assertEqual(node['system_cpu_m'] + node['kube_cpu_m'], cpu)
                self.assertEqual(node['system_memory_mib'] + node['kube_memory_mib'], ram)
                self.assertEqual(node['eviction_memory_mib'], 768)
        self.assertEqual(evaluate(self.path)['nodes']['worker']['allocatable_memory_mib'], 61 * 1024)

    def test_empty_pods_default_and_cpu_does_not_multiply_budgets(self):
        a = evaluate(self.path, pods='', cpu=4)['nodes']['worker']
        b = evaluate(self.path, pods='', cpu=64)['nodes']['worker']
        self.assertEqual(a['config'], b['config'])
        self.assertEqual(a['kube_cpu_m'], 500)

    def test_memory_floor_rounding_and_eviction_cap(self):
        for memory, system, eviction in [(8192, 512, 512), (51200, 512, 512),
                                          (51201, 768, 768), (131072, 1536, 1536),
                                          (262144, 2816, 2048)]:
            with self.subTest(memory=memory):
                node = evaluate(self.path, memory=memory)['nodes']['worker']
                self.assertEqual((node['system_memory_mib'], node['eviction_memory_mib']), (system, eviction))

    def test_overrides_and_canonical_quantities(self):
        node = evaluate(self.path, worker_system_reserved_cpu='1',
                        worker_system_reserved_memory_min='2Gi',
                        worker_kube_reserved_cpu_per_pod_millicores='3',
                        worker_kube_reserved_memory_per_pod_mib='7')['nodes']['worker']
        self.assertEqual(node['config']['systemReserved'], {'cpu': '1', 'memory': '2Gi'})
        self.assertEqual(node['config']['kubeReserved'], {'cpu': '1', 'memory': '2Gi'})

    def test_heterogeneous_workers_use_their_own_memory(self):
        evaluate(self.path)
        # Rewrite HCL inputs rather than evaluating a second sizing implementation.
        resources = {'small': {'vcpus': 4, 'memory': 8192, 'k8s_node': 'worker', 'disks': []},
                     'large': {'vcpus': 32, 'memory': 131072, 'k8s_node': 'worker', 'disks': []}}
        vms = {name: {'node_name': 'host', 'vm_id': 100 + i, 'ip': f'192.0.2.{10+i}', 'type': name}
               for i, name in enumerate(resources)}
        for key, value in [('resources', resources), ('vms', vms)]:
            (self.path / f'{key}.auto.tfvars').write_text(f'{key} = {hcl(value)}\n')
        nodes = M.evaluate(self.path)['nodes']
        self.assertEqual(nodes['small']['system_memory_mib'], 512)
        self.assertEqual(nodes['large']['system_memory_mib'], 1536)
        self.assertEqual(nodes['small']['kube_memory_mib'], nodes['large']['kube_memory_mib'])

    def test_invalid_settings_and_insufficient_workers_fail(self):
        for settings in [dict(pods='0'), dict(pods='250.5'), dict(pods='nan'),
                         dict(worker_system_reserved_cpu='NaN'), dict(worker_eviction_memory_percent='101'),
                         dict(worker_kube_reserved_memory_per_pod_mib='-1'),
                         dict(worker_system_reserved_memory_min='1GB'),
                         dict(worker_eviction_memory_min='3Gi'), dict(cpu=1), dict(memory=1024)]:
            with self.subTest(settings=settings), self.assertRaises(ValueError):
                evaluate(self.path, **settings)


class Rendering(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.report = evaluate(self.path)
        self.config = self.report['nodes']['worker']['config']

    def test_preserves_companion_defaults_and_custom_fields(self):
        merged = M.merged_config({'evictionSoft': {'memory.available': '1Gi'}}, self.config, 'v1.13.0')
        self.assertEqual(merged['systemReserved']['pid'], '100')
        self.assertEqual(merged['systemReserved']['ephemeral-storage'], '256Mi')
        self.assertEqual(merged['evictionHard']['imagefs.inodesFree'], '5%')
        self.assertEqual(merged['evictionSoft']['memory.available'], '1Gi')
        self.assertEqual(merged['enforceNodeAllocatable'], ['pods'])

    def test_custom_maps_keep_existing_suppressed_defaults(self):
        source = {'systemReserved': {'pid': '200'}, 'evictionHard': {'nodefs.available': '20%'}}
        merged = M.merged_config(source, self.config, 'v1.13.0')
        self.assertEqual(merged['systemReserved']['pid'], '200')
        self.assertNotIn('ephemeral-storage', merged['systemReserved'])
        self.assertEqual(merged['evictionHard']['nodefs.available'], '20%')
        self.assertEqual(merged['evictionHard']['imagefs.available'], '0%')

    def test_conflicting_fields_cgroups_and_unsupported_versions_fail(self):
        for source in [{'systemReserved': {'cpu': '1'}}, {'kubeReserved': {'memory': '4Gi'}},
                       {'evictionHard': {'memory.available': '4Gi'}},
                       {'enforceNodeAllocatable': ['none']}, {'reservedSystemCPUs': '0-1'}]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                M.merged_config(source, self.config, 'v1.13.0')
        with self.assertRaises(ValueError):
            M.merged_config({}, self.config, 'v1.15.0')

    def test_worker_only_and_native_compatibility_with_mounts(self):
        cp = self.path / 'machine-cp.yaml'
        cp.write_text('machine: {kubelet: {extraArgs: {max-pods: "250"}}}\n')
        worker = self.path / 'machine-worker.yaml'
        for mounts in [[], [{'source': '/var/mnt/data', 'destination': '/var/lib/data', 'type': 'bind', 'options': ['bind', 'rw']}]]:
            source = {'machine': {'kubelet': {'extraMounts': mounts, 'extraArgs': {'max-pods': '250'}}}}
            worker.write_text(yaml.safe_dump(source))
            M.prepare(self.report, self.path)
            legacy = worker.read_text()
            self.assertNotIn('systemReserved', cp.read_text())
            spec = importlib.util.spec_from_file_location('patch_format', ROOT / 'scripts/prepare-talos-patches.py')
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            docs = list(yaml.safe_load_all(module.render(legacy, 'factory.talos.dev/installer/example:v1.14.4', 'v1.36.5', 'worker')))
            self.assertEqual(M.kubelet_config(docs)[0]['kubeReserved']['memory'], '1536Mi')
            if mounts:
                self.assertEqual(docs[0]['machine']['kubelet']['extraMounts'], mounts)

    def test_api_configuration_wrappers_and_malformed_input(self):
        source = 'machine: {kubelet: {extraConfig: {}}}\n---\nkind: ResolverConfig\n'
        for wrapped in [source, yaml.safe_dump(source), json.dumps(source)]:
            self.assertEqual(len(M.decode_configuration(wrapped)), 2)
        with self.assertRaisesRegex(ValueError, 'privately'):
            M.decode_configuration('machine: [')

    def test_malformed_secret_bearing_patch_does_not_leak_in_console(self):
        (self.path / 'machine-worker.yaml').write_text('machine: [secret-sentinel\n')
        result = subprocess.run([os.sys.executable, str(ROOT / 'scripts/worker-reservations.py'),
                                 '--cluster-dir', str(self.path), '--prepare-patches', str(self.path)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Error:', result.stderr)
        self.assertNotIn('secret-sentinel', result.stdout + result.stderr)

    @unittest.skipUnless(os.environ.get('TALOS_CONFIG_VALIDATOR'), 'Set TALOS_CONFIG_VALIDATOR for official CLI validation')
    def test_reservation_patch_validates_with_official_talos_in_both_formats(self):
        binary = os.environ['TALOS_CONFIG_VALIDATOR']
        spec = importlib.util.spec_from_file_location('patch_format_validation', ROOT / 'scripts/prepare-talos-patches.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for version in ['v1.13.0', 'v1.14.4']:
            with self.subTest(version=version):
                base, output, patchfile = [self.path / n for n in ['base.yaml', 'merged.yaml', 'patch.yaml']]
                def command(*args):
                    result = subprocess.run([binary, *args], capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr)
                command('gen', 'config', 'example', 'https://192.0.2.1:6443', '--talos-version', version,
                        '--kubernetes-version', '1.36.0', '--with-docs=false', '--with-examples=false',
                        '--output-types', 'worker', '--output', str(base), '--force')
                source = yaml.safe_dump({'machine': {'install': {'disk': '/dev/sda'},
                                                    'kubelet': {'extraConfig': M.merged_config({}, self.config, version)}}})
                patchfile.write_text(module.render(source, 'factory.talos.dev/installer/example:v1.14.4', 'v1.36.0', 'worker') if version == 'v1.14.4' else source)
                command('machineconfig', 'patch', str(base), '--patch', '@' + str(patchfile), '--output', str(output))
                command('validate', '--config', str(output), '--mode', 'metal')
                effective = M.kubelet_config(M.decode_configuration(output.read_text()))[0]
                self.assertEqual(effective['kubeReserved'], {'cpu': '750m', 'memory': '1536Mi'})


class FakeLive:
    def __init__(self, report):
        self.report = report
        self.explicit = {}
        self.effective_config = M.merged_config({}, report['nodes']['worker']['config'], report['version'])
        self.pods = []
        self.node = {'metadata': {'name': 'worker'}, 'spec': {}, 'status': {
            'addresses': [{'type': 'InternalIP', 'address': '192.0.2.10'}],
            'capacity': {'cpu': '32', 'memory': '64Gi'},
            'allocatable': {'cpu': '31', 'memory': '61Gi'},
            'conditions': [{'type': 'Ready', 'status': 'True'}]}}

    def kubectl(self, *args, **kwargs):
        return json.dumps({'items': self.pods if args[1] == 'pods' else [self.node]})

    def active(self, address):
        return [{'machine': {'kubelet': {'extraConfig': self.explicit}}}]

    def effective(self, name):
        return self.effective_config



class LiveSafety(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.report = evaluate(self.path)
        self.client = FakeLive(self.report)

    def test_default_adoption_then_verification(self):
        self.assertIn('worker', M.check_live(self.report, self.client))
        M.verify_live(self.report, self.client)

    def test_active_conflicts_and_unowned_disk_changes_block(self):
        self.client.explicit = {'kubeReserved': {'cpu': '2'}}
        with self.assertRaisesRegex(ValueError, 'conflicting active'):
            M.check_live(self.report, self.client)
        self.client.explicit = {}
        self.client.effective_config['evictionHard']['nodefs.available'] = '20%'
        with self.assertRaisesRegex(ValueError, 'preserve active'):
            M.check_live(self.report, self.client)

    def test_previous_owned_values_can_change(self):
        self.client.explicit = copy.deepcopy(self.report['nodes']['worker']['config'])
        new = evaluate(self.path, pods='500')
        self.assertIn('worker', M.check_live(new, self.client, previous=self.report))
        with self.assertRaises(ValueError):
            M.check_live(new, self.client)

    def test_ready_pressure_and_allocatable_mismatches_fail(self):
        original = copy.deepcopy(self.client.node)
        for change in ['ready', 'pressure', 'allocatable']:
            self.client.node = copy.deepcopy(original)
            if change == 'ready':
                self.client.node['status']['conditions'][0]['status'] = 'False'
            elif change == 'pressure':
                self.client.node['status']['conditions'].append({'type': 'MemoryPressure', 'status': 'True'})
            else:
                self.client.node['status']['allocatable']['memory'] = '62Gi'
            with self.subTest(change=change), self.assertRaises(ValueError):
                M.verify_live(self.report, self.client)

    def test_request_warning_includes_sidecars_init_and_overhead(self):
        container = lambda cpu: {'resources': {'requests': {'cpu': cpu, 'memory': '1Gi'}}}
        self.client.pods = [{'spec': {'nodeName': 'worker', 'containers': [container('30')],
                                     'initContainers': [{**container('2'), 'restartPolicy': 'Always'}, container('1')],
                                     'overhead': {'cpu': '100m'}}, 'status': {'phase': 'Running'}}]
        self.assertEqual(M.pod_requests(self.client.pods[0], 'cpu'), M.Decimal('32.1'))
        output = io.StringIO()
        with redirect_stderr(output):
            M.check_live(self.report, self.client)
        self.assertIn('current pod cpu requests exceed', output.getvalue())

    def test_workload_regression_restarts_the_full_stability_window(self):
        clock = [0]
        samples = []
        renewals = []
        def sleep(seconds):
            clock[0] += seconds
        def health():
            samples.append(clock[0])
            if clock[0] == 10:
                raise ValueError('A workload became unhealthy')
        with patch.object(M.time, 'monotonic', side_effect=lambda: clock[0]), patch.object(M.time, 'sleep', side_effect=sleep):
            M.wait_verified(self.report, self.client, 'worker', health=health, renew=lambda: renewals.append(clock[0]))
        self.assertEqual(clock[0], 45)
        self.assertEqual(samples[-1], 45)
        self.assertEqual(renewals, [0])

    def test_failed_verification_times_out_without_releasing_the_gate(self):
        self.client.node['status']['allocatable']['memory'] = '62Gi'
        clock = [0]
        def sleep(seconds):
            clock[0] += seconds
        with patch.object(M.time, 'monotonic', side_effect=lambda: clock[0]), patch.object(M.time, 'sleep', side_effect=sleep):
            with self.assertRaisesRegex(ValueError, 'did not stabilize'):
                M.wait_verified(self.report, self.client, 'worker', timeout=10)
        self.assertEqual(clock[0], 10)

    def test_maintenance_renewal_failure_stops_immediately(self):
        def lost_ownership():
            raise ValueError('Lost maintenance ownership')
        with self.assertRaisesRegex(ValueError, 'ownership'):
            M.wait_verified(self.report, self.client, 'worker', renew=lost_ownership)


if __name__ == '__main__':
    unittest.main()
