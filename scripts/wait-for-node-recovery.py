#!/usr/bin/env python3
"""Wait read-only for automatic recovery before entering planned maintenance."""
import argparse
import importlib.util
from pathlib import Path
import sys
import time

SPEC = importlib.util.spec_from_file_location('maintenance', Path(__file__).with_name('node-maintenance.py'))
MAINTENANCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MAINTENANCE)


def wait(kube, timeout):
    deadline = time.monotonic() + timeout
    last = None
    while True:
        nodes = kube.get(['nodes'])['items']
        fences = kube.get(['networkfences'])['items']
        pending = sorted(n['metadata']['name'] for n in nodes
                         if not MAINTENANCE.ready(n) or n.get('spec', {}).get('unschedulable')
                         or n['metadata'].get('annotations', {}).get(MAINTENANCE.STATE, '') not in ('', 'cooldown'))
        if nodes and not pending and not fences:
            print('Automatic node recovery completed; nodes are Ready and uncordoned, with no NetworkFences.')
            return
        status = (tuple(pending), len(fences))
        if status != last:
            print(f'Waiting for automatic recovery: {len(pending)} nodes, {len(fences)} NetworkFences.', flush=True)
            last = status
        if time.monotonic() >= deadline:
            raise ValueError('Automatic recovery remains incomplete; inspect CSI/controller errors without forcing fencing or attachments.')
        time.sleep(5)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--kubeconfig', required=True)
    p.add_argument('--timeout', type=int, default=600)
    args = p.parse_args()
    wait(MAINTENANCE.Kubernetes(args.kubeconfig), args.timeout)


if __name__ == '__main__':
    try: main()
    except Exception as error:
        print('Error: ' + str(error), file=sys.stderr); sys.exit(1)
