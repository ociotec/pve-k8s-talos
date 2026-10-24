"""Check deployment privileges before worker VMs exist."""

import os
from pathlib import Path
import subprocess
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "deploy.sh"
FUNCTION = "validate_node_remediation_proxmox_access() {" + SCRIPT.read_text().split(
    "validate_node_remediation_proxmox_access() {", 1
)[1].split("\nvalidate_node_remediation_dedicated_proxmox_access() {", 1)[0]


class ProxmoxBootstrapPreflightTest(unittest.TestCase):
    def run_check(self, audit="1", admin="1", api_failure="false", workers="true"):
        harness = r'''
set -euo pipefail
cluster_k8s_net_constants_path=unused
skip_ceph=false
error() { echo "$*" >&2; }
message() { :; }
tf_bool_value() { echo true; }
collect_worker_vm_targets() {
  if [[ "$WORKERS" == true ]]; then
    echo 'worker-01|pve-01|101'
    echo 'worker-02|pve-02|102'
  fi
}
proxmox_api_request() {
  case "$2" in
    '/access/permissions?path=/')
      printf '{"data":{"/":{"Permissions.Modify":%s,"User.Modify":%s}}}' "$ADMIN" "$ADMIN" ;;
    '/access/permissions?path=/vms/'*)
      [[ "$API_FAILURE" != true ]] || { echo 'API unavailable' >&2; return 1; }
      local path="${2#*path=}"
      printf '{"data":{"%s":{"VM.Audit":%s}}}' "$path" "$AUDIT" ;;
    */status/current)
      echo 'HTTP 500: VM does not exist' >&2
      return 1 ;;
    *) echo 'Unexpected Proxmox request' >&2; return 1 ;;
  esac
}
'''
        return subprocess.run(
            ["bash", "-c", harness + FUNCTION + "\nvalidate_node_remediation_proxmox_access"],
            env={**os.environ, "AUDIT": audit, "ADMIN": admin,
                 "API_FAILURE": api_failure, "WORKERS": workers},
            capture_output=True, text=True,
        )

    def test_creation_is_allowed_with_permissions_and_no_existing_vms(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_audit_privilege_blocks(self):
        result = self.run_check(audit="0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("VM.Audit", result.stderr)

    def test_missing_identity_provisioning_privileges_blocks(self):
        result = self.run_check(admin="0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Permissions.Modify", result.stderr)

    def test_permissions_api_failure_blocks(self):
        result = self.run_check(api_failure="true")
        self.assertNotEqual(result.returncode, 0)

    def test_no_workers_blocks(self):
        result = self.run_check(workers="false")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no worker VM targets", result.stderr)


if __name__ == "__main__":
    unittest.main()
