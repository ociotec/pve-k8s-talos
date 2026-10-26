"""Validate real Talos patch merging, including settings lacking native equivalents."""
import importlib.util
import os
from pathlib import Path
import shutil
import sys
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('talos_patches', ROOT / 'scripts/prepare-talos-patches.py')
PATCHES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PATCHES)
IMAGE = 'factory.talos.dev/metal-installer/example:v1.14.4'
LEGACY = '''machine:
  nodeLabels:
    example.com/storage: s3
  install:
    grubUseUKICmdline: false
    extraKernelArgs: [ipv6.disable=1]
  network:
    nameservers: [192.0.2.53]
  kubelet:
    extraArgs: {max-pods: "160"}
    extraMounts:
      - source: /var/mnt/s3
        destination: /var/lib/s3
        type: bind
        options: [bind, rshared, rw]
cluster:
  discovery:
    registries:
      kubernetes: {disabled: false}
      service: {disabled: false, endpoint: https://discovery.example.com/}
  apiServer:
    resources:
      requests: {cpu: "1", memory: 1Gi}
      limits: {cpu: "1", memory: 1Gi}
  controllerManager:
    extraArgs: {node-cidr-mask-size: "24"}
  scheduler:
    resources:
      requests: {cpu: 100m, memory: 128Mi}
      limits: {cpu: 100m, memory: 128Mi}
'''

