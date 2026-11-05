"""The API must be healthy and authenticated discovery must work."""
import os
from pathlib import Path
import re
import subprocess
import unittest

SOURCE = Path(__file__).resolve().parents[1].joinpath('deploy.sh').read_text()
FUNCTION = re.search(r'^wait_for_k8s_api_ready\(\) \{\n.*?^\}', SOURCE, re.M | re.S)[0]

class ApiReadinessTest(unittest.TestCase):
    def check(self, ready='ok', discovery='{"groups":[]}', failure='false', timeout=0):
        harness = r'''
set -euo pipefail
cluster_kubeconfig_path=unused
error() { echo "$*" >&2; }
sleep() { :; }
kubectl() {
  [[ "$FAILURE" != true ]] || return 1
  case "$*" in
    *'/readyz'*) printf '%s' "$READY" ;;
    *'/apis'*) printf '%s' "$DISCOVERY" ;;
    *) return 1 ;;
  esac
}
'''
        return subprocess.run(['bash','-c',harness+FUNCTION+f'\nwait_for_k8s_api_ready 192.0.2.1 {timeout}'],
            env={**os.environ,'READY':ready,'DISCOVERY':discovery,'FAILURE':failure},
            capture_output=True,text=True)

    def test_healthy_api_and_discovery_pass(self):
        result=self.check(timeout=5)
        self.assertEqual(result.returncode,0,result.stderr)

    def test_unhealthy_body_is_not_readiness(self):
        for body in ('not ready','503 Service Unavailable',''):
            self.assertNotEqual(self.check(ready=body).returncode,0)

    def test_failed_tls_or_http_request_blocks(self):
        self.assertNotEqual(self.check(failure='true').returncode,0)

    def test_discovery_failure_or_wrong_payload_blocks(self):
        for payload in ('Forbidden','{}','{"groups": null}'):
            self.assertNotEqual(self.check(discovery=payload).returncode,0)


class PrometheusReloadTest(unittest.TestCase):
    def check(self,mounted=True):
        function=re.search(r'^reconcile_prometheus_config\(\) \{\n.*?^\}',SOURCE,re.M|re.S)[0]
        harness='''set -euo pipefail
# A retry may start with the already-updated API hash, despite stale live config.
monitoring_prometheus_config_changed=false
wait_for_prometheus_config_hash() { [[ "$1" == desired && "$MOUNTED" == true ]]; }
reload_prometheus_config() { echo live-config-reloaded; }
'''
        return subprocess.run(['bash','-c',harness+function+'\nreconcile_prometheus_config desired'],
            env={**os.environ,'MOUNTED':str(mounted).lower()},capture_output=True,text=True)

    def test_retry_reloads_even_when_the_api_configmap_hash_did_not_change(self):
        result=self.check();self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('live-config-reloaded',result.stdout)

    def test_unmounted_config_is_not_reloaded(self):
        result=self.check(False);self.assertNotEqual(result.returncode,0)
        self.assertNotIn('live-config-reloaded',result.stdout)

if __name__=='__main__': unittest.main()
