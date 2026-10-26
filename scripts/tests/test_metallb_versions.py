"""Verify release-specific MetalLB probes and authenticated Prometheus discovery."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('metallb_releases', ROOT / 'scripts/prepare-infrastructure-manifests.py')
RELEASES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASES)

class MetalLBReleaseTest(unittest.TestCase):
    def test_modern_controller_executes_health_checks_in_its_own_network_namespace(self):
        documents = [copy.deepcopy(d) for d in yaml.safe_load_all((ROOT / 'k8s-net/metallb-native.yaml').read_text()) if d]
        workloads = [d for d in documents if d['kind'] in ['Deployment','DaemonSet']]
        RELEASES.modern_metallb(documents, 'busybox:example@sha256:'+'0'*64)
        controller = next(d for d in workloads if d['kind']=='Deployment')['spec']['template']['spec']
        container = controller['containers'][0]
        for name, endpoint in [('startupProbe','healthz'),('livenessProbe','healthz'),('readinessProbe','readyz')]:
            self.assertEqual(container[name]['exec']['command'][-1], 'http://127.0.0.1:17472/'+endpoint)
            self.assertNotIn('httpGet',container[name])
        init = controller['initContainers'][0]
        self.assertEqual(init['resources']['requests']['memory'],init['resources']['limits']['memory'])
        self.assertTrue(init['securityContext']['runAsNonRoot'])
        self.assertTrue(init['securityContext']['readOnlyRootFilesystem'])
        self.assertEqual(init['securityContext']['capabilities']['drop'],['ALL'])
        self.assertTrue(next(m for m in container['volumeMounts'] if m['name']=='health-probe')['readOnly'])
        for d in workloads:
            annotations=d['spec']['template']['metadata']['annotations']
            self.assertEqual((annotations['prometheus.io/port'],annotations['prometheus.io/scheme']),('9120','https'))
        role=next(d for d in documents if d['kind']=='ClusterRole' and d['metadata']['name']=='metallb-metrics-auth')
        self.assertEqual({r['resources'][0] for r in role['rules']},{'tokenreviews','subjectaccessreviews'})
        self.assertTrue(all(r['verbs']==['create'] for r in role['rules']))

    def test_new_helper_image_is_a_cluster_decision(self):
        with self.assertRaisesRegex(ValueError,'explicit metallb_probe_image'):
            RELEASES.modern_metallb([], '')

    @unittest.skipUnless(shutil.which('tofu'),'OpenTofu required')
    def test_legacy_http_and_modern_authenticated_https_configs(self):
        template=(ROOT/'monitoring/prometheus.yaml').read_text().split('data:\n  prometheus.yml: |',1)[1].split('\n---\n',1)[0]
        for enabled in [False,True]:
            with self.subTest(secure=enabled), tempfile.TemporaryDirectory() as directory:
                root=Path(directory);(root/'scrape.tpl').write_text(template)
                values={'ceph_prometheus_targets':[],'ceph_prometheus_scheme':'http','ceph_cluster_name':'example','ceph_namespace':'rook-ceph','metallb_secure_metrics':enabled,'metallb_metrics_server_name':'metallb-metrics.example.com'}
                (root/'main.tf').write_text('locals { config = templatefile("${path.module}/scrape.tpl", '+json.dumps(values)+') }\n')
                env={k:v for k,v in os.environ.items() if not k.startswith('TF_VAR_')}
                r=subprocess.run(['tofu','console','-no-color'],cwd=root,input='jsonencode(local.config)\n',capture_output=True,text=True,env=env,timeout=30)
                self.assertEqual(r.returncode,0,r.stderr)
                config=yaml.safe_load(json.loads(json.loads(r.stdout)))
                jobs={j['job_name']:j for j in config['scrape_configs']}
                generic=jobs['kubernetes-pods']['relabel_configs']
                drops=[r for r in generic if r.get('action')=='drop' and r.get('regex')=='metallb-system']
                self.assertEqual(bool(drops),enabled)
                if not enabled:
                    self.assertNotIn('metallb-https',jobs)
                    self.assertNotIn('authorization',jobs['kubernetes-pods'])
                else:
                    secure=jobs['metallb-https']
                    self.assertEqual(secure['scheme'],'https')
                    self.assertEqual(secure['authorization']['credentials_file'],'/var/run/secrets/kubernetes.io/serviceaccount/token')
                    self.assertNotIn('insecure_skip_verify',secure['tls_config'])
                    self.assertEqual(secure['tls_config']['server_name'],'metallb-metrics.example.com')
                    self.assertTrue(any(r.get('regex')=='metallb-system;metricshttps' for r in secure['relabel_configs']))

if __name__=='__main__':
    unittest.main()
