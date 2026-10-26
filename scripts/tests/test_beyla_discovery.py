"""Keep legacy discovery stable and explicitly include Kubernetes OAuth2 proxies."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("tofu"), "OpenTofu required")
class BeylaDiscoveryTest(unittest.TestCase):
    def test_explicit_proxy_discovery_is_opt_in(self):
        for enabled, workers_only in [(False, False), (True, False), (True, True)]:
            with self.subTest(enabled=enabled, workers_only=workers_only), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "beyla.tpl").write_text((ROOT / "monitoring/beyla.yaml").read_text())
                values = {
                    "beyla_image_tag": "3.39.1", "beyla_cpu_request": "100m",
                    "beyla_cpu_limit": "500m", "beyla_mem_request": "256Mi",
                    "beyla_mem_limit": "256Mi", "beyla_sampling_ratio": 0.1,
                    "beyla_oauth2_proxy_discovery_enabled": enabled, "beyla_config_hash": "example",
                    "beyla_workers_only": workers_only,
                }
                (root / "main.tf").write_text('locals { config = templatefile("${path.module}/beyla.tpl", ' + json.dumps(values) + ') }\n')
                env = {k: v for k, v in os.environ.items() if not k.startswith("TF_VAR_")}
                result = subprocess.run(["tofu", "console", "-no-color"], cwd=root, env=env,
                                        input="jsonencode(local.config)\n", capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                documents = list(yaml.safe_load_all(json.loads(json.loads(result.stdout))))
                config = yaml.safe_load(next(d for d in documents if d["kind"] == "ConfigMap")["data"]["beyla.yaml"])
                pod = next(d for d in documents if d["kind"] == "DaemonSet")["spec"]["template"]
                self.assertEqual("checksum/config" in pod["metadata"]["annotations"], enabled)
                self.assertEqual("affinity" in pod["spec"], workers_only)
                mounts = {item["mountPath"] for item in pod["spec"]["containers"][0]["volumeMounts"]}
                self.assertEqual("/sys/fs/bpf" in mounts, enabled)
                self.assertEqual("/sys/kernel/tracing" in mounts, enabled)
                if workers_only:
                    expressions = pod["spec"]["affinity"]["nodeAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]["nodeSelectorTerms"][0]["matchExpressions"]
                    self.assertEqual({item["key"] for item in expressions}, {"node-role.kubernetes.io/control-plane", "node-role.kubernetes.io/master"})
                    self.assertTrue(all(item["operator"] == "DoesNotExist" for item in expressions))
                if enabled:
                    self.assertEqual(config["discovery"]["default_exclude_services"], [])
                    self.assertEqual(config["discovery"]["default_exclude_instrument"], [])
                    self.assertEqual(config["discovery"]["instrument"], [{"k8s_container_name": "oauth2-proxy", "containers_only": True, "exports": ["traces"]}])
                else:
                    self.assertEqual(config["discovery"], {"instrument": [{"container_name": "oauth2-proxy", "containers_only": True, "exports": ["traces"]}]})


if __name__ == "__main__":
    unittest.main()
