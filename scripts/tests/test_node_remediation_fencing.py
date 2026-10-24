"""Exercise deploy.sh's read-only Ceph-skip preflight without a cluster."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "deploy.sh"
FUNCTION = SCRIPT.read_text().split(
    "validate_existing_node_remediation_fencing() {", 1
)[1].split("\nvalidate_node_remediation_proxmox_access() {", 1)[0]
FUNCTION = "validate_existing_node_remediation_fencing() {" + FUNCTION
HELPER = SCRIPT.read_text().split("rook_csi_resource_names() {", 1)[1].split("\nvalidate_existing_node_remediation_fencing() {", 1)[0]
FUNCTION = "rook_csi_resource_names() {" + HELPER + "\n" + FUNCTION


class FencingPreflightTest(unittest.TestCase):
    def setUp(self):
        deployment = {
            "metadata": {"generation": 2},
            "spec": {
                "replicas": 2,
                "template": {"spec": {"containers": [{"name": "csi-addons"}]}},
            },
            "status": {
                "observedGeneration": 2,
                "updatedReplicas": 2,
                "availableReplicas": 2,
            },
        }
        self.objects = {
            "crd": {
                "spec": {
                    "scope": "Cluster",
                    "versions": [{"name": "v1alpha1", "served": True}],
                },
                "status": {"conditions": [{"type": "Established", "status": "True"}]},
            },
            "configmap": {"data": {"CSI_ENABLE_CSIADDONS": "true"}},
            "operatorconfig": {"spec": {"driverSpecDefaults": {"deployCsiAddons": True}}},
            "controller": json.loads(json.dumps(deployment)),
            "provisioner": json.loads(json.dumps(deployment)),
            "daemonset": {
                "metadata": {"generation": 2},
                "spec": deployment["spec"],
                "status": {
                    "observedGeneration": 2,
                    "desiredNumberScheduled": 8,
                    "updatedNumberScheduled": 8,
                    "numberReady": 8,
                },
            },
            "secret": {"metadata": {"name": "rook-csi-rbd-provisioner"}},
            "csidriver": {"metadata": {"name": "rook-ceph.rbd.csi.ceph.com"}},
        }

    def run_check(self, enabled="true", missing="", rook_version="1.19.4"):
        with tempfile.TemporaryDirectory() as directory:
            for name, value in self.objects.items():
                Path(directory, name + ".json").write_text(json.dumps(value))
            harness = r'''
set -euo pipefail
cluster_kubeconfig_path=unused
cluster_ceph_constants_path=unused
error() { echo "$*" >&2; }
tf_bool_value() { echo "$ENABLED"; }
tf_string_value() { if [[ "$2" == "rook_version" ]]; then echo "$ROOK_VERSION"; fi; }
kubectl() {
  local key
  case "$*" in
    *"get crd "*) key=crd ;;
    *"get configmap "*) key=configmap ;;
    *"get operatorconfig.csi.ceph.io "*) key=operatorconfig ;;
    *"get deployment csi-addons-controller-manager"*) key=controller ;;
    *"get deployment csi-rbdplugin-provisioner"*|*"rbd.csi.ceph.com-ctrlplugin"*) key=provisioner ;;
    *"get daemonset "*) key=daemonset ;;
    *"get secret "*) key=secret ;;
    *"get csidriver "*) key=csidriver ;;
    *) echo "Unexpected Kubernetes command" >&2; return 1 ;;
  esac
  [[ "$key" != "$MISSING" ]] || return 1
  cat "$FIXTURES/$key.json"
}
'''
            import os

            result = subprocess.run(
                ["bash", "-c", harness + FUNCTION + "\nvalidate_existing_node_remediation_fencing"],
                env={**os.environ, "FIXTURES": directory, "ENABLED": enabled, "MISSING": missing, "ROOK_VERSION": rook_version},
                capture_output=True,
                text=True,
            )
            return result

    def test_modern_rook_uses_operator_config_and_separate_addons_nodes(self):
        self.objects["configmap"]["data"] = {}
        result = self.run_check(rook_version="1.21.0")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_modern_rook_disabled_addons_block_skip(self):
        self.objects["operatorconfig"]["spec"]["driverSpecDefaults"]["deployCsiAddons"] = False
        self.assertNotEqual(self.run_check(rook_version="1.21.0").returncode, 0)

    def test_healthy_dependencies_allow_skip(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_disabled_desired_or_deployed_addons_block(self):
        self.assertNotEqual(self.run_check(enabled="false").returncode, 0)
        self.objects["configmap"]["data"]["CSI_ENABLE_CSIADDONS"] = "false"
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_missing_dependencies_or_api_errors_block(self):
        for name in self.objects:
            with self.subTest(resource=name):
                version = "1.21.0" if name == "operatorconfig" else "1.19.4"
                self.assertNotEqual(self.run_check(missing=name, rook_version=version).returncode, 0)

    def test_unserved_crd_blocks(self):
        self.objects["crd"]["spec"]["versions"][0]["served"] = False
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_stale_rollout_blocks(self):
        for name in ("controller", "provisioner", "daemonset"):
            with self.subTest(resource=name):
                self.objects[name]["status"]["observedGeneration"] = 1
                self.assertNotEqual(self.run_check().returncode, 0)
                self.objects[name]["status"]["observedGeneration"] = 2

    def test_unready_or_missing_sidecars_block(self):
        for name in ("provisioner", "daemonset"):
            with self.subTest(resource=name):
                self.objects[name]["spec"]["template"]["spec"]["containers"] = []
                self.assertNotEqual(self.run_check().returncode, 0)
                self.objects[name]["spec"]["template"]["spec"]["containers"] = [{"name": "csi-addons"}]
        self.objects["daemonset"]["status"]["numberReady"] = 7
        self.assertNotEqual(self.run_check().returncode, 0)


if __name__ == "__main__":
    unittest.main()
