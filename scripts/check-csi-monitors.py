#!/usr/bin/env python3
"""Wait for the configuration actually consumed by CSI to contain current MONs."""
import argparse
import json
import subprocess
import sys
import time


def matches(endpoints, configuration, cluster_id):
    expected = {part.split('=', 1)[1] for part in endpoints.get('data', {}).get('data', '').split(',') if '=' in part}
    if not expected:
        return False
    entries = []
    for value in configuration.get('data', {}).values():
        try:
            data = json.loads(value)
        except (ValueError, TypeError):
            continue
        if isinstance(data, dict):
            data = data.get('clusters', [data])
        if isinstance(data, list):
            entries.extend(x for x in data if isinstance(x, dict))
    selected = [x for x in entries if x.get('clusterID') == cluster_id]
    monitors = selected[0].get('monitors') if len(selected) == 1 else None
    return isinstance(monitors, list) and all(isinstance(x, str) for x in monitors) and set(monitors) == expected


def wait(get, namespace, configmap, cluster_id, timeout):
    deadline = time.monotonic() + timeout
    while True:
        endpoints = get(namespace, 'rook-ceph-mon-endpoints')
        configuration = get(namespace, configmap)
        if matches(endpoints, configuration, cluster_id):
            print('CSI consumes the current external Ceph monitor endpoints.')
            return
        if time.monotonic() >= deadline:
            raise ValueError('CSI monitor configuration did not converge; no CSI restart was requested.')
        time.sleep(2)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--kubeconfig', required=True)
    p.add_argument('--namespace', required=True)
    p.add_argument('--configmap', required=True)
    p.add_argument('--cluster-id', required=True)
    p.add_argument('--timeout', type=int, default=180)
    args = p.parse_args()
    def get(namespace, name):
        r = subprocess.run(['kubectl', '--kubeconfig', args.kubeconfig, '--request-timeout=15s',
                            'get', 'configmap', name, '-n', namespace, '--ignore-not-found', '-o', 'json'],
                           capture_output=True, text=True, timeout=25)
        if r.returncode:
            raise RuntimeError('Kubernetes ConfigMap read failed while waiting for CSI monitor propagation.')
        return json.loads(r.stdout) if r.stdout.strip() else {}
    wait(get, args.namespace, args.configmap, args.cluster_id, args.timeout)


if __name__ == '__main__':
    try: main()
    except Exception as error:
        print('Error: ' + str(error), file=sys.stderr); sys.exit(1)
