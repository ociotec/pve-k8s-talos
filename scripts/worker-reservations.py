#!/usr/bin/env python3
"""Calculate, render and inspect worker host budgets without exposing credentials."""
import argparse
import copy
from decimal import Decimal
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
DISK_EVICTIONS = {'nodefs.available': '10%', 'nodefs.inodesFree': '5%',
                  'imagefs.available': '15%', 'imagefs.inodesFree': '5%'}


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, timeout=kwargs.pop('timeout', 60), **kwargs)
    if result.returncode:
        # Configuration and API diagnostics can contain secrets. Retain safe summaries.
        summaries = [s.strip() for s in result.stderr.splitlines() if s.startswith('Error:')]
        raise ValueError(f'{Path(command[0]).name} failed: ' + ('; '.join(summaries) or 'check connectivity, permissions and input configuration.'))
    return result.stdout


def evaluate(cluster, check_capacity=True):
    with tempfile.TemporaryDirectory(prefix='worker-reservations-') as tmp:
        workspace = Path(tmp)
        for name in ['vms_variables.tf', 'worker-reservations.tf']:
            (workspace / name).symlink_to(ROOT / name)
        environment = {k: v for k, v in os.environ.items()
                       if not k.startswith(('TF_VAR_', 'TF_CLI_ARGS', 'TF_LOG'))
                       and k not in ('TF_DATA_DIR', 'TF_WORKSPACE')}
        command = ['tofu', f'-chdir={workspace}', 'console', '-no-color']
        command += [f'-var-file={cluster / (name + ".auto.tfvars")}' for name in ['constants', 'vms', 'resources']]
        expression = ('jsonencode({sizing=local.worker_reservations,'
                      'version=var.constants.talos.version})\n')
        result = json.loads(json.loads(run(command, input=expression, env=environment)))
    report = result['sizing']
    report['version'] = result['version']
    if report['invalid']:
        raise ValueError('Invalid worker reservation settings: ' + ', '.join(report['invalid']))
    if check_capacity and not report['fits']:
        names = [n for n, v in report['nodes'].items()
                 if v['allocatable_cpu_m'] <= 0 or v['allocatable_memory_mib'] <= 0]
        raise ValueError('Worker reservations leave no pod capacity: ' + ', '.join(names))
    return report


def quantity(value, cpu=False):
    value = str(value)
    match = re.fullmatch(r'([0-9]+(?:\.[0-9]+)?)(m|Ki|Mi|Gi|Ti|[kMGT])?', value)
    if not match:
        raise ValueError('Invalid resource quantity in reservation configuration.')
    suffix = match[2] or ''
    factors = {'': 1, 'm': Decimal('.001'), 'Ki': 1024, 'Mi': 1024**2,
               'Gi': 1024**3, 'Ti': 1024**4, 'k': 1000, 'M': 1000**2,
               'G': 1000**3, 'T': 1000**4}
    return Decimal(match[1]) * factors[suffix]


def equivalent(a, b):
    try:
        return quantity(a) == quantity(b)
    except ValueError:
        return a == b


def kubelet_config(documents):
    """Read the active legacy or native kubelet block, rejecting ambiguous ownership."""
    blocks = []
    for document in documents:
        if not isinstance(document, dict):
            raise ValueError('Talos configuration must contain mapping documents.')
        if document.get('$patch') == 'delete':
            continue
        if document.get('kind') == 'KubeletConfig':
            blocks.append((document, 'config'))
        elif document.get('kind') in (None, 'Config'):
            machine = document.get('machine', {})
            if 'kubelet' in machine:
                blocks.append((machine['kubelet'], 'extraConfig'))
    if len(blocks) != 1:
        raise ValueError('Expected exactly one active kubelet configuration block.')
    block, key = blocks[0]
    return block.setdefault(key, {}), block


