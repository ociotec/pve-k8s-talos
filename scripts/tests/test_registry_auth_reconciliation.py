"""Exercise CRI activation and kubelet pull checks without accessing a cluster."""

import argparse
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("registry_auth", ROOT / "scripts/reconcile-registry-auth.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FakeReconciler(MODULE.Reconciler):
    def __init__(self):
        super().__init__(argparse.Namespace(
            node_name="worker-a", node_address="192.0.2.10", talosconfig="unused",
            kubeconfig="unused", timeout=10, probe_image=MODULE.PROBE_IMAGE, allow_node_reboot=True,
        ))
        self.file = {
            "metadata": {"updated": "2026-01-01T00:00:02Z", "version": 2},
            "spec": {"contents": '[plugins."io.containerd.cri.v1.images".registry.configs."registry.example.com".auth]\n'
                                  'username = "test-user"\npassword = "test-password"\n'},
        }
        self.process = {"metadata": {"updated": "2026-01-01T00:00:03Z"}, "spec": {"pid": 100}}
        self.node_data = {
            "metadata": {"name": "worker-a", "annotations": {}},
            "status": {"nodeInfo": {"bootID": "boot-a"},
                       "conditions": [{"type": "Ready", "status": "True"}]},
        }
        self.workloads = [{
            "metadata": {"uid": "pod-a"},
            "status": {"containerStatuses": [{"name": "app", "restartCount": 0,
                                               "containerID": "containerd://original", "state": {"running": {}}}]},
        }]
        self.calls = []
        self.probe = None
        self.fail_pull = False
        self.transient_pull = False
        self.file_id = MODULE.FILE_ID
        self.inject_secret = False
        self.move_probe = False
        self.fail_cleanup = False
        self.disrupt = None
        self.healthy = True
        self.materialized = True
        self.disk_matches = True
        self.fail_restart = False
        self.stuck_restart = False
        self.fail_pod_create = False
        self.rotate_during_restart = False
        self.rotate_during_probe = False

    def command(self, args, payload=None, raw=False, timeout=45):
        if args[0] == "talosctl":
            op = args[args.index("-n") + 2:]
            if op[0] == "reboot":
                self.calls.append("reboot")
                if self.fail_restart:
                    raise MODULE.ReconcileError("Simulated reboot error.")
                if not self.stuck_restart:
                    self.node_data["status"]["nodeInfo"]["bootID"] = "boot-b"
                    self.process["spec"]["pid"] += 1
                    self.process["metadata"]["updated"] = (
                        MODULE.timestamp(self.file["metadata"]["updated"]) + MODULE.datetime.timedelta(seconds=1)
                    ).isoformat().replace("+00:00", "Z")
                if self.rotate_during_restart:
                    self.file["metadata"].update(updated="2026-01-01T00:00:04Z", version=3)
                if self.disrupt == "container":
                    self.workloads[0]["status"]["containerStatuses"][0]["containerID"] = "containerd://changed"
                if self.disrupt == "boot":
                    self.node_data["status"]["nodeInfo"]["bootID"] = "boot-b"
                return ""
            if op[0] == "read":
                if op[1] != "/etc/" + self.file_id:
                    raise MODULE.ReconcileError("Unexpected CRI file path.")
                return self.file["spec"]["contents"] if self.disk_matches else "not materialized"
            kind = op[1]
            if kind == "etcfilespecs.files.talos.dev":
                if op[2] != self.file_id:
                    raise MODULE.ResourceNotFoundError("Talos resource not found.")
                return copy.deepcopy(self.file)
            if kind == "etcfilestatuses.files.talos.dev":
                return {"spec": {"specVersion": str(self.file["metadata"]["version"]) if self.materialized else "1"}}
            if kind == "servicepids":
                return copy.deepcopy(self.process)
            if kind == "services":
                return {"spec": {"running": True, "healthy": self.healthy, "unknown": False}}
        else:
            op = args[args.index("--request-timeout=20s") + 1:]
            if op[:2] == ["get", "node"]:
                return copy.deepcopy(self.node_data)
            if op[:2] == ["get", "deployments,statefulsets,daemonsets"]:
                return {"items": []}
            if op[0] in {"drain", "taint", "cordon", "uncordon"}:
                self.calls.append(op[0])
                return ""
            if op[:2] == ["get", "pods"]:
                return {"items": copy.deepcopy(self.workloads)}
            if op[0] == "create":
                self.calls.append("create-" + payload["kind"])
                if payload["kind"] == "ServiceAccount":
                    self.account = copy.deepcopy(payload)
                    return payload
                if self.fail_pod_create:
                    raise MODULE.ReconcileError("Simulated Pod creation error.")
                self.probe = copy.deepcopy(payload)
                if self.rotate_during_probe:
                    self.file["metadata"].update(updated="2026-01-01T00:00:04Z", version=3)
                if self.inject_secret:
                    self.probe["spec"]["imagePullSecrets"] = [{"name": "injected"}]
                if self.move_probe:
                    self.probe["spec"]["nodeName"] = "different-node"
                self.probe["status"] = {"containerStatuses": [{
                    "ready": not self.fail_pull,
                    "state": {"waiting": {"reason": "ImagePullBackOff"}} if self.fail_pull else {"running": {}},
                }]}
                if self.transient_pull:
                    self.probe["status"]["containerStatuses"][0]["state"]["waiting"]["message"] = "DeadlineExceeded: timeout awaiting response headers"
                return self.probe
            if op[:2] == ["get", "pod"]:
                if self.transient_pull:
                    self.probe["status"] = {"containerStatuses": [{"ready": True, "state": {"running": {}}}]}
                return self.probe
            if op[0] == "delete":
                self.calls.append("delete-" + op[1])
                if self.fail_cleanup and op[1] == "pod":
                    raise MODULE.ReconcileError("Simulated cleanup error.")
                return ""
            if op[0] == "annotate":
                self.calls.append("annotate")
                key, sep, value = op[3].partition("=")
                if sep:
                    self.node_data["metadata"]["annotations"][key] = value
                else:
                    self.node_data["metadata"]["annotations"].pop(key.rstrip("-"), None)
                return ""
        raise AssertionError("Unexpected command shape")


class ReconcileTest(unittest.TestCase):
    def setUp(self):
        self.sleep = patch.object(MODULE.time, "sleep").start()
        self.stdout = patch("sys.stdout", new_callable=io.StringIO).start()
        self.addCleanup(patch.stopall)
        self.r = FakeReconciler()

    def pending(self):
        self.r.process["metadata"]["updated"] = "2026-01-01T00:00:01Z"
        self.r.node_data["metadata"]["annotations"][MODULE.MAINTENANCE] = "true"

    def test_legacy_registry_fragment_remains_supported(self):
        current = self.r.runtime()
        self.assertEqual(current["file_id"], MODULE.FILE_ID)
        self.assertFalse(current["automatic_reload"])
        self.assertTrue(current["has_auth"])

    def test_merged_config_is_used_when_the_legacy_resource_is_absent(self):
        self.r.file_id = "cri/conf.d/cri.toml"
        current = self.r.runtime()
        self.assertEqual(current["file_id"], self.r.file_id)
        self.assertTrue(current["automatic_reload"])
        self.assertTrue(current["has_auth"])
        self.r.reconcile()
        self.assertIn("create-Pod", self.r.calls)
        self.assertNotIn("reboot", self.r.calls)

    def test_merged_config_waits_for_automatic_reload_without_draining(self):
        self.r.file_id = "cri/conf.d/cri.toml"
        self.r.process["metadata"]["updated"] = "2026-01-01T00:00:01Z"
        self.sleep.side_effect = lambda _: self.r.process["metadata"].update(
            updated="2026-01-01T00:00:03Z")
        self.r.reconcile()
        self.assertIn("create-Pod", self.r.calls)
        self.assertNotIn("drain", self.r.calls)
        self.assertNotIn("reboot", self.r.calls)

    def test_automatic_reload_timeout_never_touches_a_node(self):
        self.r.file_id = "cri/conf.d/cri.toml"
        self.r.process["metadata"]["updated"] = "2026-01-01T00:00:01Z"
        with patch.object(MODULE.time, "monotonic", side_effect=range(30)):
            with self.assertRaisesRegex(MODULE.ReconcileError, "automatic CRI reload"):
                self.r.reconcile()
        self.assertEqual(self.r.calls, [])

    def test_resource_access_errors_do_not_fall_back_to_another_file(self):
        original = self.r.talos_resource
        requested = []
        def resource(kind, resource_id):
            requested.append(resource_id)
            if kind == "etcfilespecs.files.talos.dev":
                raise MODULE.ReconcileError("Simulated permission or transport error.")
            return original(kind, resource_id)
        self.r.talos_resource = resource
        with self.assertRaisesRegex(MODULE.ReconcileError, "permission or transport"):
            self.r.runtime()
        self.assertEqual(requested, [MODULE.FILE_ID])
        self.assertEqual(self.r.calls, [])

    def test_missing_both_supported_files_is_an_error(self):
        self.r.file_id = "unsupported/config.toml"
        with self.assertRaisesRegex(MODULE.ReconcileError, "No supported CRI"):
            self.r.runtime()
        self.assertEqual(self.r.calls, [])

    def test_pending_credentials_require_explicit_permission(self):
        self.pending()
        self.r.args.allow_node_reboot = False
        with self.assertRaisesRegex(MODULE.ReconcileError, "explicitly enable"):
            self.r.reconcile()
        self.assertEqual(self.r.calls, [])

    def test_pending_node_requires_cluster_preflight_protection(self):
        self.pending()
        self.r.node_data["metadata"]["annotations"].clear()
        with self.assertRaisesRegex(MODULE.ReconcileError, "protected"):
            self.r.reconcile()
        self.assertEqual(self.r.calls, [])

    def test_rolling_reboot_validates_before_releasing_and_is_idempotent(self):
        self.pending()
        self.r.reconcile()
        self.assertEqual(self.r.calls[:4], ["drain", "reboot", "create-ServiceAccount", "create-Pod"])
        self.assertLess(self.r.calls.index("delete-serviceaccount"), self.r.calls.index("uncordon"))
        self.assertNotIn(MODULE.MAINTENANCE, self.r.node_data["metadata"]["annotations"])
        self.r.calls.clear()
        self.r.reconcile()
        self.assertEqual(self.r.calls, [])
        self.assertNotIn("test-password", str(self.r.node_data) + self.stdout.getvalue())

    def test_failed_probe_retains_protection_and_resume_does_not_reboot_again(self):
        self.pending()
        self.r.fail_pull = True
        with self.assertRaisesRegex(MODULE.ReconcileError, "ImagePullBackOff"):
            self.r.reconcile()
        self.assertNotIn("uncordon", self.r.calls)
        self.assertEqual(self.r.node_data["metadata"]["annotations"][MODULE.MAINTENANCE], "true")
        self.r.fail_pull = False
        self.r.reconcile()
        self.assertEqual(self.r.calls.count("reboot"), 1)
        self.assertIn("uncordon", self.r.calls)

    def test_already_loaded_unvalidated_auth_only_runs_a_probe(self):
        self.r.process["metadata"]["updated"] = "2026-01-01T00:00:03Z"
        self.r.reconcile()
        self.assertNotIn("restart", self.r.calls)
        self.assertIn("annotate", self.r.calls)

    def test_transient_registry_timeout_allows_kubelet_to_retry(self):
        self.r.fail_pull = True
        self.r.transient_pull = True
        self.r.reconcile()
        self.assertEqual(self.r.calls.count("create-Pod"), 1)
        self.assertIn("annotate", self.r.calls)
        self.assertNotIn("reboot", self.r.calls)

    def test_transient_pull_retry_still_has_a_deadline_and_cleans_up(self):
        self.r.fail_pull = self.r.transient_pull = True
        with patch.object(MODULE.time, "monotonic", side_effect=[0, 11]):
            with self.assertRaisesRegex(MODULE.ReconcileError, "Timed out"):
                self.r.pull_probe()
        self.assertIn("delete-pod", self.r.calls)
        self.assertIn("delete-serviceaccount", self.r.calls)
        self.assertNotIn("annotate", self.r.calls)

    def test_authentication_failure_is_not_retried_as_a_timeout(self):
        pod = {"status": {"containerStatuses": [{"state": {"waiting": {
            "message": "unauthorized; previous request timeout"}}}]}}
        self.assertFalse(self.r.transient_pull_failure(pod))

    def test_backoff_uses_only_the_same_pods_timeout_events(self):
        pod = {"metadata": {"uid": "probe-uid"}, "status": {"containerStatuses": [
            {"state": {"waiting": {"message": "Back-off pulling image"}}}]}}
        with patch.object(self.r, "command", return_value={"items": [{"message": "timeout awaiting response headers"}]}) as command:
            self.assertTrue(self.r.transient_pull_failure(pod))
        self.assertIn("involvedObject.uid=probe-uid", command.call_args.args[0])

    def test_no_auth_and_no_pending_change_does_nothing(self):
        self.r.file["spec"]["contents"] = '[plugins."io.containerd.cri.v1.images".registry]\n'
        self.r.process["metadata"]["updated"] = "2026-01-01T00:00:03Z"
        self.r.reconcile()
        self.assertEqual(self.r.calls, [])

    def test_probe_requires_node_credentials_and_resources_for_regular_container(self):
        self.r.reconcile()
        spec = self.r.probe["spec"]
        self.assertEqual(spec["nodeName"], "worker-a")
        self.assertEqual(spec["imagePullSecrets"], [])
        self.assertFalse(spec["automountServiceAccountToken"])
        self.assertNotIn("imagePullSecrets", self.r.account)
        self.assertEqual(spec["priorityClassName"], "infra-observability")
        self.assertEqual(spec["tolerations"], [{"operator": "Exists"}])
        container = spec["containers"][0]
        self.assertEqual(container["imagePullPolicy"], "Always")
        self.assertEqual(container["resources"]["requests"]["memory"], container["resources"]["limits"]["memory"])
        for resource in ["requests", "limits"]:
            self.assertIn("cpu", container["resources"][resource])

    def test_admission_injected_secret_cannot_produce_a_false_success(self):
        self.r.inject_secret = True
        with self.assertRaisesRegex(MODULE.ReconcileError, "Admission changed"):
            self.r.reconcile()
        self.assertNotIn("annotate", self.r.calls)
        self.assertEqual(self.r.calls[-2:], ["delete-pod", "delete-serviceaccount"])

    def test_admission_cannot_move_probe_to_a_different_node(self):
        self.r.move_probe = True
        with self.assertRaisesRegex(MODULE.ReconcileError, "Admission changed"):
            self.r.reconcile()
        self.assertNotIn("annotate", self.r.calls)

    def test_creation_and_cleanup_failures_never_mark_validation(self):
        for flag in ["fail_pod_create", "fail_cleanup"]:
            with self.subTest(flag=flag):
                r = FakeReconciler()
                setattr(r, flag, True)
                with self.assertRaises(MODULE.ReconcileError):
                    r.reconcile()
                self.assertEqual(r.calls[-2:], ["delete-pod", "delete-serviceaccount"])
                self.assertNotIn("annotate", r.calls)

    def test_unhealthy_or_unmaterialized_runtime_is_not_mutated(self):
        for flag in ["healthy", "materialized", "disk_matches"]:
            with self.subTest(flag=flag):
                r = FakeReconciler()
                setattr(r, flag, False)
                with self.assertRaises(MODULE.ReconcileError):
                    r.reconcile()
                self.assertEqual(r.calls, [])

    def test_reboot_errors_and_timeouts_never_release(self):
        self.pending()
        self.r.fail_restart = True
        with self.assertRaises(MODULE.ReconcileError):
            self.r.reconcile()
        self.assertEqual(self.r.calls, ["drain", "reboot"])
        self.r.fail_restart = False
        self.r.stuck_restart = True
        with patch.object(MODULE.time, "monotonic", side_effect=range(30)):
            with self.assertRaisesRegex(MODULE.ReconcileError, "did not reboot"):
                self.r.reconcile()
        self.assertNotIn("uncordon", self.r.calls)

    def test_new_credentials_already_loaded_after_external_restart_are_revalidated(self):
        self.r.reconcile()
        self.r.file["metadata"].update(updated="2026-01-01T00:00:04Z", version=3)
        self.r.file["spec"]["contents"] += '# credential rotation\n'
        self.r.process["metadata"]["updated"] = "2026-01-01T00:00:05Z"
        self.r.reconcile()
        self.assertEqual(self.r.calls.count("reboot"), 0)
        self.assertEqual(self.r.calls.count("create-Pod"), 2)

    def test_concurrent_registry_changes_never_mark_success(self):
        self.r.rotate_during_probe = True
        with self.assertRaisesRegex(MODULE.ReconcileError, "changed during"):
            self.r.reconcile()
        self.assertNotIn("annotate", self.r.calls)

    def test_registry_content_change_during_reboot_stops(self):
        self.pending()
        original = self.r.command
        def command(args, *a, **kw):
            result = original(args, *a, **kw)
            if "reboot" in args:
                self.r.file["spec"]["contents"] += "# concurrent rotation"
            return result
        self.r.command = command
        with self.assertRaisesRegex(MODULE.ReconcileError, "changed during"):
            self.r.reconcile()
        self.assertNotIn("uncordon", self.r.calls)

    def test_cleanup_failure_preserves_the_original_pull_error(self):
        self.r.fail_pull = self.r.fail_cleanup = True
        with self.assertRaisesRegex(MODULE.ReconcileError, "ImagePullBackOff.*clean up"):
            self.r.reconcile()
        self.assertNotIn("annotate", self.r.calls)

    def test_missing_timestamps_fail_closed(self):
        self.r.process["metadata"]["updated"] = "not-a-date"
        with self.assertRaisesRegex(MODULE.ReconcileError, "timestamp"):
            self.r.reconcile()
        self.assertEqual(self.r.calls, [])

    def test_command_errors_do_not_print_configuration_contents(self):
        result = subprocess.CompletedProcess([], 1, stdout="test-password", stderr="test-password")
        with patch.object(MODULE.subprocess, "run", return_value=result):
            with self.assertRaises(MODULE.ReconcileError) as error:
                MODULE.Reconciler(self.r.args).command(["talosctl", "read", "/unused"])
        self.assertNotIn("test-password", str(error.exception))

    def test_only_a_real_notfound_response_allows_resource_fallback(self):
        for code in ["NotFound", "PermissionDenied", "Unavailable"]:
            with self.subTest(code=code):
                stderr = f"rpc error: code = {code} desc = test-password"
                if code == "Unavailable":
                    stderr += " upstream code = NotFound"
                result = subprocess.CompletedProcess([], 1, stdout="", stderr=stderr)
                with patch.object(MODULE.subprocess, "run", return_value=result):
                    with self.assertRaises(MODULE.ReconcileError) as error:
                        MODULE.Reconciler(self.r.args).talos_resource(
                            "etcfilespecs.files.talos.dev", MODULE.FILE_ID)
                self.assertEqual(isinstance(error.exception, MODULE.ResourceNotFoundError),
                                 code == "NotFound")
                self.assertNotIn("test-password", str(error.exception))

    def test_drain_uses_evictions_and_never_forces_unmanaged_pods(self):
        self.pending()
        original = self.r.command
        seen = []
        def command(args, *a, **kw):
            seen.append(args)
            return original(args, *a, **kw)
        self.r.command = command
        self.r.reconcile()
        drain = next(args for args in seen if "drain" in args)
        self.assertIn("--delete-emptydir-data", drain)
        self.assertNotIn("--force", drain)
        self.assertNotIn("--disable-eviction", drain)
        self.assertFalse(any("service" in args for args in seen))

    def test_failed_drain_never_reboots_or_releases(self):
        self.pending()
        original = self.r.command
        def command(args, *a, **kw):
            if "drain" in args:
                raise MODULE.ReconcileError("PDB prevents eviction")
            return original(args, *a, **kw)
        self.r.command = command
        with self.assertRaisesRegex(MODULE.ReconcileError, "PDB"):
            self.r.reconcile()
        self.assertNotIn("reboot", self.r.calls)
        self.assertNotIn("uncordon", self.r.calls)

    def test_preexisting_degraded_controller_fails_preflight_immediately(self):
        original = self.r.command
        def command(args, *a, **kw):
            if "deployments,statefulsets,daemonsets" in args:
                return {"items": [{"kind": "DaemonSet", "metadata": {"name": "agent", "namespace": "system"},
                                   "status": {"desiredNumberScheduled": 3, "numberReady": 2}}]}
            return original(args, *a, **kw)
        self.r.command = command
        with self.assertRaisesRegex(MODULE.ReconcileError, "Pre-existing.*system/agent"):
            self.r.wait_workloads(wait=False)
        self.sleep.assert_not_called()

    def test_application_baseline_allows_existing_failure_but_not_new_degradation(self):
        objects = [{"kind": "Deployment", "metadata": {"name": "app", "namespace": "apps",
                    "uid": "app-uid", "generation": 1}, "spec": {"replicas": 3},
                    "status": {"readyReplicas": 2, "observedGeneration": 1}}]
        original = self.r.command
        def command(args, *a, **kw):
            if "deployments,statefulsets,daemonsets" in args:
                return {"items": copy.deepcopy(objects)}
            return original(args, *a, **kw)
        self.r.command = command
        with tempfile.TemporaryDirectory() as directory:
            self.r.args.workload_baseline = str(Path(directory, "health.json"))
            self.r.capture_workload_baseline()
            self.r.wait_workloads(wait=False)
            objects[0]["status"]["readyReplicas"] = 1
            with self.assertRaisesRegex(MODULE.ReconcileError, "apps/app"):
                self.r.wait_workloads(wait=False)
            objects[0]["status"]["readyReplicas"] = 3
            self.r.wait_workloads(wait=False)
            objects[0]["status"]["readyReplicas"] = 2
            with self.assertRaisesRegex(MODULE.ReconcileError, "apps/app"):
                self.r.wait_workloads(wait=False)

    def test_infrastructure_failures_are_never_accepted_as_application_baseline(self):
        for namespace, labels in [("kube-system", {}), ("cattle-system", {}),
                                  ("apps", {"app.kubernetes.io/managed-by": "infrastructure"})]:
            objects = [{"kind": "Deployment", "metadata": {"name": "app", "namespace": namespace,
                        "labels": labels}, "spec": {"replicas": 1}, "status": {"readyReplicas": 0}}]
            original = FakeReconciler.command
            def command(args, *a, **kw):
                if "deployments,statefulsets,daemonsets" in args:
                    return {"items": copy.deepcopy(objects)}
                return original(self.r, args, *a, **kw)
            self.r.command = command
            with tempfile.TemporaryDirectory() as directory:
                self.r.args.workload_baseline = str(Path(directory, "health.json"))
                self.r.capture_workload_baseline()
                with self.assertRaisesRegex(MODULE.ReconcileError, namespace + "/app"):
                    self.r.wait_workloads(wait=False)

    def test_prepare_checks_seed_pull_before_protecting_any_target(self):
        seed = FakeReconciler()
        seed.fail_pull = True
        self.pending()
        self.r.args.prepare_node = ["seed|192.0.2.11|worker", "worker-a|192.0.2.10|worker"]
        with patch.object(MODULE, "Reconciler", side_effect=[seed, self.r]):
            with self.assertRaisesRegex(MODULE.ReconcileError, "ImagePullBackOff"):
                MODULE.prepare_cluster(self.r.args)
        self.assertNotIn("cordon", seed.calls + self.r.calls)
        self.assertNotIn("reboot", seed.calls + self.r.calls)

    def test_recovery_oom_stops_immediately_without_advancing(self):
        original = self.r.command
        def command(args, *a, **kw):
            if "deployments,statefulsets,daemonsets" in args:
                return {"items": [{"kind": "Deployment", "metadata": {"name": "app", "namespace": "system"},
                                   "spec": {"replicas": 1}, "status": {"readyReplicas": 0}}]}
            if "pods" in args:
                return {"items": [{"metadata": {"name": "app-a", "namespace": "system"},
                                   "status": {"phase": "Running", "containerStatuses": [{
                                       "name": "server", "ready": False,
                                       "state": {"waiting": {"reason": "CrashLoopBackOff"}},
                                       "lastState": {"terminated": {"reason": "OOMKilled"}},
                                   }]}}]}
            return original(args, *a, **kw)
        self.r.command = command
        with self.assertRaisesRegex(MODULE.ReconcileError, "OOMKilled.*system/app-a/server"):
            self.r.wait_workloads()
        self.sleep.assert_not_called()

    def test_prepare_without_permission_has_no_mutations(self):
        args = self.r.args
        args.prepare_node = ["worker-a|192.0.2.10|worker"]
        args.allow_node_reboot = False
        self.pending()
        with patch.object(MODULE, "Reconciler", return_value=self.r):
            with self.assertRaisesRegex(MODULE.ReconcileError, "no nodes were cordoned"):
                MODULE.prepare_cluster(args)
        self.assertEqual(self.r.calls, [])

    def test_prepare_waits_for_merged_config_without_reboot_permission(self):
        args = self.r.args
        args.prepare_node = ["worker-a|192.0.2.10|worker"]
        args.allow_node_reboot = False
        self.r.file_id = MODULE.MERGED_FILE_ID
        self.r.process["metadata"]["updated"] = "2026-01-01T00:00:01Z"
        self.sleep.side_effect = lambda _: self.r.process["metadata"].update(
            updated="2026-01-01T00:00:03Z")
        with patch.object(MODULE, "Reconciler", return_value=self.r):
            MODULE.prepare_cluster(args)
        self.assertEqual(self.r.calls, [])

    def test_prepare_without_loaded_seed_does_not_cordon(self):
        self.pending()
        self.r.args.prepare_node = ["worker-a|192.0.2.10|worker"]
        with patch.object(MODULE, "Reconciler", return_value=self.r):
            with self.assertRaisesRegex(MODULE.ReconcileError, "No Ready schedulable worker"):
                MODULE.prepare_cluster(self.r.args)
        self.assertEqual(self.r.calls, [])


class DeployOrderTest(unittest.TestCase):
    def run_reconcile(self, fail_node="", initial=False):
        source = (ROOT / "scripts/deploy.sh").read_text()
        function = re.search(r"^reconcile_talos_registry_auth\(\) \{\n.*?^\}", source, re.M | re.S)[0]
        with tempfile.TemporaryDirectory() as directory:
            for name, role in [("cp-a", "controlplane"), ("cp-b", "controlplane"), ("worker-a", "worker")]:
                Path(directory, "machineconfig-" + name + ".yaml").write_text("machine:\n  type: " + role + "\n")
            harness = r'''
set -euo pipefail
script_dir=unused
cluster_root_workspace="$FIXTURES"
cluster_talosconfig_path=unused
cluster_kubeconfig_path=unused
talos_bootstrap_marker_was_present="$EXISTING"
reboot_for_registry_auth=true
first_controlplane_ip() { echo 192.0.2.1; }
cluster_node_name_ip_pairs() { printf 'cp-a|192.0.2.1\ncp-b|192.0.2.2\nworker-a|192.0.2.10\n'; }
error() { echo "$*" >&2; }
wait_for_all_kubernetes_nodes_ready() { :; }
wait_for_controlplane_etcd_ready() { echo "etcd:$1" >> "$FIXTURES/calls"; }
python3() {
  local name
  if [[ "$*" == *--prepare-node* ]]; then echo prepare >> "$FIXTURES/calls"; return; fi
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == --node-name ]]; then name="$2"; break; fi
    shift
  done
  echo "$name" >> "$FIXTURES/calls"
  [[ "$name" != "$FAIL_NODE" ]]
}
'''
            result = subprocess.run(["bash", "-c", harness + function + "\nreconcile_talos_registry_auth"],
                                    env={**os.environ, "FIXTURES": directory, "FAIL_NODE": fail_node,
                                         "EXISTING": "false" if initial else "true"}, capture_output=True, text=True)
            calls = Path(directory, "calls")
            return result, calls.read_text().splitlines() if calls.exists() else []

    def test_workers_first_then_secondary_controlplanes_then_primary(self):
        result, calls = self.run_reconcile()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["etcd:cp-b", "etcd:cp-a", "prepare", "worker-a", "cp-b", "etcd:cp-b", "cp-a", "etcd:cp-a"])

    def test_failure_stops_other_nodes(self):
        result, calls = self.run_reconcile(fail_node="worker-a")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["etcd:cp-b", "etcd:cp-a", "prepare", "worker-a"])

    def test_first_bootstrap_does_not_need_diagnostic_priorityclass(self):
        result, calls = self.run_reconcile(initial=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])

    def test_reconciliation_precedes_successful_talos_deployment_record(self):
        source = (ROOT / "scripts/deploy.sh").read_text()
        call = source.index("\n  reconcile_talos_registry_auth\n")
        self.assertLess(source.index("\n  reboot_nodes_with_pending_kubelet_max_pods "), call)
        self.assertLess(call, source.index('\n  record_deployment_status "k8s"', call))


if __name__ == "__main__":
    unittest.main()
