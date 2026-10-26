#!/usr/bin/env python3
"""Adapt generated patches to Talos 1.14 documents without dropping legacy-only settings."""
import argparse
import copy
import json
import os
from pathlib import Path
import re
import sys
import tempfile


def modern(version):
    match = re.match(r'^v?(\d+)\.(\d+)(?:\.|$)', version)
    if not match:
        raise ValueError('An explicit Talos version is required.')
    return tuple(map(int, match.groups())) >= (1, 14)


def render(source, image, kubernetes_version, role='controlplane'):
    import yaml  # Older contracts retain their original files and dependencies.
    documents = [d for d in yaml.safe_load_all(source) if d]
    legacy = next((d for d in documents if d.get('kind') in (None, 'Config')), None)
    if legacy is None:
        raise ValueError('Generated patch has no machine configuration document.')
    legacy = copy.deepcopy(legacy)
    machine = legacy.setdefault('machine', {})
    cluster = legacy.setdefault('cluster', {})
    emitted = {}

    def document(kind, **fields):
        key = (kind, fields.get('name'))
        value = emitted.setdefault(key, {'apiVersion': 'v1alpha1', 'kind': kind})
        value.update(fields)
        return value

    def delete(kind, **fields):
        document(kind, **fields)['$patch'] = 'delete'

    def fields(value, allowed, location):
        unknown = set(value) - set(allowed)
        if unknown:
            raise ValueError('Unsupported native fields at ' + location + ': ' + ', '.join(sorted(unknown)))

    network = machine.get('network', {})
    if 'nameservers' in network:
        document('ResolverConfig', nameservers=[{'address': address} for address in network.pop('nameservers')])
    search = {}
    if 'searchDomains' in network:
        search['domains'] = network.pop('searchDomains')
    if 'disableSearchDomain' in network:
        search['disableDefault'] = network.pop('disableSearchDomain')
    if search:
        document('ResolverConfig', searchDomains=search)
    features = machine.get('features', {})
    if 'hostDNS' in features:
        document('ResolverConfig', hostDNS=features.pop('hostDNS'))
    for old, new in [('nodeLabels', 'labels'), ('nodeAnnotations', 'annotations'), ('nodeTaints', 'taints')]:
        if old in machine:
            value = machine.pop(old)
            if value:
                document('KubeNodeConfig', **{new: value})

    kubelet = machine.pop('kubelet', None)
    if kubelet is not None:
        for key in ['skipNodeRegistration', 'registerWithFQDN', 'nodeIP']:
            if key in kubelet:
                document('KubeNodeConfig', **{key: kubelet.pop(key)})
        native_fields = {'image', 'extraArgs', 'extraConfig', 'clusterDNS', 'defaultRuntimeSeccompProfileEnabled'}
        # Talos 1.14 KubeletConfig.ExtraMounts() returns nil. Keep the supported
        # v1alpha1 block when custom mounts or other legacy-only settings exist.
        unsupported = set(kubelet) - native_fields - {'extraMounts', 'disableManifestsDirectory'}
        needs_legacy = bool(kubelet.get('extraMounts')) or bool(unsupported) or kubelet.get('disableManifestsDirectory') is False
        if needs_legacy:
            machine['kubelet'] = {
                'image': 'ghcr.io/siderolabs/kubelet:v' + kubernetes_version.lstrip('v'),
                'defaultRuntimeSeccompProfileEnabled': True,
                'disableManifestsDirectory': True,
                **kubelet,
            }
            delete('KubeletConfig')
        else:
            kubelet.pop('extraMounts', None)
            kubelet.pop('disableManifestsDirectory', None)
            if 'extraConfig' in kubelet:
                kubelet['config'] = kubelet.pop('extraConfig')
            if kubelet:
                document('KubeletConfig', **kubelet)

    install = machine.pop('install', {})
    if install.get('extraKernelArgs') == []:
        install.pop('extraKernelArgs')
    # UnattendedInstallConfig has no extraKernelArgs/grubUseUKICmdline fields.
    # Preserve those boot semantics and remove its conflicting default document.
    if set(install) - {'image', 'disk', 'wipe'}:
        if 'disk' not in install and 'diskSelector' not in install:
            install['disk'] = '/dev/sda'  # Same install-disk default as the Talos generator.
        machine['install'] = {'wipe': False, **install, 'image': image}
        delete('UnattendedInstallConfig')
    else:
        value = document('UnattendedInstallConfig', installer={'image': image})
        provisioning = {}
        if install.get('disk'):
            provisioning['diskSelector'] = {'match': 'disk.dev_path == ' + json.dumps(install['disk'])}
        if 'wipe' in install:
            provisioning['wipe'] = install['wipe']
        if provisioning:
            value['provisioning'] = provisioning

    discovery = cluster.pop('discovery', None)
    if discovery is not None:
        registries = discovery.get('registries', {})
        # DiscoveryServiceConfig cannot express Kubernetes-registry discovery.
        # Retain that existing behavior, with only one discovery configuration.
        if 'kubernetes' in registries or set(discovery) - {'enabled', 'registries'} or set(registries) - {'service'}:
            cluster['discovery'] = discovery
            delete('DiscoveryServiceConfig', name='default')
        else:
            service = registries.get('service', {})
            fields(service, {'disabled', 'endpoint'}, 'cluster.discovery.registries.service')
            if discovery.get('enabled') is False or service.get('disabled') is True:
                delete('DiscoveryServiceConfig', name='default')
            else:
                value = document('DiscoveryServiceConfig', name='default')
                if service.get('endpoint'):
                    value['endpoint'] = service['endpoint']

    components = {
        'apiServer': ('KubeAPIServerConfig', {'image', 'extraArgs', 'env', 'resources', 'apiPort', 'certExtraSANs', 'startupProbes'}),
        'controllerManager': ('KubeControllerManagerConfig', {'enabled', 'image', 'extraArgs', 'env', 'resources'}),
        'scheduler': ('KubeSchedulerConfig', {'enabled', 'image', 'extraArgs', 'env', 'resources', 'config'}),
    }
    for key, (kind, allowed) in components.items():
        value = cluster.pop(key, None)
        if value is not None and role == 'controlplane':
            fields(value, allowed, 'cluster.' + key)
            document(kind, **value)
    proxy = cluster.pop('proxy', None)
    if proxy is not None:
        fields(proxy, {'disabled', 'image', 'mode', 'extraArgs', 'resources', 'config'}, 'cluster.proxy')
        if 'disabled' in proxy:
            proxy['enabled'] = not proxy.pop('disabled')
        document('KubeProxyConfig', **proxy)

    for key in ['network', 'features']:
        if machine.get(key) == {}:
            machine.pop(key)
    for key in ['machine', 'cluster']:
        if legacy.get(key) == {}:
            legacy.pop(key)
    existing = [d for d in documents if d.get('kind') not in (None, 'Config')]
    collisions = {(d['kind'], d.get('name')) for d in existing} & set(emitted)
    if collisions:
        raise ValueError('Patch sets both legacy and native settings for the same component.')
    return yaml.safe_dump_all([legacy, *existing, *emitted.values()], sort_keys=False)