def decode_configuration(source):
    import yaml
    # Some Talos API/CLI combinations return a YAML-quoted configuration string
    # inside the JSON spec. Decode the wrapper without printing its secret data.
    try:
        for _ in range(3):
            if isinstance(source, dict):
                return [source]
            docs = [d for d in yaml.safe_load_all(source) if d]
            if len(docs) == 1 and isinstance(docs[0], str):
                source = docs[0]
                continue
            if docs and all(isinstance(d, dict) for d in docs):
                return docs
            break
    except yaml.YAMLError:
        pass
    raise ValueError('Cannot decode Talos machine configuration; inspect it privately.')


def merged_config(existing, desired, version):
    match = re.match(r'^v?(\d+)\.(\d+)(?:\.|$)', version)
    if not match or not (1, 9) <= tuple(map(int, match.groups())) <= (1, 14):
        raise ValueError('Worker reservation defaults are verified for Talos 1.9 through 1.14 only.')
    result = copy.deepcopy(existing)
    for group in ['systemReserved', 'kubeReserved', 'evictionHard']:
        current = result.setdefault(group, {})
        for key, value in desired[group].items():
            if key in current and not equivalent(current[key], value):
                raise ValueError(f'Conflicting custom kubelet setting: {group}.{key}; resolve it in source configuration.')
            current[key] = value
    if existing.get('enforceNodeAllocatable', ['pods']) != ['pods']:
        raise ValueError('Conflicting custom kubelet setting: enforceNodeAllocatable.')
    if any(existing.get(key) for key in ['systemReservedCgroup', 'kubeReservedCgroup', 'reservedSystemCPUs']):
        raise ValueError('Custom reservation cgroups or exclusive system CPUs require explicit reconciliation.')
    result['enforceNodeAllocatable'] = ['pods']
    # A nonempty systemReserved map suppresses these Talos defaults.
    # An explicit existing map suppresses them already; preserve that behavior too.
    if not existing.get('systemReserved'):
        result['systemReserved'].update({'pid': '100', 'ephemeral-storage': '256Mi'})
    hard = result['evictionHard']
    original_hard = existing.get('evictionHard', {})
    # Kubernetes defaults unspecified thresholds to zero for a custom map,
    # unless mergeDefaultEvictionSettings was explicitly enabled.
    for key, default in DISK_EVICTIONS.items():
        hard.setdefault(key, default if not original_hard or existing.get('mergeDefaultEvictionSettings') else '0%')
    return result


def prepare(report, directory):
    import yaml
    outputs = {}
    for name, node in report['nodes'].items():
        path = directory / f'machine-{name}.yaml'
        if path.is_symlink():
            raise ValueError('Generated worker patches must not be source symlinks.')
        docs = [d for d in yaml.safe_load_all(path.read_text()) if d]
        existing, block = kubelet_config(docs)
        args = block.get('extraArgs', {})
        if any(k in args for k in ['system-reserved', 'kube-reserved', 'eviction-hard',
                                   'enforce-node-allocatable', 'reserved-cpus']):
            raise ValueError(f'{name}: reservation CLI arguments conflict with automatic kubelet configuration.')
        updated = merged_config(existing, node['config'], report['version'])
        existing.clear()
        existing.update(updated)
        outputs[path] = yaml.safe_dump_all(docs, sort_keys=False)
    # Validate every worker before writing the first one.
    for path, content in outputs.items():
        path.write_text(content)


def summary(report):
    for name, node in report['nodes'].items():
        print(f'Worker {name}: system {node["config"]["systemReserved"]["cpu"]}/'
              f'{node["config"]["systemReserved"]["memory"]}, kubelet/runtime '
              f'{node["config"]["kubeReserved"]["cpu"]}/{node["config"]["kubeReserved"]["memory"]}, '
              f'eviction {node["config"]["evictionHard"]["memory.available"]}; '
              f'projected pods {node["allocatable_cpu_m"] / 1000:g} CPU/'
              f'{node["allocatable_memory_mib"]:g}Mi, max_pods={report["max_pods"]}.')


