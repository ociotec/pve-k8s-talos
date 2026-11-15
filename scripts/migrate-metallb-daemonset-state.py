#!/usr/bin/env python3
"""Hand existing MetalLB DaemonSets from manifest state to guarded server-side apply."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def execute(command, payload=None):
    result = subprocess.run(command, input=payload, capture_output=True, text=True, timeout=120)
    if result.returncode:
        # Do not echo state or configuration diagnostics, which may contain secrets.
        summaries = [line.strip() for line in result.stderr.splitlines() if line.startswith('Error:')]
        raise RuntimeError(f'{Path(command[0]).name} failed: ' + '; '.join(summaries))
    return result.stdout


def value(attribute):
    return attribute.get('value', attribute) if isinstance(attribute, dict) else {}


def candidates(state, desired):
    identities = {(m['metadata']['namespace'], m['metadata']['name']): m for m in desired}
    result = []
    for resource in state.get('resources', []):
        if resource.get('module') or resource.get('mode') != 'managed' or resource.get('type') != 'kubernetes_manifest' or resource.get('name') != 'metallb_native':
            continue
        for instance in resource.get('instances', []):
            manifest = value(instance.get('attributes', {}).get('manifest', {}))
            if manifest.get('kind') != 'DaemonSet':
                continue
            metadata = manifest['metadata']
            identity = (metadata.get('namespace'), metadata.get('name'))
            if identity not in identities or identity[0] != 'metallb-system':
                raise ValueError('Existing MetalLB DaemonSet is absent from the desired inventory; refusing state handoff.')
            address = 'kubernetes_manifest.metallb_native[' + json.dumps(instance['index_key']) + ']'
            result.append((address, instance, identities[identity]))
    return result


def verify_live(instance, desired, live):
    before = value(instance['attributes'].get('object', {}))
    metadata = live.get('metadata', {})
    for key in ['name', 'namespace']:
        if metadata.get(key) != desired['metadata'][key]:
            raise ValueError('Live DaemonSet identity differs from the desired object.')
    uid = before.get('metadata', {}).get('uid')
    if uid and uid != metadata.get('uid'):
        raise ValueError('Live DaemonSet UID differs from state; refusing handoff.')
    if live.get('spec', {}).get('selector') != desired['spec']['selector']:
        raise ValueError('MetalLB DaemonSet selector changes require a separate migration.')


def handoff(workspace, kubeconfig, cluster, apply=False, run=execute):
    if not (workspace / 'terraform.tfstate').is_file():
        return 0
    tofu = ['tofu', '-chdir=' + str(workspace)]
    state = json.loads(run(tofu + ['state', 'pull']))
    # Resolve the exact release-specific inventory without parsing HCL or YAML.
    expression = 'jsonencode(local.metallb_native_daemonsets)\n'
    desired = json.loads(json.loads(run(tofu + ['console', '-no-color'], expression)))
    selected = candidates(state, desired)
    if not selected:
        return 0
    for address, instance, manifest in selected:
        metadata = manifest['metadata']
        live = json.loads(run(['kubectl', '--kubeconfig', str(kubeconfig), '--request-timeout=30s',
                               '-n', metadata['namespace'], 'get', 'daemonset', metadata['name'], '-o', 'json']))
        verify_live(instance, manifest, live)
    if not apply:
        return len(selected)
    git_dir = Path(run(['git', '-C', str(cluster), 'rev-parse', '--absolute-git-dir']).strip())
    directory = git_dir / 'metallb-daemonset-handoffs'
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    with tempfile.NamedTemporaryFile(mode='w', prefix=timestamp + '-', suffix='.json', dir=directory, delete=False) as backup:
        os.chmod(backup.name, 0o600)
        json.dump(state, backup)
    # Native state rm takes the normal OpenTofu lock and never deletes live objects.
    run(tofu + ['state', 'rm', '-lock-timeout=60s', '-backup=' + backup.name + '.before',
                *[address for address, _, _ in selected]])
    print(f'MetalLB state handoff completed for {len(selected)} DaemonSet(s); private backup saved under the cluster Git directory.')
    return len(selected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', required=True, type=Path)
    parser.add_argument('--kubeconfig', required=True, type=Path)
    parser.add_argument('--cluster-dir', required=True, type=Path)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    count = handoff(args.workspace.resolve(), args.kubeconfig.resolve(), args.cluster_dir.resolve(), args.execute)
    if not args.execute:
        print(f'MetalLB state handoff inspection: {count} DaemonSet(s); no changes applied.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(f'Error: MetalLB state handoff failed: {error}', file=sys.stderr)
        sys.exit(1)