class TalosPatchFormatTest(unittest.TestCase):
    def test_legacy_generation_is_byte_identical_without_pyyaml(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            patch = root / 'machine-node.yaml'
            installer = root / 'qemu.yaml'
            patch.write_text(LEGACY)
            installer.write_text('machine:\n  install:\n    image: ' + IMAGE + '\n')
            before = {p.name: p.read_bytes() for p in [patch, installer]}
            result = subprocess.run([sys.executable, '-S', str(ROOT / 'scripts/prepare-talos-patches.py'),
                                     '--version', 'v1.13.5', '--patch-dir', str(root),
                                     '--kubernetes-version', 'v1.36.2', '--control-plane', 'node'],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(before, {p.name: p.read_bytes() for p in [patch, installer]})

    def test_native_fields_and_proxy_disabling_have_no_legacy_duplicates(self):
        source = ('machine:\n  install: {extraKernelArgs: []}\n'
                  '  kubelet: {extraMounts: [], extraArgs: {max-pods: "160"}}\n'
                  '  nodeLabels: {example.com/storage: s3}\n'
                  '  network: {nameservers: [192.0.2.53]}\n'
                  'cluster:\n  proxy: {disabled: true}\n'
                  '  discovery: {registries: {service: {endpoint: https://discovery.example.com/}}}\n')
        docs = list(yaml.safe_load_all(PATCHES.render(source, IMAGE, 'v1.36.5')))
        native = {d['kind']: d for d in docs if d.get('kind')}
        self.assertNotIn('kubelet', docs[0].get('machine', {}))
        self.assertNotIn('install', docs[0].get('machine', {}))
        self.assertEqual(native['KubeletConfig']['extraArgs'], {'max-pods': '160'})
        self.assertFalse(native['KubeProxyConfig']['enabled'])
        self.assertEqual(native['UnattendedInstallConfig']['installer']['image'], IMAGE)
        self.assertEqual(native['DiscoveryServiceConfig']['endpoint'], 'https://discovery.example.com/')
        self.assertNotIn('$patch', native['DiscoveryServiceConfig'])

    def test_worker_conversion_preserves_mounts_and_omits_control_plane_patches(self):
        docs = list(yaml.safe_load_all(PATCHES.render(LEGACY, IMAGE, 'v1.36.5', 'worker')))
        self.assertEqual(docs[0]['machine']['kubelet']['extraMounts'][0]['destination'], '/var/lib/s3')
        self.assertFalse(any(d.get('kind') in ['KubeAPIServerConfig', 'KubeControllerManagerConfig', 'KubeSchedulerConfig'] for d in docs))
        self.assertNotIn('apiServer', docs[0].get('cluster', {}))

    def test_unsupported_native_fields_fail_before_any_output_is_rewritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            a, b, installer = [root / n for n in ['machine-a.yaml', 'machine-b.yaml', 'qemu.yaml']]
            a.write_text(LEGACY)
            b.write_text('cluster: {apiServer: {unknownSetting: true}}\n')
            installer.write_text('machine: {install: {image: "' + IMAGE + '"}}\n')
            before = {p.name: p.read_bytes() for p in [a, b, installer]}
            with self.assertRaisesRegex(ValueError, 'Unsupported native fields'):
                PATCHES.prepare('v1.14.4', root, 'v1.36.5', {'a', 'b'})
            self.assertEqual(before, {p.name: p.read_bytes() for p in [a, b, installer]})

    @unittest.skipUnless(os.environ.get('TALOS_CONFIG_VALIDATOR'), 'Set TALOS_CONFIG_VALIDATOR for official CLI validation')
    def test_control_plane_resize_payload_validates_in_both_formats(self):
        spec = importlib.util.spec_from_file_location('resize_contract', ROOT / 'scripts/resize-control-planes.py')
        resize = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(resize)
        resources = {'requests': {'cpu': '1', 'memory': '1Gi'}, 'limits': {'cpu': '1', 'memory': '1Gi'}}
        patch = {'cluster': {field: {'resources': resources} for field in resize.COMPONENTS}}
        binary = os.environ['TALOS_CONFIG_VALIDATOR']
        for version in ['v1.13.5', 'v1.14.4']:
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                source, updated = [Path(directory) / n for n in ['source.yaml', 'updated.yaml']]
                command = lambda args: subprocess.run([binary, *args], capture_output=True, text=True, timeout=30)
                result = command(['gen', 'config', 'compatibility.example', 'https://192.0.2.10:6443',
                                  '--talos-version', version, '--kubernetes-version', '1.36.5',
                                  '--with-docs=false', '--with-examples=false', '--output-types', 'controlplane', '--output', str(source)])
                self.assertEqual(result.returncode, 0, result.stderr)
                payload = resize.resource_patch(source.read_text(), patch)
                result = command(['machineconfig', 'patch', str(source), '--patch', payload, '--output', str(updated)])
                self.assertEqual(result.returncode, 0, result.stderr)
                result = command(['validate', '--config', str(updated), '--mode', 'metal'])
                self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(os.environ.get('TALOS_CONFIG_VALIDATOR'), 'Set TALOS_CONFIG_VALIDATOR for official CLI validation')
    def test_complete_mixed_patch_is_accepted_after_conversion(self):
        binary = os.environ['TALOS_CONFIG_VALIDATOR']
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            original, patch, merged = [base / name for name in ['native.yaml', 'patch.yaml', 'merged.yaml']]
            run = lambda args: subprocess.run([binary, *args], capture_output=True, text=True, timeout=30)
            generated = run(['gen', 'config', 'compatibility.example', 'https://192.0.2.10:6443',
                             '--talos-version', 'v1.14.4', '--kubernetes-version', '1.36.5',
                             '--with-docs=false', '--with-examples=false', '--output-types', 'controlplane', '--output', str(original)])
            self.assertEqual(generated.returncode, 0, generated.stderr)
            patch.write_text(PATCHES.render(LEGACY, IMAGE, 'v1.36.5'))
            applied = run(['machineconfig', 'patch', str(original), '--patch', '@' + str(patch), '--output', str(merged)])
            self.assertEqual(applied.returncode, 0, applied.stderr)
            validated = run(['validate', '--config', str(merged), '--mode', 'metal'])
            self.assertEqual(validated.returncode, 0, validated.stderr)
            documents = list(yaml.safe_load_all(merged.read_text()))
            legacy = next(d for d in documents if d.get('kind') is None or d.get('kind') == 'Config')
            self.assertEqual(legacy['machine']['install']['extraKernelArgs'], ['ipv6.disable=1'])
            self.assertEqual(legacy['machine']['install']['image'], IMAGE)
            self.assertEqual(legacy['machine']['kubelet']['extraMounts'][0]['source'], '/var/mnt/s3')
            self.assertEqual(legacy['machine']['kubelet']['image'], 'ghcr.io/siderolabs/kubelet:v1.36.5')
            resolver = next(d for d in documents if d.get('kind') == 'ResolverConfig')
            self.assertEqual(resolver['nameservers'], [{'address': '192.0.2.53'}])

if __name__ == '__main__':
    unittest.main()