def pod_requests(pod, resource):
    """Scheduler requests including sequential init containers and restartable sidecars."""
    spec = pod['spec']
    def request(container):
        return quantity(container.get('resources', {}).get('requests', {}).get(resource, '0'))
    running = sum((request(c) for c in spec.get('containers', [])), Decimal(0))
    sidecars, init_peak = Decimal(0), Decimal(0)
    for container in spec.get('initContainers', []):
        value = request(container)
        if container.get('restartPolicy') == 'Always':
            sidecars += value
            init_peak = max(init_peak, sidecars)
        else:
            init_peak = max(init_peak, sidecars + value)
    total = max(running + sidecars, init_peak)
    total = max(total, quantity(spec.get('resources', {}).get('requests', {}).get(resource, '0')))
    return total + quantity(spec.get('overhead', {}).get(resource, '0'))


class Live:
    def __init__(self, kubeconfig, talosconfig):
        self.kube = ['kubectl', '--kubeconfig', str(kubeconfig), '--request-timeout=20s']
        self.talosconfig = str(talosconfig)

    def kubectl(self, *args, **kwargs):
        return run(self.kube + list(args), **kwargs)

    def talos(self, address, *args):
        return run(['talosctl', '--talosconfig', self.talosconfig, '--nodes', address, *args])

    def active(self, address):
        response = json.loads(self.talos(address, 'get', 'machineconfig', 'v1alpha1', '-o', 'json'))
        return decode_configuration(response['spec'])

    def effective(self, name):
        return json.loads(self.kubectl('get', '--raw', f'/api/v1/nodes/{name}/proxy/configz'))['kubeletconfig']


def desired_config(report, name, directory):
    import yaml
    if directory:
        docs = [d for d in yaml.safe_load_all((directory / f'machine-{name}.yaml').read_text()) if d]
        return kubelet_config(docs)[0]
    return merged_config({}, report['nodes'][name]['config'], report['version'])


def check_live(report, client, directory=None, previous=None, selected=None):
    """Read-only gate: preserve custom settings and report request headroom before mutation."""
    inventory = {n['metadata']['name']: n for n in json.loads(client.kubectl('get', 'nodes', '-o', 'json'))['items']}
    pods = json.loads(client.kubectl('get', 'pods', '-A', '-o', 'json'))['items']
    results = {}
    for name, node in report['nodes'].items():
        if selected and name != selected:
            continue
        if name not in inventory:  # Scale-out workers have no active configuration.
            if selected:
                raise ValueError('The selected worker must exist in the live cluster.')
            continue
        live = inventory[name]
        addresses = [a['address'] for a in live['status']['addresses'] if a['type'] == 'InternalIP']
        if not addresses:
            raise ValueError(f'{name}: no internal node address.')
        active = client.active(addresses[0])
        explicit, block = kubelet_config(active)
        if any(key in block.get('extraArgs', {}) for key in ['system-reserved', 'kube-reserved',
               'eviction-hard', 'enforce-node-allocatable', 'reserved-cpus']):
            raise ValueError(f'{name}: reconcile custom reservation CLI arguments before deployment.')
        effective = client.effective(name)
        desired = desired_config(report, name, directory)
        old = (previous or {}).get('nodes', {}).get(name, {}).get('config', {})
        for key in ['evictionSoft', 'evictionSoftGracePeriod', 'evictionMinimumReclaim',
                    'evictionMaxPodGracePeriod', 'evictionPressureTransitionPeriod',
                    'mergeDefaultEvictionSettings']:
            if key in explicit and explicit[key] != desired.get(key, {} if isinstance(explicit[key], dict) else None):
                raise ValueError(f'{name}: preserve active {key} in the source machine template before deployment.')
        for group in ['systemReserved', 'kubeReserved', 'evictionHard']:
            for key, value in node['config'][group].items():
                actual = explicit.get(group, {}).get(key)
                if actual is not None and not any(equivalent(actual, candidate) for candidate in
                                                  [value, old.get(group, {}).get(key, value)]):
                    raise ValueError(f'{name}: conflicting active {group}.{key}; reconcile its source before deployment.')
            # Preserve every unowned effective setting, including PID, storage and eviction signals.
            for key, value in effective.get(group, {}).items():
                if key not in node['config'][group] and not equivalent(value, desired.get(group, {}).get(key, '0')):
                    raise ValueError(f'{name}: preserve active {group}.{key} in the source machine template before deployment.')
        if effective.get('enforceNodeAllocatable', ['pods']) != ['pods'] or any(effective.get(k) for k in
                ['systemReservedCgroup', 'kubeReservedCgroup', 'reservedSystemCPUs']):
            raise ValueError(f'{name}: custom allocation enforcement requires reconciliation.')
        cpu = quantity(live['status']['capacity']['cpu']) - Decimal(node['system_cpu_m'] + node['kube_cpu_m']) / 1000
        memory = quantity(live['status']['capacity']['memory']) - Decimal(
            node['system_memory_mib'] + node['kube_memory_mib'] + node['eviction_memory_mib']) * 1024**2
        if cpu <= 0 or memory <= 0:
            raise ValueError(f'{name}: live Capacity cannot hold the calculated reservations.')
        resident = [p for p in pods if p['spec'].get('nodeName') == name
                    and p.get('status', {}).get('phase') not in ['Succeeded', 'Failed']]
        for resource, available in [('cpu', cpu), ('memory', memory)]:
            used = sum((pod_requests(p, resource) for p in resident), Decimal(0))
            if used > available:
                print(f'WARNING: {name}: current pod {resource} requests exceed projected Allocatable.', file=sys.stderr)
        results[name] = {'address': addresses[0], 'active': active, 'desired': desired,
                         'cpu': cpu, 'memory': memory,
                         'unschedulable': live['spec'].get('unschedulable', False)}
    return results


