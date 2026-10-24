"""Exercise worker reconciliation without applying configuration to a cluster."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "deploy.sh"
SOURCE = SCRIPT.read_text()


def function(name):
    return re.search(r"^" + name + r"\(\) \{\n.*?^\}", SOURCE, re.M | re.S)[0]


class WorkerConfigTest(unittest.TestCase):
    def run_worker(self, **settings):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "worker.yaml").write_text("machine: {}\n")
            harness = r'''
set -euo pipefail
cluster_talosconfig_path=unused
error() { echo "$*" >&2; }
message() { :; }
require_cmd() { :; }
secondary_network_enabled() { return 0; }
collect_workers_with_secondary_network() { echo 'worker|pve|100|192.0.2.10|198.51.100.10'; }
secondary_network_machineconfig_path() { echo "$FIXTURES/worker.yaml"; }
node_has_staged_machineconfig() { [[ "$PENDING" == 1 || -f "$FIXTURES/staged" ]]; }
node_has_secondary_ip_active() {
  if [[ -f "$FIXTURES/applied" ]]; then return "$POST_IP_RESULT"; fi
  return "$IP_RESULT"
}
node_primary_default_route_ok() {
  if [[ -f "$FIXTURES/applied" ]]; then return "$POST_ROUTE_RESULT"; fi
  return "$ROUTE_RESULT"
}
node_machineconfig_matches_file() { [[ "$MATCHES" == 1 ]]; }
node_machineconfig_network_matches_file() { return "$NETWORK_RESULT"; }
node_machineconfig_apply_mode() {
  echo dry-run >> "$FIXTURES/calls"
  echo "$MODE"
  return "$DRY_RUN_RESULT"
}
wait_for_machineconfig_match() {
  echo verify >> "$FIXTURES/calls"
  return "$VERIFY_RESULT"
}
wait_for_node_ready() {
  echo ready >> "$FIXTURES/calls"
  [[ "$READY_RESULT" == 0 ]] || exit 1
}
talosctl() {
  case "$*" in
    *'--mode no-reboot'*)
      echo no-reboot >> "$FIXTURES/calls"
      touch "$FIXTURES/applied"
      return "$APPLY_RESULT" ;;
    *'--mode staged'*)
      echo staged >> "$FIXTURES/calls"
      touch "$FIXTURES/staged" ;;
    *) echo 'Unexpected Talos command' >&2; return 1 ;;
  esac
}
'''
            defaults = dict(PENDING="0", IP_RESULT="0", ROUTE_RESULT="0", MATCHES="0",
                            NETWORK_RESULT="0", MODE="no-reboot", DRY_RUN_RESULT="0",
                            APPLY_RESULT="0", VERIFY_RESULT="0", READY_RESULT="0",
                            POST_IP_RESULT="0", POST_ROUTE_RESULT="0")
            result = subprocess.run(
                ["bash", "-c", harness + function("stage_secondary_network_worker_configs")
                 + "\nstage_secondary_network_worker_configs"],
                env={**os.environ, **defaults, **settings, "FIXTURES": directory},
                capture_output=True, text=True,
            )
            calls = Path(directory, "calls")
            return result, calls.read_text().splitlines() if calls.exists() else []

    def test_compatible_change_is_applied_and_verified_without_staging(self):
        result, calls = self.run_worker()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["dry-run", "no-reboot", "verify", "ready"])

    def test_matching_config_is_untouched(self):
        result, calls = self.run_worker(MATCHES="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])

    def test_initial_network_network_changes_and_pending_configs_are_staged(self):
        for setting in [dict(IP_RESULT="1"), dict(ROUTE_RESULT="1"),
                        dict(NETWORK_RESULT="1"), dict(PENDING="1")]:
            with self.subTest(setting=setting):
                result, calls = self.run_worker(**setting)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, ["staged"])

    def test_explicit_reboot_requirement_is_staged(self):
        result, calls = self.run_worker(MODE="staged")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["dry-run", "staged"])

    def test_read_dry_run_apply_and_verification_errors_never_fall_back_to_staging(self):
        for setting in [dict(IP_RESULT="2"), dict(ROUTE_RESULT="2"),
                        dict(NETWORK_RESULT="2"), dict(DRY_RUN_RESULT="1"),
                        dict(APPLY_RESULT="1"), dict(VERIFY_RESULT="1"),
                        dict(READY_RESULT="1"), dict(POST_IP_RESULT="1"),
                        dict(POST_ROUTE_RESULT="1")]:
            with self.subTest(setting=setting):
                result, calls = self.run_worker(**setting)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("staged", calls)


class CompatibilityCheckTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("talosctl"), "Talos CLI is required for normalization")
    def test_real_talos_normalizes_multiple_documents(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory, "config.yaml")
            config.write_text("version: v1alpha1\nmachine:\n  network:\n    hostname: worker\n---\napiVersion: v1alpha1\nkind: LinkConfig\nname: eth1\nup: true\n")
            result = subprocess.run(
                ["bash", "-c", "set -euo pipefail\n" + function("machineconfig_network_signature")
                 + '\nmachineconfig_network_signature "$1"', "bash", str(config)],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("hostname: worker", result.stdout)
            self.assertIn("kind: LinkConfig", result.stdout)

    def run_mode(self, response, code=0):
        with tempfile.TemporaryDirectory() as directory:
            harness = r'''
set -euo pipefail
cluster_talosconfig_path=unused
error() { echo "$*" >&2; }
timeout() { shift 2; "$@"; }
talosctl() { printf '%s\n' "$RESPONSE"; return "$CODE"; }
'''
            return subprocess.run(
                ["bash", "-c", harness + function("node_machineconfig_apply_mode")
                 + "\nnode_machineconfig_apply_mode 192.0.2.10 unused"],
                env={**os.environ, "TMPDIR": directory, "RESPONSE": response, "CODE": str(code)},
                capture_output=True, text=True,
            )

    def test_only_explicit_successful_talos_decisions_are_accepted(self):
        for decision, mode in [("without", "no-reboot"), ("with", "staged")]:
            response = f"Dry run summary:\nApplied configuration {decision} a reboot (skipped in dry-run).\nConfig diff:\npassword: private-test-value"
            result = self.run_mode(response)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), mode)
            self.assertNotIn("private-test-value", result.stdout + result.stderr)
            failed = self.run_mode(response, code=1)
            self.assertNotEqual(failed.returncode, 0)
            self.assertNotIn("private-test-value", failed.stdout + failed.stderr)
        self.assertNotEqual(self.run_mode("unexpected output").returncode, 0)
        self.assertNotEqual(self.run_mode("connection unavailable", code=124).returncode, 0)

    def test_network_comparison_excludes_registry_but_preserves_network_and_extra_documents(self):
        config = "version: v1alpha1\nmachine:\n  network:\n    hostname: worker\n    interfaces:\n      - interface: eth1\n        addresses: [198.51.100.10/24]\n  registries:\n    config: {}\ncluster: {}\n"
        harness = r'''
set -euo pipefail
cluster_talosconfig_path=unused
error() { echo "$*" >&2; }
timeout() { shift 2; "$@"; }
talosctl() {
  if [[ "$1" == machineconfig ]]; then
    cat "$3"
  else
    printf '%s\n' "$CURRENT"
  fi
}
'''
        with tempfile.TemporaryDirectory() as directory:
            desired = Path(directory, "desired.yaml")
            for content, expected in [
                (config.replace("config: {}", "config: {registry.example.com: {}}"), 0),
                (config.replace("/24", "/25"), 1),
                (config.replace("eth1", "eth2"), 1),
                (config + "---\nkind: LinkConfig\nname: eth1\n", 1),
                ("version: v1alpha1\nmachine: {}\n", 2),
            ]:
                with self.subTest(content=content):
                    desired.write_text(content)
                    result = subprocess.run(
                        ["bash", "-c", harness + function("machineconfig_network_signature")
                         + "\n" + function("node_machineconfig_network_matches_file")
                         + '\nnode_machineconfig_network_matches_file 192.0.2.10 "$DESIRED"'],
                        env={**os.environ, "CURRENT": json.dumps({"spec": config}),
                             "DESIRED": str(desired), "TMPDIR": directory},
                        capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertEqual(result.stdout, "")


class StagedConfigReconciliationTest(unittest.TestCase):
    def run_reconcile(self, persistent="active configuration", api_result="0"):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, ".talos-bootstrap-complete").touch()
            Path(directory, "machineconfig-worker.yaml").write_text("machine:\n  type: worker\n")
            harness = r'''
set -euo pipefail
cluster_out_dir="$FIXTURES"
cluster_root_workspace="$FIXTURES"
cluster_talosconfig_path=unused
cluster_kubeconfig_path=unused
kubectl() { :; }
require_cmd() { :; }
error() { echo "$*" >&2; }
message() { :; }
first_controlplane_ip() { echo 192.0.2.1; }
cluster_node_name_ip_pairs() { echo 'worker|192.0.2.10'; }
timeout() { shift 2; "$@"; }
wait_for_all_kubernetes_nodes_ready() { :; }
talosctl() {
  case "$*" in
    *'get machineconfig -o json'*)
      [[ "$API_RESULT" == 0 ]] || return "$API_RESULT"
      printf '%s\n' "$CONFIGS" ;;
    *'reboot'*) echo 'Unexpected reboot of an already applied configuration' >&2; exit 99 ;;
    *) echo 'Unexpected Talos command' >&2; exit 98 ;;
  esac
}
'''
            configs = [{"metadata": {"id": "v1alpha1"}, "spec": "active configuration"}]
            if persistent is not None:
                configs.append({"metadata": {"id": "persistent"}, "spec": persistent})
            result = subprocess.run(
                ["bash", "-c", harness + function("node_has_staged_machineconfig") + "\n"
                 + function("reconcile_staged_talos_nodes") + "\nreconcile_staged_talos_nodes"],
                env={**os.environ, "FIXTURES": directory, "API_RESULT": api_result,
                     "CONFIGS": '\n'.join(json.dumps(c) for c in configs)},
                capture_output=True, text=True,
            )
            return result

    def test_persisted_active_config_does_not_trigger_a_reboot(self):
        result = self.run_reconcile()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_persistent_config_does_not_trigger_a_reboot(self):
        result = self.run_reconcile(persistent=None)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_different_persistent_config_still_triggers_reboot_reconciliation(self):
        result = self.run_reconcile(persistent="configuration requiring activation")
        self.assertEqual(result.returncode, 99, result.stderr)

    def test_config_lookup_error_stops_reconciliation(self):
        result = self.run_reconcile(api_result="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(result.returncode, 99)


if __name__ == "__main__":
    unittest.main()
