#!/usr/bin/env python3
"""Resize existing control-plane and worker VMs sequentially before the root apply.

OpenTofu owns VM hardware. Talos owns graceful shutdown and staged resources.
A private journal makes a stopped or partially recovered node resumable.
"""
import argparse
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request


class ResizeError(RuntimeError):
    pass


VM = 'proxmox_virtual_environment_vm.create_pve_vms'
MAINTENANCE = 'pve-k8s-talos/node-resize'
LEGACY_MAINTENANCE = 'pve-k8s-talos/control-plane-resize'
COMPONENTS = {'apiServer': 'kube-apiserver', 'controllerManager': 'kube-controller-manager', 'scheduler': 'kube-scheduler'}
CONSTANTS = {'apiServer': 'api_server', 'controllerManager': 'controller_manager', 'scheduler': 'scheduler'}
DOCUMENTS = {'apiServer': 'KubeAPIServerConfig', 'controllerManager': 'KubeControllerManagerConfig', 'scheduler': 'KubeSchedulerConfig'}


def resource_patch(configuration, patch):
    """Match the active node's format, including nodes upgraded with an old contract."""
    kinds = set(re.findall(r'(?m)^kind:\s*([A-Za-z0-9]+)\s*$', configuration))
    legacy, documents = {}, []
    for field, value in patch['cluster'].items():
        kind = DOCUMENTS[field]
        if kind in kinds:
            documents.append({'apiVersion': 'v1alpha1', 'kind': kind, **value})
        else:
            legacy[field] = value
    if legacy:
        documents.insert(0, {'cluster': legacy})
    return '\n---\n'.join(json.dumps(document) for document in documents)


def resize_candidates(plan, journal=None):
    """Reject replacements, shrinking and mixed hardware changes before disruption."""
    variables = {k: v['value'] for k, v in plan['variables'].items()}
    nodes = []
    for change in plan.get('resource_changes', []):
        if change['type'] != 'proxmox_virtual_environment_vm' or change['name'] != 'create_pve_vms':
            continue
        name = change['index']
        before, after = change['change'].get('before'), change['change'].get('after')
        actions = change['change']['actions']
        if before and 'delete' in actions:
            raise ResizeError(f'{name}: refusing node removal/replacement.')
        vm = variables['vms'][name]
        profile = variables['resources'][vm['type']]
        if profile['k8s_node'] not in ('controlplane', 'worker'):
            continue
        if not before:  # Initial bootstrap/scale-out is still owned by the normal apply.
            continue
        if not after:
            continue
        old = (before['cpu'][0]['cores'], before['memory'][0]['dedicated'])
        new = (after['cpu'][0]['cores'], after['memory'][0]['dedicated'])
        if old == new:
            continue
        if any(n < o for o, n in zip(old, new)):
            raise ResizeError(f'{name}: automatic node shrinking is unsupported.')
        allowed = {'cpu', 'memory', 'reboot_after_update'}
        # An interrupted graceful shutdown is an expected runtime difference,
        # but only for the node owned by this journal.
        if (journal and journal['node'] == name and journal['phase'] in ('staged', 'stopped')
                and before.get('started') is False and after.get('started') is True):
            allowed.add('started')
        other = [k for k in before.keys() | after.keys() if k not in allowed and before.get(k) != after.get(k)]
        cpu_other = {k for k in before['cpu'][0].keys() | after['cpu'][0].keys() if k != 'cores' and before['cpu'][0].get(k) != after['cpu'][0].get(k)}
        mem_other = {k for k in before['memory'][0].keys() | after['memory'][0].keys() if k != 'dedicated' and before['memory'][0].get(k) != after['memory'][0].get(k)}
        if other or cpu_other or mem_other:
            raise ResizeError(f'{name}: resize must not include unrelated VM configuration changes.')
        nodes.append(name)
    return variables, nodes


def etcd_rows(output):
    rows = []
    for line in output.splitlines()[1:]:
        if not line.strip():
            continue
        cells = re.split(r'\s{2,}', line.strip())
        if len(cells) not in (11, 12) or (len(cells) == 12 and cells[11]) or cells[8] != 'false':
            raise ResizeError('An etcd member is unhealthy, a learner, or returned an unexpected status.')
        rows.append({'member': cells[1], 'leader': cells[4], 'term': cells[6]})
    if not rows:
        raise ResizeError('No etcd member status returned.')
    return rows


