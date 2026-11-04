"""Exercise the production sizing model and pre-apply gate without infrastructure."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import yaml

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('cp_sizing', ROOT / 'scripts/control-plane-sizing.py')
SIZING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIZING)


def hcl(value):
    if isinstance(value, dict):
        return '{\n' + '\n'.join(json.dumps(k) + ' = ' + hcl(v) for k, v in value.items()) + '\n}'
    if isinstance(value, list):
        return '[' + ', '.join(hcl(v) for v in value) + ']'
    return json.dumps(value)


def fleet(workers=3, cp_count=3, cp_cpu=4, cp_memory=8192, worker_cpu=4, worker_memory=8192):
    resources = {
        'cp': {'vcpus': cp_cpu, 'memory': cp_memory, 'k8s_node': 'controlplane', 'disks': []},
        'wk': {'vcpus': worker_cpu, 'memory': worker_memory, 'k8s_node': 'worker', 'disks': []},
    }
    vms = {f'cp-{i}': {'node_name': 'host', 'vm_id': 100+i, 'ip': f'192.0.2.{i+1}', 'type': 'cp'} for i in range(cp_count)}
    vms.update({f'wk-{i}': {'node_name': 'host', 'vm_id': 200+i, 'ip': f'198.51.100.{i+1}', 'type': 'wk'} for i in range(workers)})
    return {'constants': {'talos': {}}, 'vms': vms, 'resources': resources}


@unittest.skipUnless(shutil.which('tofu'), 'OpenTofu is required')
class ControlPlaneSizingTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.cluster = Path(self.temporary.name)

    def write(self, values):
        for name, value in values.items():
            (self.cluster / f'{name}.auto.tfvars').write_text(f'{name} = {hcl(value)}\n')

    def evaluate(self, values):
        self.write(values)
        return SIZING.evaluate(self.cluster)

    def cli(self, *args):
        return subprocess.run(['python3', str(ROOT / 'scripts/control-plane-sizing.py'),
                               '--cluster-dir', str(self.cluster), *args], capture_output=True, text=True)

    def test_minimum_has_no_percentage_margin_and_upper_threshold_is_rounded(self):
        report = self.evaluate(fleet())
        self.assertEqual(report['required'], {'cpu_m': 3000, 'memory_mib': 7168})
        self.assertEqual(report['recommended'], {'cpu_m': 4000, 'memory_mib': 9216})
        self.assertEqual(report['totals'], {
            'components': {'cpu_m': 1750, 'memory_mib': 4608},
            'services': {'cpu_m': 1250, 'memory_mib': 2048},
            'combined': {'cpu_m': 3000, 'memory_mib': 6656}})
        self.assertEqual(report['components']['api_server'], {'cpu': '1', 'memory': '3Gi'})
        self.assertEqual(set(report['budgets']), {'etcd', 'system', 'node_agents'})
        self.assertTrue(report['fits'])
        self.assertTrue(all(not n['oversized'] for n in report['nodes'].values()))

    def test_zero_workers_uses_baseline_and_unused_profiles_do_not_count(self):
        values = fleet(workers=0)
        values['resources']['unused'] = {'vcpus': 1000, 'memory': 1024000, 'k8s_node': 'worker', 'disks': []}
        report = self.evaluate(values)
        self.assertEqual(report['workers']['count'], 0)
        self.assertEqual(report['workers']['vcpu'], 0)
        self.assertEqual(report['capacity_factor'], 1)

    def test_worker_count_and_capacity_independently_increase_sizing(self):
        for values in [fleet(workers=20), fleet(workers=1, worker_cpu=656, worker_memory=840*1024)]:
            with self.subTest(workers=len(values['vms'])):
                report = self.evaluate(values)
                self.assertEqual(report['capacity_factor'], 2)
                self.assertEqual(report['components']['api_server'], {'cpu': '2', 'memory': '6Gi'})
                self.assertFalse(report['fits'])

    def test_limiting_worker_resource_determines_workload_capacity(self):
        for cpu, memory in [(656, 420*1024), (328, 840*1024)]:
            report = self.evaluate(fleet(workers=1, worker_cpu=cpu, worker_memory=memory))
            self.assertEqual(report['capacity_factor'], 1)

    def test_pod_density_increases_sizing(self):
        values = fleet(workers=10)
        values['constants']['talos']['max_pods'] = '220'
        self.assertEqual(self.evaluate(values)['capacity_factor'], 2)

    def test_more_cp_replicas_do_not_reduce_per_member_needs(self):
        self.assertEqual(self.evaluate(fleet())['required'], self.evaluate(fleet(cp_count=5))['required'])

    def test_heterogeneous_cps_are_checked_individually(self):
        values = fleet()
        values['resources']['small'] = {**values['resources']['cp'], 'vcpus': 2, 'memory': 2048}
        values['vms']['cp-1']['type'] = 'small'
        report = self.evaluate(values)
        self.assertTrue(report['nodes']['cp-0']['fits'])
        self.assertEqual(report['nodes']['cp-1']['cpu_deficit_m'], 1000)
        self.assertEqual(report['nodes']['cp-1']['memory_deficit_mib'], 5120)
        self.assertFalse(report['fits'])

    def test_exact_fit_passes_and_cpu_or_memory_shortfall_fails(self):
        self.assertTrue(self.evaluate(fleet(cp_cpu=3, cp_memory=7168))['fits'])
        for cpu, memory in [(2, 8192), (3, 7167)]:
            self.assertFalse(self.evaluate(fleet(cp_cpu=cpu, cp_memory=memory))['fits'])

    def test_vm_thresholds_always_round_up_to_whole_vcpu_and_gib(self):
        values = fleet()
        values['constants']['talos'].update(api_server_cpu='1100m', api_server_memory='3136Mi')
        report = self.evaluate(values)
        self.assertEqual(report['totals']['combined'], {'cpu_m': 3100, 'memory_mib': 6720})
        self.assertEqual(report['required'], {'cpu_m': 4000, 'memory_mib': 7168})
        self.assertEqual(report['recommended'], {'cpu_m': 4000, 'memory_mib': 9216})

    def test_headroom_changes_only_the_upper_threshold(self):
        for margin, cpu, memory in [('0', 3000, 7168), ('10', 4000, 8192), ('20', 4000, 9216), ('40', 5000, 11264)]:
            values = fleet()
            values['constants']['talos']['control_plane_recommended_headroom_percent'] = margin
            report = self.evaluate(values)
            self.assertEqual(report['required'], {'cpu_m': 3000, 'memory_mib': 7168})
            self.assertEqual(report['recommended'], {'cpu_m': cpu, 'memory_mib': memory})

    def test_at_or_between_thresholds_passes_without_warnings(self):
        for cpu, memory in [(3, 7168), (4, 8192), (4, 9216)]:
            self.write(fleet(cp_cpu=cpu, cp_memory=memory))
            result = self.cli()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('WARNING:', result.stderr)
            self.assertIn('Minimum VM: 3 vCPU / 7Gi; no percentage headroom.', result.stdout)
            self.assertIn('Recommended upper VM size: 4 vCPU / 9Gi', result.stdout)

    def test_cpu_or_memory_oversizing_warns_without_force_and_continues(self):
        for cpu, memory in [(5, 8192), (4, 10240)]:
            self.write(fleet(cp_cpu=cpu, cp_memory=memory))
            result = self.cli('--check', '--format', 'json')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('WARNING: possible control-plane oversizing', result.stderr)
            self.assertIn('Continuing without changing VM resources.', result.stderr)
            report = json.loads(result.stdout)
            self.assertTrue(report['fits'])
            self.assertTrue(all(node['oversized'] for node in report['nodes'].values()))

    def test_minimum_failure_and_oversizing_are_independent_per_resource(self):
        self.write(fleet(cp_cpu=2, cp_memory=10240))
        result = self.cli()
        self.assertNotEqual(result.returncode, 0)
        forced = self.cli('--force-control-plane-capacity')
        self.assertEqual(forced.returncode, 0, forced.stderr)
        self.assertIn('deficit 1000m / 0Mi', forced.stderr)
        self.assertIn('possible control-plane oversizing', forced.stderr)

    def test_component_and_budget_overrides_are_counted(self):
        values = fleet()
        values['constants']['talos'].update(api_server_cpu='2', api_server_memory='2Gi',
                                          node_agents_reserve_cpu='1500m', node_agents_reserve_memory='2Gi')
        report = self.evaluate(values)
        self.assertEqual(report['components']['api_server'], {'cpu': '2', 'memory': '2Gi'})
        self.assertEqual(report['budgets']['node_agents'], {'cpu': '1500m', 'memory': '2Gi'})
        self.assertFalse(report['fits'])

    def test_empty_pairs_select_automatic_values(self):
        values = fleet()
        values['constants']['talos'].update(api_server_cpu='', api_server_memory='', max_pods='')
        self.assertEqual(self.evaluate(values)['components']['api_server'], {'cpu': '1', 'memory': '3Gi'})

    def test_invalid_overrides_and_settings_cannot_be_forced(self):
        for overrides in [dict(api_server_cpu='1'), dict(api_server_cpu='1000m', api_server_memory='1Gi'),
                          dict(scheduler_cpu='250m', scheduler_memory='1024Mi'),
                          dict(etcd_reserve_cpu='1'), dict(max_pods='broken'), dict(max_pods='1.5'),
                          dict(max_pods='0'), dict(control_plane_recommended_headroom_percent='100'),
                          dict(control_plane_recommended_headroom_percent='-1'),
                          dict(control_plane_recommended_headroom_percent='10.5'),
                          dict(control_plane_recommended_headroom_percent='broken')]:
            with self.subTest(overrides=overrides):
                values = fleet()
                values['constants']['talos'].update(overrides)
                self.write(values)
                result = self.cli('--force-control-plane-capacity')
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('WARNING:', result.stderr)

    def test_cli_aborts_and_force_preserves_resources_and_deficit_warning(self):
        self.write(fleet(cp_cpu=2, cp_memory=2048))
        result = self.cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('deployment aborted', result.stderr)
        self.assertIn('deficit 1000m / 5120Mi', result.stderr)
        forced = self.cli('--force-control-plane-capacity', '--format', 'json')
        self.assertEqual(forced.returncode, 0, forced.stderr)
        self.assertIn('WARNING:', forced.stderr)
        self.assertIn('deficit 1000m / 5120Mi', forced.stderr)
        self.assertEqual(json.loads(forced.stdout)['components']['api_server']['memory'], '3Gi')

    def test_no_cp_is_an_error_even_with_force(self):
        self.write(fleet(cp_count=0))
        result = self.cli('--force-control-plane-capacity')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No control-plane VMs', result.stderr)

    def test_console_errors_and_reports_do_not_expose_constants(self):
        values = fleet()
        values['constants']['private_value'] = 'secret-sentinel'
        self.write(values)
        for args in [('--format', 'json'), ('--format', 'values')]:
            result = self.cli(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('secret-sentinel', result.stdout + result.stderr)
        (self.cluster / 'constants.auto.tfvars').write_text('constants = { private_value = "secret-sentinel" broken }')
        result = self.cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('secret-sentinel', result.stdout + result.stderr)

    def test_inherited_tf_arguments_cannot_bypass_or_change_the_estimate(self):
        self.write(fleet())
        with patch.dict(os.environ, {'TF_VAR_allow_control_plane_overcommit': 'true',
                                    'TF_CLI_ARGS_console': '-var=resources=broken'}):
            self.assertTrue(SIZING.evaluate(self.cluster)['fits'])

    def test_deploy_gate_stops_before_next_action_and_skips_service_or_destroy_only(self):
        source = (ROOT / 'scripts/deploy.sh').read_text()
        block = source.split('# Check the synchronized final inventory', 1)[1].split('\n', 1)[1].split('\ndeployment_status_enabled=', 1)[0]
        self.write(fleet(cp_cpu=2, cp_memory=2048))
        for force, destroy, services, succeeds in [
            ('false', 'false', 'false', False),
            ('true', 'false', 'false', True),
            ('false', 'true', 'false', True),
            ('false', 'false', 'true', True),
        ]:
            script = 'set -euo pipefail\n' + block + '\nprintf NEXT_ACTION\n'
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                                    env={**os.environ, 'cluster_dir': str(self.cluster), 'script_dir': str(ROOT / 'scripts'),
                                         'force_control_plane_capacity': force, 'destroy_only': destroy,
                                         'services_only': services})
            self.assertEqual(result.returncode == 0, succeeds, result.stderr)
            self.assertEqual('NEXT_ACTION' in result.stdout, succeeds)
            if services == 'true' or destroy == 'true':
                self.assertNotIn('Error:', result.stderr)
                self.assertNotIn('Control plane:', result.stdout)

    def test_services_only_never_invokes_the_sizing_calculator(self):
        source = (ROOT / 'scripts/deploy.sh').read_text()
        block = source.split('# Check the synchronized final inventory', 1)[1].split('\n', 1)[1].split('\ndeployment_status_enabled=', 1)[0]
        script = 'set -euo pipefail\npython3() { echo CALCULATOR_CALLED >&2; return 99; }\n' + block + '\nprintf SERVICE_ACTION\n'
        result = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                                env={**os.environ, 'services_only': 'true', 'destroy_only': 'false',
                                     'force_control_plane_capacity': 'false'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'SERVICE_ACTION')
        self.assertNotIn('CALCULATOR_CALLED', result.stderr)

    def test_deploy_parser_accepts_the_specific_override_flag(self):
        result = subprocess.run(['bash', str(ROOT / 'scripts/deploy.sh'), '--force-control-plane-capacity', '--help'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--force-control-plane-capacity', result.stdout)

    def test_actual_root_preconditions_reject_capacity_and_invalid_forced_input(self):
        workspace = self.cluster / 'out/root'
        workspace.mkdir(parents=True)
        for name in ['vms_variables.tf', 'control-plane-sizing.tf']:
            (workspace / name).symlink_to(ROOT / name)
        lifecycle = (ROOT / 'vms_pve.tf').read_text().split('  lifecycle {', 1)[1].split('\n  name ', 1)[0]
        (workspace / 'gate.tf').write_text('resource "terraform_data" "gate" {\n  lifecycle {' + lifecycle + '\n}\n')
        for command in [['tofu', 'init', '-backend=false', '-no-color'], ['tofu', 'validate', '-no-color']]:
            result = subprocess.run(command, cwd=workspace, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        values = fleet(cp_cpu=2, cp_memory=2048)
        for force, invalid, succeeds in [(False, False, False), (True, False, True), (True, True, False)]:
            values['constants']['talos'] = {'api_server_cpu': '1'} if invalid else {}
            self.write(values)
            command = ['tofu', 'plan', '-input=false', '-no-color', f'-var=allow_control_plane_overcommit={str(force).lower()}']
            command += [f'-var-file={self.cluster / (name + ".auto.tfvars")}' for name in ['constants', 'vms', 'resources']]
            result = subprocess.run(command, cwd=workspace, capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)

        self.write(fleet(cp_cpu=5, cp_memory=10240))
        command = ['tofu', 'plan', '-input=false', '-no-color']
        command += [f'-var-file={self.cluster / (name + ".auto.tfvars")}' for name in ['constants', 'vms', 'resources']]
        result = subprocess.run(command, cwd=workspace, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Possible control-plane oversizing', result.stdout + result.stderr)

    def generate(self, version):
        repository = self.cluster / version
        for name in ['scripts', 'templates', 'patches']:
            shutil.copytree(ROOT / name, repository / name, ignore=shutil.ignore_patterns('__pycache__'))
        for name in ['main.tf', 'providers.tf', 'vms_pve.tf', 'vms_variables.tf', 'control-plane-sizing.tf', '.terraform.lock.hcl']:
            shutil.copy(ROOT / name, repository / name)
        cluster = repository / 'clusters/check'
        cluster.mkdir(parents=True)
        for name in ['constants', 'vms', 'resources']:
            shutil.copy(ROOT / 'clusters/sample' / f'{name}.auto.tfvars', cluster)
        constants = cluster / 'constants.auto.tfvars'
        constants.write_text(constants.read_text().replace('"version" = "v1.13.0"', f'"version" = "{version}"'))
        command = ['bash', str(repository / 'scripts/gen-talos-assets.sh'), '--cluster', 'check']
        command += ['--skip-' + section for section in ['ceph', 'k8s-net', 'identity', 's3-storage', 'platform', 'kafka', 'monitoring', 'benchmark']]
        result = subprocess.run(command, cwd=cluster, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return cluster / 'out/root'

    def test_full_generation_consumes_automatic_sizing_for_both_talos_formats(self):
        for version in ['v1.13.0', 'v1.14.4']:
            with self.subTest(version=version):
                workspace = self.generate(version)
                docs = list(yaml.safe_load_all((workspace / 'patches/machine-talos-cp-01.yaml').read_text()))
                if version == 'v1.13.0':
                    api = docs[0]['cluster']['apiServer']
                else:
                    api = next(d for d in docs if d.get('kind') == 'KubeAPIServerConfig')
                self.assertEqual(api['resources'], {'requests': {'cpu': '1', 'memory': '3Gi'},
                                                    'limits': {'cpu': '1', 'memory': '3Gi'}})
                self.assertTrue((workspace / 'control-plane-sizing.tf').is_symlink())
                self.assertTrue((workspace / 'talos.tf').is_file())

    @unittest.skipUnless((ROOT / '.terraform/providers').exists(), 'Locally cached root providers are required')
    def test_generated_root_workspace_initializes_and_validates_offline(self):
        workspace = self.generate('v1.13.0')
        for command in [
            ['tofu', 'init', '-backend=false', '-input=false', '-lockfile=readonly', '-no-color',
             '-plugin-dir=' + str(ROOT / '.terraform/providers')],
            ['tofu', 'validate', '-no-color'],
        ]:
            result = subprocess.run(command, cwd=workspace, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
