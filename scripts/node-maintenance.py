#!/usr/bin/env python3
"""Bounded, owner-scoped node maintenance coordinated with automatic remediation."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys
import time

UNTIL = 'pve-k8s-talos/maintenance-until'
OWNER = 'pve-k8s-talos/maintenance-owner'
STATE = 'remediation.pve-k8s-talos/state'
PROTOCOL = 'pve-k8s-talos/maintenance-protocol'
REGISTRY_MAINTENANCE = 'pve-k8s-talos/registry-auth-maintenance'
PATCH_ATTEMPTS = 20


class ResourceConflict(RuntimeError):
    pass


def ready(node):
    return any(c['type'] == 'Ready' and c['status'] == 'True' for c in node.get('status', {}).get('conditions', []))


def timestamp():
    return dt.datetime.now(dt.timezone.utc)


def validate_entry(node, owner, now, resuming=False):
    annotations = node['metadata'].get('annotations', {})
    if annotations.get(STATE, '') not in ('', 'cooldown'):
        raise ValueError('A node is already undergoing recovery; finish it before planned maintenance.')
    if annotations.get(OWNER) != owner and annotations.get(UNTIL):
        until = dt.datetime.fromisoformat(annotations[UNTIL].replace('Z', '+00:00'))
        if until > now:
            raise ValueError('Another operator owns active node maintenance.')
    # Registry reconciliation quarantines pending credentials before its sequential
    # reboots. That scheduling guard does not disable automatic remediation.
    registry_cordon = annotations.get(REGISTRY_MAINTENANCE) == 'true'
    if not resuming and (not ready(node) or (node.get('spec', {}).get('unschedulable') and not registry_cordon)):
        raise ValueError('Maintenance must start with Ready nodes not cordoned by another operator.')


class Kubernetes:
    def __init__(self, kubeconfig):
        self.command = ['kubectl', '--kubeconfig', kubeconfig, '--request-timeout=20s']

    def run(self, args):
        r = subprocess.run(self.command + args, capture_output=True, text=True, timeout=40)
        if r.returncode:
            error = 'Kubernetes maintenance operation failed: ' + r.stderr.strip()
            if '(Conflict)' in r.stderr: raise ResourceConflict(error)
            raise RuntimeError(error)
        return r.stdout

    def get(self, args):
        data = self.run(['get'] + args + ['-o', 'json'])
        return json.loads(data) if data.strip() else None

    def patch(self, node, values):
        # Retry unrelated kubelet/status updates, but never race past another
        # maintainer, recovery transition or cordon. Every retry retains CAS.
        original = node
        guards = (OWNER, UNTIL, STATE)
        for attempt in range(PATCH_ATTEMPTS):
            payload = {'metadata': {'resourceVersion': node['metadata']['resourceVersion'], 'annotations': values}}
            try:
                self.run(['patch', 'node', node['metadata']['name'], '--type=merge', '-p', json.dumps(payload)])
                return
            except ResourceConflict:
                if attempt == PATCH_ATTEMPTS - 1: raise
                # Read after backoff so status writes during sleep cannot age CAS.
                time.sleep(min(0.1 * (attempt + 1), 1.0))
                node = self.get(['node', node['metadata']['name']])
                old = original['metadata'].get('annotations', {})
                current = node['metadata'].get('annotations', {})
                if (any(old.get(key) != current.get(key) for key in guards)
                        or original.get('spec', {}).get('unschedulable', False) != node.get('spec', {}).get('unschedulable', False)):
                    raise ValueError('Node maintenance/recovery ownership or cordon changed during update.')
                if OWNER in values and values[OWNER] != old.get(OWNER) and not ready(node):
                    raise ValueError('Cannot change maintenance ownership while the node is unready.')

    def verify_controller(self):
        deployment = self.get(['deployment', 'node-remediation-controller', '-n', 'kube-system', '--ignore-not-found'])
        if deployment is None: return
        pods = self.get(['pods', '-n', 'kube-system', '-l', 'app.kubernetes.io/name=node-remediation-controller'])['items']
        active = [p for p in pods if p['status'].get('phase') not in ('Succeeded', 'Failed')]
        desired = deployment['spec'].get('replicas', 1)
        if len(active) < desired or any(p['metadata'].get('annotations', {}).get(PROTOCOL) != '1' or not ready(p) for p in active):
            raise ValueError('Deploy the k8s-net remediation maintenance protocol first; old controller pods are still active.')


def save(path, state):
    temporary = path.with_suffix('.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f: json.dump(state, f)
    os.replace(temporary, path)


def read_state(path, owner):
    state = json.loads(path.read_text()) if path.exists() else {'owner': owner, 'nodes': {}}
    if state['owner'] != owner:
        raise ValueError('Maintenance state belongs to another deployment.')
    return state


def check_peers(kube, owner, active=()):
    """Other nodes retain remediation and must be healthy before maintenance proceeds."""
    for node in kube.get(['nodes'])['items']:
        name = node['metadata']['name']
        if name in active:
            continue
        validate_entry(node, owner, timestamp())
        until = node['metadata'].get('annotations', {}).get(UNTIL)
        if until and dt.datetime.fromisoformat(until.replace('Z', '+00:00')) > timestamp():
            raise ValueError('Another node has active maintenance; refusing overlapping interventions.')


def preflight(kube, path, owner, names):
    """Validate the inventory without annotating or disabling any node."""
    kube.verify_controller()
    state = read_state(path, owner)
    if len(state['nodes']) > 1:
        raise ValueError('Legacy maintenance covers multiple nodes; recover and release it before proceeding.')
    check_peers(kube, owner, state['nodes'])
    now = timestamp()
    nodes = []
    for name in names:
        node = kube.get(['node', name, '--ignore-not-found'])
        if node is None: continue  # A scale-out node has not registered yet.
        validate_entry(node, owner, now, resuming=name in state['nodes'])
        nodes.append(node)
    return state, nodes


def begin(kube, path, owner, names, ttl):
    state, nodes = preflight(kube, path, owner, names)
    if len(nodes) != 1:
        raise ValueError('Maintenance must select exactly one registered node.')
    selected = nodes[0]['metadata']['name']
    if set(state['nodes']) - {selected}:
        raise ValueError('Finish the current node maintenance before selecting another node.')
    # Recheck peers immediately before acquiring the selected node's lease.
    check_peers(kube, owner, [selected])
    now = timestamp()
    for initial in nodes:
        name = initial['metadata']['name']
        # The all-node preflight can outlive a kubelet status update.
        node = kube.get(['node', name])
        if node is None: raise ValueError('A node disappeared during maintenance preflight.')
        validate_entry(node, owner, timestamp(), resuming=name in state['nodes'])
        annotations = node['metadata'].get('annotations', {})
        if name not in state['nodes']:
            state['nodes'][name] = {'annotations': {key: annotations.get(key) for key in (OWNER, UNTIL)},
                                    'unschedulable': node.get('spec', {}).get('unschedulable', False)}
            save(path, state)
        kube.patch(node, {OWNER: owner, UNTIL: (now + dt.timedelta(seconds=ttl)).isoformat().replace('+00:00', 'Z')})
    save(path, state)
    print(f'Planned maintenance active for {len(nodes)} registered nodes (bounded lease).')


def renew(kube, path, owner, ttl):
    state = read_state(path, owner)
    if len(state['nodes']) != 1:
        raise ValueError('Maintenance renewal requires exactly one active node.')
    check_peers(kube, owner, state['nodes'])
    for name in state['nodes']:
        node = kube.get(['node', name, '--ignore-not-found'])
        if node is None:
            raise ValueError('The maintenance node disappeared; refusing to continue.')
        if node['metadata'].get('annotations', {}).get(OWNER) != owner:
            raise ValueError('Node maintenance ownership changed; refusing to continue.')
        validate_entry(node, owner, timestamp(), resuming=True)
        kube.patch(node, {UNTIL: (timestamp() + dt.timedelta(seconds=ttl)).isoformat().replace('+00:00', 'Z')})


def finish(kube, path, owner, names=None):
    if not path.exists(): return
    state = read_state(path, owner)
    selected = list(state['nodes']) if names is None else names
    for name in selected:
        if name not in state['nodes']:
            continue
        node = kube.get(['node', name, '--ignore-not-found'])
        if names is not None and (node is None or node['metadata'].get('annotations', {}).get(OWNER) != owner):
            raise ValueError('Cannot release node maintenance after ownership loss or node removal.')
        if node is not None and node['metadata'].get('annotations', {}).get(OWNER) == owner:
            if not ready(node) or node['metadata'].get('annotations', {}).get(STATE, '') not in ('', 'cooldown'):
                continue  # Keep protection only until its bounded expiry.
            if not state['nodes'][name]['unschedulable'] and node.get('spec', {}).get('unschedulable'):
                kube.run(['uncordon', name])
                node = kube.get(['node', name])
            kube.patch(node, state['nodes'][name]['annotations'])
        del state['nodes'][name]
        save(path, state)
    if state['nodes']:
        print('Unfinished nodes retain maintenance until expiry; resume from this PC.', file=sys.stderr)
        if names is not None and set(names) & set(state['nodes']):
            raise ValueError('The selected node has not recovered; maintenance remains active.')
    else:
        path.unlink(missing_ok=True)
        print('Planned node maintenance released.')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['preflight', 'begin', 'renew', 'finish']); p.add_argument('--kubeconfig', required=True)
    p.add_argument('--state', required=True); p.add_argument('--owner', required=True)
    p.add_argument('--node', action='append', default=[]); p.add_argument('--ttl', type=int, default=1800)
    a = p.parse_args()
    if not 60 <= a.ttl <= 3600: raise ValueError('Maintenance TTL must be between 60 and 3600 seconds.')
    kube, path = Kubernetes(a.kubeconfig), Path(a.state)
    if a.action == 'preflight': preflight(kube, path, a.owner, a.node)
    elif a.action == 'begin': begin(kube, path, a.owner, a.node, a.ttl)
    elif a.action == 'renew': renew(kube, path, a.owner, a.ttl)
    else: finish(kube, path, a.owner, a.node or None)

if __name__ == '__main__':
    try: main()
    except Exception as exc:
        print('Error: node maintenance failed: ' + str(exc), file=sys.stderr); sys.exit(1)