def atomic_write(path, text):
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix='.talos-patch-')
    try:
        with os.fdopen(descriptor, 'w') as file:
            file.write(text)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def prepare(version, directory, kubernetes_version, controlplanes):
    if not modern(version):
        return
    import yaml
    install = directory / 'qemu.yaml'
    image = yaml.safe_load(install.read_text())['machine']['install']['image']
    # Render everything before writing, so a conversion failure preserves all inputs.
    converted = {}
    for path in sorted(directory.glob('machine-*.yaml')):
        if path.is_symlink():
            raise ValueError('Generated machine patches must not be source symlinks.')
        name = path.stem.removeprefix('machine-')
        converted[path] = render(path.read_text(), image, kubernetes_version,
                                 'controlplane' if name in controlplanes else 'worker')
    for path, text in converted.items():
        atomic_write(path, text)
    atomic_write(install, '# Installer image is included in each version-aware machine patch.\nmachine: {}\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--patch-dir', type=Path, required=True)
    parser.add_argument('--kubernetes-version', required=True)
    parser.add_argument('--control-plane', nargs='*', default=[])
    args = parser.parse_args()
    try:
        prepare(args.version, args.patch_dir, args.kubernetes_version, set(args.control_plane))
    except Exception as exc:
        detail = str(exc) if isinstance(exc, ValueError) else 'Check generated YAML and the PyYAML installation.'
        print('Error: cannot prepare Talos patches: ' + detail, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
