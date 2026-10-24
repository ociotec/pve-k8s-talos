#!/usr/bin/env python3
"""Preinstall only missing CRDs from the configured operator chart, then let Helm own updates."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


def run(args, payload=None):
    result = subprocess.run(args, input=payload, capture_output=True, text=True, timeout=180)
    if result.returncode:
        raise RuntimeError('Command failed: ' + ' '.join(args[:3]) + '\n' + result.stderr.strip())
    return result.stdout


def verify_existing(obj, release, namespace):
    annotations = obj.get('metadata', {}).get('annotations', {})
    if (annotations.get('meta.helm.sh/release-name'), annotations.get('meta.helm.sh/release-namespace')) != (release, namespace):
        raise ValueError('Existing Grafana Operator CRD has unapproved ownership; refusing adoption.')
    if obj.get('spec', {}).get('names', {}).get('kind') == 'Grafana':
        if not any(v.get('name') == 'v1beta1' and v.get('served') for v in obj['spec'].get('versions', [])):
            raise ValueError('Existing Grafana CRD does not serve v1beta1; review its migration before deploying.')


def objects_from_stream(text):
    # kubectl releases differ: -o json may emit a List or adjacent JSON objects.
    decoder, objects = json.JSONDecoder(), []
    text = text.lstrip()
    while text:
        obj, end = decoder.raw_decode(text)
        objects.extend(obj.get('items', []) if obj.get('kind') == 'List' else [obj])
        text = text[end:].lstrip()
    return objects


def bootstrap(crds, kube, release='grafana-operator', namespace='monitoring', execute=run, apply=True):
    if not crds:
        raise ValueError('The pinned chart did not render any CRDs.')
    # Inspect the complete set before creating anything; foreign objects are never adopted.
    missing = []
    for obj in crds:
        name = obj['metadata']['name']
        existing = execute(kube + ['get', 'crd', name, '--ignore-not-found', '-o', 'json'])
        if existing.strip():
            verify_existing(json.loads(existing), release, namespace)
        else:
            missing.append(obj)
    if not apply:
        return len(missing)
    for obj in missing:
        obj = json.loads(json.dumps(obj))
        metadata = obj['metadata']
        metadata.setdefault('labels', {})['app.kubernetes.io/managed-by'] = 'Helm'
        metadata.setdefault('annotations', {}).update({
            'meta.helm.sh/release-name': release,
            'meta.helm.sh/release-namespace': namespace,
            'helm.sh/resource-policy': 'keep',
        })
        try:
            # Atomic create avoids mutating a foreign object created concurrently.
            execute(kube + ['create', '-f', '-'], json.dumps(obj))
        except RuntimeError:
            current = execute(kube + ['get', 'crd', metadata['name'], '-o', 'json'])
            verify_existing(json.loads(current), release, namespace)
    for obj in crds:
        execute(kube + ['wait', '--for=condition=Established', 'crd/' + obj['metadata']['name'], '--timeout=120s'])
    return len(missing)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--constants', required=True)
    parser.add_argument('--kubeconfig', required=True)
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    text = Path(args.constants).read_text()
    if not re.search(r'^\s*grafana_operator_enabled\s*=\s*true\s*$', text, re.M):
        return 0
    match = re.search(r'^\s*grafana_operator_chart_version\s*=\s*"([^"\n]+)"', text, re.M)
    version = match[1] if match else '5.25.0'
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?', version):
        raise ValueError('An explicit Grafana Operator chart version is required.')
    kube = ['kubectl', '--kubeconfig', args.kubeconfig, '--request-timeout=30s']
    rendered = run(['helm', 'template', 'grafana-operator', 'oci://ghcr.io/grafana/helm-charts/grafana-operator',
                    '--version', version, '--namespace', 'monitoring', '--include-crds',
                    '--set', 'crds.immutable=false'])
    # Let the existing Kubernetes client decode YAML; no new Python YAML dependency.
    items = objects_from_stream(run(kube + ['create', '--dry-run=client', '--validate=false', '-f', '-', '-o', 'json'], rendered))
    crds = [obj for obj in items if obj.get('kind') == 'CustomResourceDefinition']
    count = bootstrap(crds, kube, apply=not args.check_only)
    if args.check_only:
        print(f'Grafana Operator CRD inspection: {count} definitions missing from chart {version}; no changes applied.')
    else:
        print(f'Grafana Operator CRDs established; created {count} missing definitions from chart {version}.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as exc:
        print(f'Error: Grafana Operator CRD preflight failed: {exc}', file=sys.stderr)
        sys.exit(1)
