#!/usr/bin/env python3
"""Converge the configured kube-proxy image and verify control-plane versions."""
import argparse
import json
import re
import subprocess
import sys


def run(args, timeout=40):
    r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if r.returncode: raise RuntimeError('Kubernetes component reconciliation failed: ' + r.stderr.strip())
    return r.stdout


def reconcile_proxy(config, kube, execute=run):
    text = execute(kube + ['get', 'daemonset', 'kube-proxy', '-n', 'kube-system', '--ignore-not-found', '-o', 'json'])
    daemon = json.loads(text) if text.strip() else None
    if not config['enabled']:
        if daemon is not None:
            raise ValueError('Talos disables kube-proxy but its DaemonSet remains; review the networking migration explicitly.')
        return
    if daemon is None:
        raise ValueError('Talos enables kube-proxy but its DaemonSet is missing.')
    image = config.get('image')
    if not isinstance(image, str) or not image:
        raise ValueError('The generated Talos configuration has no explicit kube-proxy image.')
    containers = daemon['spec']['template']['spec']['containers']
    proxy = next((c for c in containers if c['name'] == 'kube-proxy'), None)
    if proxy is None: raise ValueError('Unexpected kube-proxy DaemonSet container layout.')
    if proxy['image'] != image:
        execute(kube + ['set', 'image', 'daemonset/kube-proxy', 'kube-proxy=' + image, '-n', 'kube-system'])
    execute(kube + ['rollout', 'status', 'daemonset/kube-proxy', '-n', 'kube-system', '--timeout=600s'], timeout=630)


def normalized(version):
    return version.lstrip('v').split('+', 1)[0]


def check_version_transition(current, desired):
    """Keep ordinary deployment from silently performing an unreviewed minor migration."""
    if not desired: return
    old = re.fullmatch(r'v?(\d+)\.(\d+)\.(\d+)(?:\+.*)?', current)
    new = re.fullmatch(r'v?(\d+)\.(\d+)\.(\d+)', desired)
    if not old or not new: raise ValueError('An explicit stable Kubernetes version is required for an in-place transition.')
    old_parts, new_parts = tuple(map(int, old.groups())), tuple(map(int, new.groups()))
    if old_parts[:2] != new_parts[:2]:
        raise ValueError('A Kubernetes minor-version transition needs a reviewed migration procedure; ordinary root apply only performs patch upgrades.')
    if new_parts < old_parts: raise ValueError('In-place Kubernetes downgrades are not supported; use an explicitly authorized recreation.')


def verify_control_planes(kube, version, execute=run):
    if not version: return
    nodes = json.loads(execute(kube + ['get', 'nodes', '-o', 'json']))['items']
    seen = 0
    for node in nodes:
        labels = node['metadata'].get('labels', {})
        if not any(key in labels for key in ('node-role.kubernetes.io/control-plane', 'node-role.kubernetes.io/master')): continue
        addresses = [a['address'] for a in node['status']['addresses'] if a['type'] == 'InternalIP']
        if not addresses: raise ValueError('Control-plane node has no internal API address.')
        address = addresses[0]
        if ':' in address: address = '[' + address + ']'
        actual = json.loads(execute(kube + ['--server=https://' + address + ':6443', 'get', '--raw', '/version']))['gitVersion']
        if normalized(actual) != normalized(version): raise ValueError('A control-plane API server is not running the desired version.')
        seen += 1
    if not seen: raise ValueError('No control-plane nodes were found for version verification.')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--kubeconfig', required=True); p.add_argument('--version', default='')
    p.add_argument('--check-transition', action='store_true')
    a = p.parse_args(); kube = ['kubectl', '--kubeconfig', a.kubeconfig, '--request-timeout=20s']
    if a.check_transition:
        current = json.loads(run(kube + ['get', '--raw', '/version']))['gitVersion']
        check_version_transition(current, a.version)
    else:
        config = json.load(sys.stdin)
        reconcile_proxy(config, kube)
        verify_control_planes(kube, a.version)
        print('Kube-proxy and control-plane API versions verified.')

if __name__ == '__main__':
    try: main()
    except Exception as exc:
        print('Error: ' + str(exc), file=sys.stderr); sys.exit(1)