def validate_etcd(rows, expected, full=True):
    members = {r['member'] for r in rows}
    leaders = {r['leader'] for r in rows}
    if len(rows) != expected or len(members) != expected or len(leaders) != 1 or len({r['term'] for r in rows}) != 1:
        raise ResizeError('Etcd members do not agree on membership, leader and term.')
    if full and not leaders.issubset(members):
        raise ResizeError('Etcd leader is not one of the healthy members.')


def decode_stream(text):
    result = []
    decoder = json.JSONDecoder()
    while text.strip():
        item, index = decoder.raw_decode(text.lstrip())
        result.append(item)
        text = text.lstrip()[index:]
    return result


class Resizer:
    def __init__(self, args):
        self.args = args
        self.workspace = Path(args.workspace).resolve()
        self.journal = self.workspace / '.node-resize.json'
        legacy = self.workspace / '.control-plane-resize.json'
        if legacy.exists():
            if self.journal.exists():
                raise ResizeError('Both legacy and current resize journals exist; resolve them before proceeding.')
            legacy.rename(self.journal)
        self.log = self.workspace / '.node-resize.log'
        self.kube = ['kubectl', '--kubeconfig', args.kubeconfig, '--request-timeout=15s']
        self.variables = {}
        self.nodes = {}
        self.cps = {}
        self.endpoint = None
        self.maintenance_renewed_at = None

    def message(self, text):
        print(f'Node resize: {text}', flush=True)

    def command(self, command, timeout=60):
        try:
            r = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ResizeError(f'{command[0]} failed ({type(exc).__name__}).') from exc
        # Commands can return credentials or sensitive plan values. Keep details local.
        fd = os.open(self.log, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, 'a') as f:
            f.write(r.stdout + r.stderr + '\n')
        if r.returncode:
            raise ResizeError(f'{command[0]} failed (exit {r.returncode}); private details: {self.log}')
        return r.stdout

    def tofu(self, *args):
        return self.command(['tofu', f'-chdir={self.workspace}', *args], timeout=900)

    def kube_json(self, *args):
        return json.loads(self.command(self.kube + ['--server', f'https://{self.endpoint}:6443', *args]))

    def talos(self, name, *args):
        return self.command(['talosctl', '--talosconfig', self.args.talosconfig,
                             '--endpoints', self.endpoint, '--nodes', self.nodes[name]['ip'], *args])

    def pve(self, node, suffix):
        base = os.environ.get('TF_VAR_proxmox_endpoint') or os.environ.get('PROXMOX_VE_ENDPOINT', '')
        token = os.environ.get('TF_VAR_proxmox_api_token') or os.environ.get('PROXMOX_VE_API_TOKEN', '')
        if not base or not token:
            raise ResizeError('Missing Proxmox API environment.')
        base = base.rstrip('/')
        if not base.endswith('/api2/json'):
            base += '/api2/json'
        vm = self.nodes[node]
        url = base + f"/nodes/{urllib.parse.quote(vm['node_name'], safe='')}/qemu/{vm['vm_id']}/{suffix}"
        insecure = (os.environ.get('TF_VAR_proxmox_insecure') or os.environ.get('PROXMOX_VE_INSECURE', '')).lower() == 'true'
        req = urllib.request.Request(url, headers={'Authorization': 'PVEAPIToken=' + token})
        with urllib.request.urlopen(req, context=ssl._create_unverified_context() if insecure else None, timeout=30) as r:
            return json.load(r)['data']

    def select_endpoint(self, excluded=None):
        for name, vm in self.cps.items():
            if name == excluded:
                continue
            try:
                self.command(self.kube + ['--server', f"https://{vm['ip']}:6443", 'get', '--raw=/readyz'], timeout=20)
                self.endpoint = vm['ip']
                return
            except ResizeError:
                continue
        raise ResizeError('No healthy alternate control-plane API endpoint.')

    def patch(self):
        talos = self.variables['constants']['talos']
        patch = {}
        for field, prefix in CONSTANTS.items():
            cpu, memory = talos.get(prefix + '_cpu'), talos.get(prefix + '_memory')
            if not cpu or not memory:
                raise ResizeError('Explicit CPU and memory values are required for all control-plane components.')
            patch[field] = {'resources': {'requests': {'cpu': cpu, 'memory': memory}, 'limits': {'cpu': cpu, 'memory': memory}}}
        return {'cluster': patch}

    def desired(self, name):
        profile = self.variables['resources'][self.nodes[name]['type']]
        wanted = {'cores': profile['vcpus'], 'memory': profile['memory']}
        if name in self.cps:
            wanted['patch'] = self.patch()
        return wanted

    def renew_maintenance(self):
        if self.maintenance_renewed_at is None or time.monotonic() - self.maintenance_renewed_at >= 60:
            self.command(['python3', str(Path(__file__).with_name('node-maintenance.py')), 'renew',
                          '--kubeconfig', self.args.kubeconfig, '--state', self.args.maintenance_state,
                          '--owner', self.args.maintenance_owner])
            self.maintenance_renewed_at = time.monotonic()

    def workloads(self):
        self.renew_maintenance()
        self.command(['python3', str(Path(__file__).with_name('check-workload-health.py')),
                      '--kubeconfig', self.args.kubeconfig, '--baseline', self.args.workload_baseline,
                      '--timeout', str(self.args.timeout)], timeout=self.args.timeout + 60)

    def save(self, entry):
        fd = os.open(str(self.journal) + '.tmp', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f:
            json.dump(entry, f)
        os.replace(str(self.journal) + '.tmp', self.journal)

    def node_health(self, excluded=None):
        nodes = self.kube_json('get', 'nodes', '-o', 'json')['items']
        names = {n['metadata']['name'] for n in nodes}
        if not set(self.cps).issubset(names):
            raise ResizeError('A configured control-plane node is missing from Kubernetes.')
        for n in nodes:
            if n['metadata']['name'] == excluded:
                continue
            conditions = {c['type']: c['status'] for c in n['status'].get('conditions', [])}
            if conditions.get('Ready') != 'True' or any(conditions.get(k) == 'True' for k in ['MemoryPressure', 'DiskPressure', 'PIDPressure']):
                raise ResizeError('A node is not Ready or reports resource pressure.')
        for name in self.cps:
            if name != excluded:
                self.command(self.kube + ['--server', f"https://{self.cps[name]['ip']}:6443", 'get', '--raw=/readyz'])
        rows = []
        for name in self.cps:
            if name != excluded:
                rows += etcd_rows(self.talos(name, 'etcd', 'status'))
        excluded_cp = excluded in self.cps
        validate_etcd(rows, len(self.cps) - excluded_cp, full=not excluded_cp)
        pods = self.kube_json('-n', 'kube-system', 'get', 'pods', '-o', 'json')['items']
        for name in self.cps:
            if name == excluded:
                continue
            for component in COMPONENTS.values():
                selected = [p for p in pods if p['spec'].get('nodeName') == name and p['metadata']['name'] == component + '-' + name]
                if len(selected) != 1 or selected[0]['status'].get('phase') != 'Running' or not any(c['type'] == 'Ready' and c['status'] == 'True' for c in selected[0]['status'].get('conditions', [])):
                    raise ResizeError(f'{name}: {component} is not Ready.')
        return nodes, pods

    def recovered(self, entry):
        name, wanted = entry['node'], entry['desired']
        nodes, pods = self.node_health()
        node = next(n for n in nodes if n['metadata']['name'] == name)
        if node['status']['nodeInfo']['bootID'] == entry['boot_id']:
            raise ResizeError('Waiting for a new boot ID.')
        capacity = node['status']['capacity']
        if int(capacity['cpu']) != wanted['cores'] or not re.fullmatch(r'\d+Ki', capacity['memory']):
            raise ResizeError('Waiting for the desired guest CPU/memory capacity.')
        memory = int(capacity['memory'][:-2]) * 1024
        # Kernel reservations grow with RAM; larger workers can lose more than
        # 512MiB between configured VM memory and Kubernetes node capacity.
        overhead = max(512, wanted['memory'] * 0.03)
        if not (wanted['memory'] - overhead) * 1024**2 <= memory <= wanted['memory'] * 1024**2:
            raise ResizeError('Guest memory does not match the resized VM (allowing kernel reservations).')
        config = self.pve(name, 'config')
        if int(config.get('cores', 0)) * int(config.get('sockets', 1)) != wanted['cores'] or int(config.get('memory', 0)) != wanted['memory']:
            raise ResizeError('Proxmox hardware does not match the desired capacity.')
        for field, component in (COMPONENTS.items() if name in self.cps else []):
            pod = next(p for p in pods if p['metadata']['name'] == component + '-' + name)
            resources = next(c['resources'] for c in pod['spec']['containers'] if c['name'] == component)
            if resources != wanted['patch']['cluster'][field]['resources']:
                raise ResizeError(f'{name}: waiting for desired {component} requests/limits.')

    def wait(self, check, description, stable=0):
        deadline = time.monotonic() + self.args.timeout
        since = None
        last = ''
        while time.monotonic() < deadline:
            self.renew_maintenance()
            try:
                check()
                since = since or time.monotonic()
                if time.monotonic() - since >= stable:
                    return
            except (ResizeError, OSError, ValueError) as exc:
                since = None
                last = str(exc)
            time.sleep(5)
        raise ResizeError(f'Timed out waiting for {description}: {last}')

    def resize(self, name):
        self.select_endpoint(excluded=name)
        self.renew_maintenance()
        entry = json.loads(self.journal.read_text()) if self.journal.exists() else None
        if not entry:
            self.node_health()
            self.workloads()
            node = self.kube_json('get', 'node', name, '-o', 'json')
            if node.get('spec', {}).get('unschedulable'):
                raise ResizeError(f'{name}: already cordoned by another operator.')
            configs = decode_stream(self.talos(name, 'get', 'machineconfig', '-o', 'json'))
            active = next(x['spec'] for x in configs if x['metadata']['id'] == 'v1alpha1')
            persistent = next((x['spec'] for x in configs if x['metadata']['id'] == 'persistent'), active)
            if active != persistent:
                raise ResizeError(f'{name}: unrelated staged Talos configuration must be resolved first.')
            entry = {'node': name, 'desired': self.desired(name), 'boot_id': node['status']['nodeInfo']['bootID'], 'phase': 'prepared'}
            self.save(entry)
        if entry['node'] != name or entry['desired'] != self.desired(name):
            raise ResizeError('Pending resize journal does not match the current configuration.')
        self.node_health(excluded=name)
        if entry['phase'] == 'prepared':
            self.message(f'{name}: draining (PDBs enforced).')
            if name in self.cps:
                configs = decode_stream(self.talos(name, 'get', 'machineconfig', '-o', 'json'))
                active = [c['spec'] for c in configs if c['metadata']['id'] == 'v1alpha1']
                if len(active) != 1 or not isinstance(active[0], str):
                    raise ResizeError('Cannot determine active Talos configuration before staging resources.')
                self.talos(name, 'patch', 'machineconfig', '--mode=staged', '--patch', resource_patch(active[0], entry['desired']['patch']))
            self.command(self.kube + ['--server', f'https://{self.endpoint}:6443', 'annotate', 'node', name, MAINTENANCE + '=true', '--overwrite'])
            self.command(self.kube + ['--server', f'https://{self.endpoint}:6443', 'taint', 'node', name, MAINTENANCE + '=true:NoSchedule', '--overwrite'])
            self.command(self.kube + ['--server', f'https://{self.endpoint}:6443', 'drain', name, '--ignore-daemonsets', '--delete-emptydir-data', '--timeout=300s'], timeout=330)
            entry['phase'] = 'staged'
            self.save(entry)
        if entry['phase'] == 'staged':
            self.renew_maintenance()
            if self.pve(name, 'status/current')['status'] != 'stopped':
                self.message(f'{name}: gracefully shutting down Talos.')
                self.talos(name, 'shutdown', '--wait=false')
            self.wait(lambda: self.assert_stopped(name), f'{name} graceful shutdown')
            entry['phase'] = 'stopped'
            self.save(entry)
        if entry['phase'] == 'stopped':
            self.renew_maintenance()
            self.message(f'{name}: applying VM hardware with OpenTofu and starting it.')
            # Only this VM is targeted. The full root apply follows after all resized nodes recover.
            self.tofu('apply', '-input=false', '-auto-approve', '-parallelism=1', '-target=' + VM + '[' + json.dumps(name) + ']')
            entry['phase'] = 'applied'
            self.save(entry)
        self.message(f'{name}: waiting for CPU/RAM and cluster health; stable {self.args.stable_seconds}s.')
        self.wait(lambda: self.recovered(entry), name + ' recovery', stable=self.args.stable_seconds)
        self.release(name)
        self.workloads()
        self.node_health()
        self.journal.unlink()
        self.message(f'{name}: recovered; safe to proceed to the next node.')

    def release(self, name):
        # A previous attempt may have exited between cleanup and deleting the
        # journal. Removing an absent taint must not prevent recovery on retry.
        node = self.kube_json('get', 'node', name, '-o', 'json')
        command = self.kube + ['--server', f'https://{self.endpoint}:6443']
        self.command(command + ['uncordon', name])
        for key in (MAINTENANCE, LEGACY_MAINTENANCE):
            if any(t['key'] == key and t['effect'] == 'NoSchedule' for t in node.get('spec', {}).get('taints', [])):
                self.command(command + ['taint', 'node', name, key + ':NoSchedule-'])
            if key in node['metadata'].get('annotations', {}):
                self.command(command + ['annotate', 'node', name, key + '-'])

    def assert_stopped(self, name):
        if self.pve(name, 'status/current')['status'] != 'stopped':
            raise ResizeError('VM has not stopped.')

    def run(self):
        self.renew_maintenance()
        with tempfile.TemporaryDirectory(prefix='.node-resize-plan-', dir=self.workspace) as tmp:
            plan = str(Path(tmp) / 'resize.plan')
            self.tofu('plan', '-input=false', '-out=' + plan)
            data = json.loads(self.tofu('show', '-json', plan))
        journal = json.loads(self.journal.read_text()) if self.journal.exists() else None
        self.variables, pending = resize_candidates(data, journal)
        self.cps = {n: v for n, v in self.variables['vms'].items() if self.variables['resources'][v['type']]['k8s_node'] == 'controlplane'}
        self.nodes = {n: v for n, v in self.variables['vms'].items() if self.variables['resources'][v['type']]['k8s_node'] in ('controlplane', 'worker')}
        if journal:
            name = journal['node']
            if name not in self.nodes:
                raise ResizeError('Pending resize node no longer exists in configuration.')
            pending = [name] + [n for n in pending if n != name]
        if not pending:
            self.message('no existing node CPU/memory changes.')
            return
        if any(n in self.cps for n in pending) and len(self.cps) < 3:
            raise ResizeError('Rolling control-plane resize requires at least three control-plane members.')
        if not self.journal.exists():
            self.select_endpoint()
            self.node_health()
            # Followers first: avoid the current leader until the other members recover.
            leaders = []
            for name in pending:
                if name not in self.cps:
                    continue
                row = etcd_rows(self.talos(name, 'etcd', 'status'))[0]
                if row['member'] == row['leader']:
                    leaders.append(name)
            pending = sorted(n for n in pending if n in self.cps and n not in leaders) + leaders + sorted(n for n in pending if n not in self.cps)
        for name in pending:
            self.resize(name)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--workspace', required=True)
    p.add_argument('--kubeconfig', required=True)
    p.add_argument('--talosconfig', required=True)
    p.add_argument('--workload-baseline', required=True)
    p.add_argument('--maintenance-state', required=True)
    p.add_argument('--maintenance-owner', required=True)
    p.add_argument('--timeout', type=int, default=900)
    p.add_argument('--stable-seconds', type=int, default=30)
    args = p.parse_args()
    os.umask(0o077)
    try:
        Resizer(args).run()
    except Exception as exc:
        print(f'Error: node resize stopped before touching another node: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
