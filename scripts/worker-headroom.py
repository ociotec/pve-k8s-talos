#!/usr/bin/env python3
"""Report scheduler fit and verify worker headroom without changing cluster resources."""
import argparse
from decimal import Decimal
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time

_spec = importlib.util.spec_from_file_location('worker_reservations', Path(__file__).with_name('worker-reservations.py'))
_reservations = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_reservations)
quantity = _reservations.quantity
pod_requests = _reservations.pod_requests
SELECTOR = 'app.kubernetes.io/part-of=worker-headroom'


def command(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(Path(args[0]).name + ' failed; check connectivity, permissions and workspace initialization.')
    return json.loads(result.stdout) if result.stdout.strip() else {}


def managed(pod):
    return pod['metadata'].get('labels', {}).get('app.kubernetes.io/part-of') == 'worker-headroom'


def active(pod):
    return pod.get('status', {}).get('phase') not in ('Succeeded', 'Failed')


def ready(pod):
    return (pod.get('status', {}).get('phase') == 'Running' and
            any(c['type'] == 'Ready' and c['status'] == 'True' for c in pod.get('status', {}).get('conditions', [])))


def fit_report(config, nodes, pods, priority):
    reports = []
    for name, budget in config['nodes'].items():
        resident = [p for p in pods if active(p) and p['spec'].get('nodeName') == name and not managed(p)]
        protected = [p for p in resident if p['spec'].get('priority', 0) >= priority]
        req = {'cpu': Decimal(budget['cpu_request_m']) / 1000, 'memory': Decimal(budget['memory_mib']) * 1048576}
        capacity = {r: quantity(nodes[name]['status']['allocatable'][r]) for r in req}
        deficits = {r: max(Decimal(0), sum((pod_requests(p, r) for p in resident), Decimal(0)) + req[r] - capacity[r]) for r in req}
        for r in req:
            if sum((pod_requests(p, r) for p in protected), Decimal(0)) + req[r] > capacity[r]:
                raise RuntimeError(name + ': headroom cannot fit alongside equal/higher-priority ' + r + ' requests.')
        if len(protected) + 1 > int(nodes[name]['status']['allocatable']['pods']):
            raise RuntimeError(name + ': protected pods leave no pod slot for headroom.')
        reports.append(name + ': headroom ' + str(budget['cpu_request_m']) + 'm CPU / ' + str(budget['memory_mib']) +
                       'Mi RAM; current deficits ' + str(deficits['cpu']) + ' CPU / ' +
                       str(round(deficits['memory'] / 1048576, 2)) + 'Mi RAM; ' +
                       str(len(resident) + 1) + '/' + nodes[name]['status']['allocatable']['pods'] + ' pod slots; ' +
                       str(len(resident) - len(protected)) + ' lower-priority pods potentially preemptible.')
    return reports


def pending_coverage(config, pods, priority):
    expected = config['nodes']
    actual = [p for p in pods if managed(p) and active(p) and not p['metadata'].get('deletionTimestamp')]
    pending = []
    for name, budget in expected.items():
        found = [p for p in actual if p['spec'].get('nodeName') == name]
        if len(found) != 1 or not ready(found[0]):
            pending.append(name + ': expected one Ready reservation')
            continue
        pod = found[0]
        container = pod['spec']['containers'][0]
        r = container['resources']
        if (pod.get('status', {}).get('qosClass') != 'Burstable' or
            pod['spec'].get('priority') != priority or pod['spec'].get('preemptionPolicy') != 'PreemptLowerPriority' or
            quantity(r['requests']['cpu']) * 1000 != budget['cpu_request_m'] or
            quantity(r['limits']['cpu']) * 1000 != budget['cpu_limit_m'] or
            quantity(r['requests']['memory']) != budget['memory_mib'] * 1048576 or
            quantity(r['limits']['memory']) != budget['memory_mib'] * 1048576):
            pending.append(name + ': effective resources or priority differ from the calculation')
    if any(p['spec'].get('nodeName') not in expected for p in actual if p['spec'].get('nodeName')):
        pending.append('reservation exists on an excluded node')
    if any(not p['spec'].get('nodeName') for p in actual):
        pending.append('reservation Pending; inspect scheduling constraints and preemption events')
    return pending


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['preflight', 'verify'])
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--kubeconfig', required=True)
    parser.add_argument('--plan', type=Path)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--timeout', type=int, default=600)
    args = parser.parse_args()
    kube = ['kubectl', '--kubeconfig', args.kubeconfig, '--request-timeout=30s']
    try:
        if args.phase == 'preflight':
            if not args.plan:
                parser.error('preflight requires --plan')
            plan = command(['tofu', '-chdir=' + str(args.workspace), 'show', '-json', str(args.plan)])
            config = plan['planned_values']['outputs']['worker_headroom']['value']
        else:
            config = command(['tofu', '-chdir=' + str(args.workspace), 'output', '-json', 'worker_headroom'])
        nodes = {n['metadata']['name']: n for n in command(kube + ['get', 'nodes', '-o', 'json'])['items']}
        priority = command(kube + ['get', 'priorityclass', 'infra-headroom', '-o', 'json'])
        if priority.get('preemptionPolicy') != 'PreemptLowerPriority':
            raise RuntimeError('infra-headroom must use PreemptLowerPriority.')
        pods = command(kube + ['get', 'pods', '-A', '-o', 'json'])['items']
        if args.phase == 'preflight':
            for line in fit_report(config, nodes, pods, priority['value']):
                print(line)
            baseline = {'pods': pods, 'boot_ids': {n: o['status']['nodeInfo']['bootID'] for n, o in nodes.items()}}
            args.baseline.write_text(json.dumps(baseline))
            args.baseline.chmod(0o600)
            return 0
        deadline = time.monotonic() + args.timeout
        stable = 0
        while True:
            pending = pending_coverage(config, pods, priority['value'])
            stable = 0 if pending else stable + 1
            if stable >= 3:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError('Incomplete headroom coverage: ' + '; '.join(pending))
            time.sleep(5)
            pods = command(kube + ['get', 'pods', '-A', '-o', 'json'])['items']
        nodes = {n['metadata']['name']: n for n in command(kube + ['get', 'nodes', '-o', 'json'])['items']}
        baseline = json.loads(args.baseline.read_text())
        for name, boot_id in baseline['boot_ids'].items():
            if name not in nodes or nodes[name]['status']['nodeInfo']['bootID'] != boot_id:
                raise RuntimeError('Node restart or removal detected during headroom deployment: ' + name)
        old = {p['metadata']['uid']: p for p in baseline['pods'] if active(p) and not managed(p)}
        current = {p['metadata']['uid']: p for p in pods}
        displaced = [p['metadata']['namespace'] + '/' + p['metadata']['name'] for uid, p in old.items() if uid not in current]
        unready = [p['metadata']['namespace'] + '/' + p['metadata']['name'] for p in pods if active(p) and not managed(p) and not ready(p)]
        print('Headroom verified on ' + str(len(config['nodes'])) + ' workers; no node restart detected.')
        print('Previous non-headroom pods replaced/removed: ' + (', '.join(displaced) or 'none'))
        print('Currently unready non-headroom pods: ' + (', '.join(unready) or 'none'))
        return 0
    except Exception as error:
        print(str(error) if isinstance(error, RuntimeError) else 'Headroom validation failed (' + type(error).__name__ + ').', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