def verify_live(report, client, selected=None):
    inventory = {n['metadata']['name']: n for n in json.loads(client.kubectl('get', 'nodes', '-o', 'json'))['items']}
    if selected and selected not in report['nodes']:
        raise ValueError('Reservation verification requires a declared worker.')
    if any(not any(c['type'] == 'Ready' and c['status'] == 'True' for c in node['status']['conditions'])
           for node in inventory.values()):
        raise ValueError('All cluster nodes must be Ready before continuing worker recovery.')
    for name, budget in report['nodes'].items():
        if selected and name != selected:
            continue
        node = inventory[name]
        if not any(c['type'] == 'Ready' and c['status'] == 'True' for c in node['status']['conditions']):
            raise ValueError(f'{name}: worker is not Ready.')
        if any(c['type'] in ['MemoryPressure', 'DiskPressure', 'PIDPressure'] and c['status'] == 'True'
               for c in node['status']['conditions']):
            raise ValueError(f'{name}: worker reports resource pressure.')
        effective = client.effective(name)
        for group in ['systemReserved', 'kubeReserved', 'evictionHard']:
            for key, desired in budget['config'][group].items():
                if not equivalent(effective.get(group, {}).get(key, '0'), desired):
                    raise ValueError(f'{name}: effective {group}.{key} does not match the calculated reservation.')
        if effective.get('enforceNodeAllocatable', ['pods']) != ['pods']:
            raise ValueError(f'{name}: pod allocation enforcement differs from the reservation policy.')
        for resource, reserve in [('cpu', Decimal(budget['system_cpu_m'] + budget['kube_cpu_m']) / 1000),
                                  ('memory', Decimal(budget['system_memory_mib'] + budget['kube_memory_mib'] + budget['eviction_memory_mib']) * 1024**2)]:
            expected = quantity(node['status']['capacity'][resource]) - reserve
            if quantity(node['status']['allocatable'][resource]) != expected:
                raise ValueError(f'{name}: published {resource} Allocatable differs from live Capacity minus reservations.')


def previous_report(state):
    if state and state.is_file():
        return json.loads(state.read_text()).get('outputs', {}).get('worker_reservations', {}).get('value', {})
    return {}


