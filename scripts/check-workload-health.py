#!/usr/bin/env python3
"""Reuse deployment workload baselines to prevent cumulative rolling-update degradation."""
import argparse
import importlib.util
from pathlib import Path
import sys

SPEC = importlib.util.spec_from_file_location('registry_health', Path(__file__).with_name('reconcile-registry-auth.py'))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--kubeconfig', required=True); p.add_argument('--baseline', required=True)
    p.add_argument('--capture', action='store_true'); p.add_argument('--timeout', type=int, default=900)
    a = p.parse_args()
    args = argparse.Namespace(kubeconfig=a.kubeconfig, talosconfig='', node_address='',
                              workload_baseline=a.baseline, timeout=a.timeout)
    checker = MODULE.Reconciler(args)
    path = Path(a.baseline)
    if a.capture and not path.exists():
        checker.capture_workload_baseline()
        path.chmod(0o600)
    if not path.exists(): raise ValueError('Workload baseline is missing; refusing to reset rollout health expectations.')
    checker.wait_workloads(wait=not a.capture)
    return 0


if __name__ == '__main__':
    try: sys.exit(main())
    except Exception as exc:
        print('Error: rolling workload health check failed: ' + str(exc), file=sys.stderr); sys.exit(1)