def wait_verified(report, client, selected, stable_seconds=30, timeout=900, health=None, renew=None):
    """Require continuous node and workload health, resetting the window on any failure."""
    deadline = time.monotonic() + timeout
    stable_since = None
    renewed_at = None
    last_error = 'Worker recovery has not completed.'
    while True:
        now = time.monotonic()
        if renew and (renewed_at is None or now - renewed_at >= 60):
            renew()  # Losing maintenance ownership must stop the operation immediately.
            renewed_at = now
        try:
            verify_live(report, client, selected)
            if health:
                health()
        except ValueError as exc:
            stable_since = None
            last_error = str(exc)
        else:
            if stable_since is None:
                stable_since = time.monotonic()
            if time.monotonic() - stable_since >= stable_seconds:
                print(f'Worker {selected}: reservations, Allocatable and workloads stable for {stable_seconds}s.')
                return
        if time.monotonic() >= deadline:
            raise ValueError(f'{selected}: recovery did not stabilize: {last_error}')
        time.sleep(5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cluster-dir', type=Path, default=Path.cwd())
    parser.add_argument('--prepare-patches', type=Path)
    parser.add_argument('--format', choices=['summary', 'json'], default='summary')
    parser.add_argument('--check-live', action='store_true')
    parser.add_argument('--verify-live', action='store_true')
    parser.add_argument('--patch-dir', type=Path)
    parser.add_argument('--state', type=Path)
    parser.add_argument('--kubeconfig', type=Path)
    parser.add_argument('--talosconfig', type=Path)
    parser.add_argument('--worker', help='Verify only this worker before advancing the rolling deployment.')
    parser.add_argument('--stable-seconds', type=int, default=0)
    parser.add_argument('--workload-baseline', type=Path)
    parser.add_argument('--maintenance-state', type=Path)
    parser.add_argument('--maintenance-owner')
    parser.add_argument('--infrastructure-health-only', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        report = evaluate(args.cluster_dir.resolve(), check_capacity=not args.prepare_patches)
        if args.prepare_patches:
            prepare(report, args.prepare_patches)
        if args.check_live or args.verify_live:
            if not args.kubeconfig or not args.talosconfig:
                raise ValueError('Live checks require kubeconfig and talosconfig paths.')
            client = Live(args.kubeconfig, args.talosconfig)
            if args.check_live:
                check_live(report, client, args.patch_dir, previous_report(args.state))
            if args.verify_live:
                if args.stable_seconds:
                    if not args.worker or not 0 < args.stable_seconds < 900:
                        raise ValueError('Stable verification requires a worker and a duration below 900 seconds.')
                    health = None
                    if args.workload_baseline:
                        health_args = [sys.executable, str(ROOT / 'scripts/check-workload-health.py'),
                                       '--kubeconfig', str(args.kubeconfig), '--baseline', str(args.workload_baseline),
                                       '--timeout', '1']
                        if args.infrastructure_health_only:
                            health_args.append('--infrastructure-health-only')
                        health = lambda: run(health_args, timeout=60)
                    renew = None
                    if args.maintenance_state:
                        if not args.maintenance_owner:
                            raise ValueError('Maintenance renewal requires its existing owner.')
                        renew = lambda: run([sys.executable, str(ROOT / 'scripts/node-maintenance.py'), 'renew',
                                             '--kubeconfig', str(args.kubeconfig), '--state', str(args.maintenance_state),
                                             '--owner', args.maintenance_owner])
                    wait_verified(report, client, args.worker, args.stable_seconds, health=health, renew=renew)
                else:
                    verify_live(report, client, args.worker)
        if args.format == 'json':
            print(json.dumps(report))
        elif not args.verify_live:
            summary(report)
        return 0
    except Exception as exc:
        # YAML diagnostics can quote registry credentials from a source patch.
        detail = str(exc) if type(exc) is ValueError else 'Check worker reservation inputs, API responses and local dependencies.'
        print('Error: ' + detail, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
