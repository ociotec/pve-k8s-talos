"""Exercise the ownership guard and the rendered, digest-pinned Rancher chart."""

import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

import yaml


ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PREPARE = load("prepare_rancher", "scripts/prepare-rancher-chart.py")
POSTRENDER = load("postrender_rancher", "platform/rancher-postrender.py")
REINSTALL = load("reinstall_rancher", "scripts/reinstall-rancher-for-helm.py")
READY = load("rancher_readiness", "platform/rancher_readiness.py")
sys.modules["rancher_readiness"] = READY
ADMIN = load("ensure_rancher_admin", "platform/ensure-rancher-admin.py")


def resource(kind, name, attributes):
    return {"mode": "managed", "type": kind, "name": name,
            "instances": [{"index_key": 0, "attributes": attributes}]}


class RancherGuardTest(unittest.TestCase):
    def test_string_state_addresses_are_quoted_for_opentofu(self):
        value = resource("kubernetes_manifest", "platform_other", {})
        instance = value["instances"][0]
        instance["index_key"] = "9"
        self.assertEqual(PREPARE.state_address(value, instance), 'kubernetes_manifest.platform_other["9"]')

    def test_missing_settings_keep_legacy(self):
        self.assertEqual(PREPARE.setting('locals {}', 'rancher_deployment_mode', 'legacy'), 'legacy')

    def test_explicit_mode_and_invalid_unquoted_mode(self):
        self.assertEqual(PREPARE.setting('rancher_deployment_mode = "helm" # review',
                                         'rancher_deployment_mode', 'legacy'), 'helm')
        with self.assertRaises(ValueError):
            PREPARE.setting('rancher_deployment_mode = true', 'rancher_deployment_mode', 'legacy')

    def test_typed_deployment_blocks_helm_but_not_legacy(self):
        state = {"resources": [resource("kubernetes_deployment_v1", "rancher", {})]}
        self.assertTrue(PREPARE.state_conflicts(state, "helm"))
        self.assertFalse(PREPARE.state_conflicts(state, "legacy"))

    def test_legacy_state_encoded_manifest_blocks_helm(self):
        manifest = {"kind": "Service", "metadata": {"name": "rancher", "namespace": "cattle-system"}}
        for stored in [manifest, {"value": manifest, "type": ["object", {}]}]:
            state = {"resources": [resource("kubernetes_manifest", "platform_other", {"manifest": stored})]}
            self.assertTrue(PREPARE.state_conflicts(state, "helm"))

    def test_helm_release_blocks_reverse_switch(self):
        state = {"resources": [resource("helm_release", "rancher", {"name": "rancher"})]}
        self.assertTrue(PREPARE.state_conflicts(state, "legacy"))
        self.assertFalse(PREPARE.state_conflicts(state, "helm"))

    def test_real_helm_state_with_null_manifest_and_object_metadata(self):
        state = {"resources": [resource("helm_release", "rancher", {
            "name": "rancher", "manifest": None, "metadata": {"name": "rancher"}})]}
        self.assertFalse(PREPARE.state_conflicts(state, "helm"))
        self.assertTrue(PREPARE.state_conflicts(state, "legacy"))

    def test_preserved_secrets_namespace_and_portainer_do_not_block(self):
        resources = [resource("kubernetes_secret_v1", "rancher_bootstrap", {
            "metadata": [{"name": "bootstrap-secret", "namespace": "cattle-system"}]}),
            resource("kubernetes_manifest", "platform_other", {"manifest": {"metadata": {
                "name": "portainer", "namespace": "portainer"}}}),
            resource("kubernetes_manifest", "platform_namespaces", {"manifest": {"metadata": {
                "name": "cattle-system"}}})]
        self.assertFalse(PREPARE.state_conflicts({"resources": resources}, "helm"))

    def test_hook_template_changes_fail_closed(self):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as chart:
            for name in ["secret.yaml", "pre-upgrade-hook-job.yaml"]:
                body = b"upstream changed"
                info = tarfile.TarInfo("rancher/templates/" + name)
                info.size = len(body)
                chart.addfile(info, io.BytesIO(body))
        with self.assertRaises(ValueError):
            PREPARE.patch_members(buffer.getvalue())


class RancherReinstallTest(unittest.TestCase):
    def test_journal_is_written_atomically_with_private_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "journal.json"
            REINSTALL.write_private(path, {"phase": "prepared"})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.read_text(), '{"phase": "prepared"}')
            self.assertFalse(path.with_suffix(".tmp").exists())

    def test_custom_resource_kind_is_qualified_to_avoid_ambiguous_cluster_apis(self):
        self.assertEqual(REINSTALL.qualified_kind({"kind": "Cluster", "apiVersion": "management.cattle.io/v3"}),
                         "Cluster.management.cattle.io")

    def obj(self, kind, name, namespace="cattle-system", **metadata):
        return {"kind": kind, "metadata": {"name": name, "namespace": namespace, **metadata}}

    def check(self, objects=(), releases=(), namespaces=(), clusters=(), gitrepos=(), bundles=(), capi=()):
        REINSTALL.validate_inventory(objects, releases, namespaces, clusters, gitrepos, bundles, capi)

    def test_known_rancher_with_local_cluster_is_accepted(self):
        self.check(objects=[self.obj("Deployment", "rancher")],
                   clusters=[self.obj("Cluster", "local")],
                   bundles=[self.obj("Bundle", "fleet-agent-local", "fleet-local")])

    def test_downstream_clusters_are_rejected(self):
        with self.assertRaises(ValueError):
            self.check(clusters=[self.obj("Cluster", "c-application")])

    def test_user_gitops_and_capi_are_rejected(self):
        for field in ["gitrepos", "bundles", "capi"]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check(**{field: [self.obj("Custom", "application")]})

    def test_unknown_workload_or_pvc_in_internal_namespace_is_rejected(self):
        for kind in ["Deployment", "StatefulSet", "DaemonSet", "PersistentVolumeClaim"]:
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                self.check(objects=[self.obj(kind, "application")])

    def test_namespace_or_volume_deletion_is_forbidden(self):
        for kind in ["Namespace", "PersistentVolumeClaim", "PersistentVolume"]:
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                REINSTALL.delete(self.obj(kind, "application"))

    def test_application_namespace_owned_by_rancher_blocks_cascade(self):
        with self.assertRaises(ValueError):
            self.check(namespaces=[self.obj("Namespace", "application", "", ownerReferences=[{
                "apiVersion": "management.cattle.io/v3", "kind": "Project", "name": "old-project"}])])

    def test_unrelated_helm_release_in_internal_namespace_is_rejected(self):
        with self.assertRaises(ValueError):
            self.check(releases=[{"namespace": "cattle-system", "name": "application"}])


class RancherLocalAdminTest(unittest.TestCase):
    def test_existing_admin_is_never_reset(self):
        with tempfile.TemporaryDirectory() as directory:
            responses = [directory, json.dumps({"items": [{"username": "admin"}]})]
            with patch.object(ADMIN, "command", side_effect=responses) as command, patch("sys.stdout", io.StringIO()):
                self.assertEqual(ADMIN.main(), 0)
            self.assertEqual(command.call_count, 2)


class RancherReadinessTest(unittest.TestCase):
    def test_existing_webhook_is_prepared_before_waiting(self):
        events = []
        def query(*args):
            events.append(args[0])
            return {"items": [{"metadata": {"name": "rancher-webhook"}}]}
        with patch.object(READY, "kubectl", side_effect=query), patch.object(READY, "wait", side_effect=lambda *a, **kw: events.append("wait")):
            READY.prepare_webhook({"spec": {"replicas": 2, "minReadySeconds": 10}})
        self.assertEqual(events, ["get", "patch", "wait"])

    def test_fresh_install_does_not_create_a_webhook_outside_helm(self):
        with patch.object(READY, "kubectl", return_value={"items": []}) as query, patch.object(READY, "wait") as wait:
            READY.prepare_webhook({"spec": {"replicas": 2}})
        query.assert_called_once()
        wait.assert_not_called()

    def test_auth_config_must_exist_and_be_enabled(self):
        with patch.object(READY, "kubectl", side_effect=[None, {"enabled": True}]):
            self.assertIsNotNone(READY.auth_pending())
            self.assertIsNone(READY.auth_pending())
        with patch.object(READY, "kubectl", return_value={"enabled": False}), self.assertRaises(RuntimeError):
            READY.auth_pending()

    def test_cached_missing_local_provider_is_retried_but_invalid_password_is_not(self):
        unavailable = urllib.error.HTTPError("example", 500, "not initialized", {}, None)
        unauthorized = urllib.error.HTTPError("example", 401, "invalid credentials", {}, None)
        with patch.object(READY.time, "sleep") as sleep:
            from unittest.mock import Mock
            request = Mock(side_effect=[unavailable, unauthorized])
            with self.assertRaises(urllib.error.HTTPError) as error:
                READY.retry_http(request)
            self.assertEqual(error.exception.code, 401)
            self.assertEqual(request.call_count, 2)
            sleep.assert_called_once()

    def test_http_transport_recovers_and_permissions_fail_immediately(self):
        from unittest.mock import Mock
        with patch.object(READY.time, "sleep"):
            request = Mock(side_effect=[urllib.error.URLError("not ready"), {"ok": True}])
            self.assertEqual(READY.retry_http(request), {"ok": True})
            request = Mock(side_effect=urllib.error.HTTPError("example", 403, "forbidden", {}, None))
            with self.assertRaises(urllib.error.HTTPError):
                READY.retry_http(request)
            self.assertEqual(request.call_count, 1)

    def test_http_failure_and_pending_systems_have_deadlines(self):
        from unittest.mock import Mock
        with patch.object(READY.time, "monotonic", side_effect=[0, 10]):
            request = Mock(side_effect=urllib.error.URLError("private response must not be printed"))
            with self.assertRaisesRegex(RuntimeError, "did not become available"):
                READY.retry_http(request, timeout=5)
        with patch.object(READY.time, "monotonic", side_effect=[0, 10]):
            with self.assertRaisesRegex(RuntimeError, "Helm: example=pending-install"):
                READY.wait(lambda: "Helm: example=pending-install", "systems", timeout=5)

    def inventory(self, release_status="deployed", generation=2, observed=2, replicas=2, updated=2, available=2):
        repos = {"items": [{"metadata": {"name": n}, "status": {"conditions": [
            {"type": "Downloaded", "status": "True"}]}} for n in
            ["rancher-charts", "rancher-partner-charts", "rancher-rke2-charts"]]}
        workloads = {"items": [{"metadata": {"name": "webhook", "namespace": "system", "generation": generation},
            "spec": {"replicas": 2}, "status": {"observedGeneration": observed,
                "replicas": replicas, "updatedReplicas": updated, "availableReplicas": available}}]}
        helm = subprocess.CompletedProcess([], 0, json.dumps([
            {"name": "webhook", "namespace": "system", "status": release_status}]), "")
        return repos, workloads, helm

    def pending(self, **kwargs):
        repos, workloads, helm = self.inventory(**kwargs)
        with patch.object(READY, "kubectl", side_effect=[repos, workloads]), patch.object(READY.subprocess, "run", return_value=helm):
            return READY.systems_pending(["system/webhook"], ["system/webhook"])

    def test_ready_pods_do_not_hide_a_pending_helm_release(self):
        self.assertIn("pending-install", self.pending(release_status="pending-install"))
        self.assertIsNone(self.pending())

    def test_rollout_must_include_every_updated_replica_and_observed_generation(self):
        for changes in [{"observed": 1}, {"replicas": 3}, {"updated": 1}, {"available": 1}]:
            with self.subTest(changes=changes):
                self.assertIn("Deployments", self.pending(**changes))

    def test_catalogs_must_be_downloaded_before_querying_releases(self):
        with patch.object(READY, "kubectl", return_value={"items": []}), patch.object(READY.subprocess, "run") as helm:
            self.assertIn("catalogs", READY.systems_pending([], []))
            helm.assert_not_called()

    def test_initial_catalog_with_null_conditions_is_pending(self):
        repos = {"items": [{"metadata": {"name": "rancher-charts"}, "status": {"conditions": None}}]}
        with patch.object(READY, "kubectl", return_value=repos):
            self.assertIn("catalogs", READY.systems_pending([], []))

    def test_previous_healthy_single_replica_does_not_satisfy_ha_gate(self):
        repos, workloads, helm = self.inventory(replicas=1, updated=1, available=1)
        workloads["items"][0]["spec"]["replicas"] = 1
        with patch.object(READY, "kubectl", side_effect=[repos, workloads]), patch.object(READY.subprocess, "run", return_value=helm):
            self.assertIn("Deployments", READY.systems_pending(["system/webhook"], ["system/webhook"], {"system/webhook": 2}))

    def test_gate_requires_consecutive_successes_after_a_transient_failure(self):
        from unittest.mock import Mock
        check = Mock(side_effect=[None, "Helm pending", None, None])
        with patch.object(READY.time, "sleep"):
            READY.wait(check, "systems", stable=2)
        self.assertEqual(check.call_count, 4)


@unittest.skipUnless(os.environ.get("RANCHER_TEST_WORKSPACE"), "Set RANCHER_TEST_WORKSPACE to a 2.15 Helm workspace")
class RancherVersionIntegrationTest(unittest.TestCase):
    def test_opentofu_graph_gates_patches_on_nested_helm_readiness(self):
        result = subprocess.run(["tofu", "-chdir=" + os.environ["RANCHER_TEST_WORKSPACE"], "graph", "-type=plan"],
                                text=True, capture_output=True, check=True)
        self.assertIn('"[root] null_resource.rancher_managed_resource_patches (expand)" -> "[root] null_resource.rancher_system_ready (expand)"', result.stdout)
        self.assertIn('"[root] helm_release.rancher (expand)" -> "[root] null_resource.rancher_webhook_prepare (expand)"', result.stdout)

    def test_webhook_chart_settings_match_the_final_patch(self):
        result = subprocess.run(["tofu", "-chdir=" + os.environ["RANCHER_TEST_WORKSPACE"], "console", "-no-color"],
            input='jsonencode({values=local.rancher_helm_values.webhook, patch=jsondecode(local.rancher_managed_resource_patches["cattle-system/rancher-webhook"].patch)})\n',
            text=True, capture_output=True, check=True)
        config = json.loads(json.loads(result.stdout.strip()))
        values, spec = config["values"], config["patch"]["spec"]
        self.assertEqual(values["replicaCount"], 2)
        self.assertEqual(values["podDisruptionBudget"], {"enabled": True, "minAvailable": 1})
        self.assertEqual(spec["replicas"], 2)
        self.assertEqual(spec["strategy"]["rollingUpdate"], {"maxUnavailable": 0, "maxSurge": 1})
        container = spec["template"]["spec"]["containers"][0]
        self.assertEqual(container["resources"], values["resources"])
        self.assertEqual(values["priorityClassName"], spec["template"]["spec"]["priorityClassName"])
        self.assertEqual(container["readinessProbe"]["httpGet"],
                         {"path": "/healthz", "port": "https", "scheme": "HTTPS"})

    def test_actual_module_selects_turtles_without_retired_controllers(self):
        result = subprocess.run(["tofu", "-chdir=" + os.environ["RANCHER_TEST_WORKSPACE"], "console", "-no-color"],
            input="jsonencode(keys(local.rancher_managed_resource_patches))\n",
            text=True, capture_output=True, check=True)
        keys = json.loads(json.loads(result.stdout.strip()))
        self.assertIn("cattle-turtles-system/rancher-turtles-controller-manager", keys)
        self.assertIn("cattle-capi-system/capi-controller-manager", keys)
        self.assertIn("cattle-fleet-local-system/fleet-agent", keys)
        self.assertNotIn("cattle-provisioning-capi-system/capi-controller-manager", keys)
        self.assertNotIn("cattle-system/api-extension", keys)


@unittest.skipUnless(os.environ.get("RANCHER_TEST_CHART"), "Set RANCHER_TEST_CHART to the prepared chart")
class RenderedChartTest(unittest.TestCase):
    def test_chart_hooks_and_workloads_meet_repository_contract(self):
        values = {
            "hostname": "rancher.example.com", "replicas": 1, "privateCA": True,
            "priorityClassName": "infra-observability",
            "ingress": {"ingressClassName": "nginx", "tls": {"source": "secret", "secretName": "tls-rancher-ingress"}},
            "resources": {"requests": {"cpu": "1", "memory": "4Gi"},
                          "limits": {"cpu": "4", "memory": "4Gi"}},
            "postDelete": {"enabled": False},
            "extraEnv": [{"name": "CATTLE_BOOTSTRAP_PASSWORD", "valueFrom": {
                "secretKeyRef": {"name": "bootstrap-secret", "key": "bootstrapPassword"}}}],
        }
        if os.environ.get("RANCHER_TEST_WORKSPACE"):
            actual = subprocess.run(["tofu", "-chdir=" + os.environ["RANCHER_TEST_WORKSPACE"], "console", "-no-color"],
                input="jsonencode(local.rancher_helm_values)\n", text=True, capture_output=True, check=True)
            values = json.loads(json.loads(actual.stdout.strip()))
        result = subprocess.run(["helm", "template", "rancher", os.environ["RANCHER_TEST_CHART"],
            "--namespace", "cattle-system", "--kube-version", "1.36.2", "-f", "-"],
            input=yaml.safe_dump(values), capture_output=True, text=True, check=True)
        documents = [d for d in yaml.safe_load_all(result.stdout) if d]
        if os.environ.get("RANCHER_TEST_WORKSPACE"):
            config = next(d for d in documents if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "rancher-config")
            webhook = yaml.safe_load(config["data"]["rancher-webhook"])
            self.assertEqual(webhook["replicaCount"], 2)
            self.assertTrue(webhook["podDisruptionBudget"]["enabled"])
            self.assertEqual(webhook["resources"]["requests"]["memory"], webhook["resources"]["limits"]["memory"])
        # Helm bypasses post-rendering for hooks: test them without transforming.
        hooks = [d for d in documents if "helm.sh/hook" in (d["metadata"].get("annotations") or {})]
        regular = [d for d in documents if d not in hooks]
        rendered = list(POSTRENDER.render(regular)) + hooks
        self.assertFalse(any(d["kind"] == "Secret" and d["metadata"]["name"] == "bootstrap-secret" for d in rendered))
        self.assertFalse(any(d["kind"] == "PriorityClass" for d in rendered))
        self.assertTrue(any(d["kind"] == "Job" for d in hooks))
        for d in rendered:
            self.assertNotIn("post-delete", d["metadata"]["name"])
            if d["kind"] not in {"Deployment", "Job"}:
                continue
            pod = d["spec"]["template"]["spec"]
            self.assertEqual(pod["priorityClassName"], "infra-observability")
            for container in pod["containers"] + pod.get("initContainers", []):
                resources = container["resources"]
                for key in ["requests", "limits"]:
                    self.assertIn("cpu", resources[key])
                    self.assertIn("memory", resources[key])
                self.assertEqual(resources["requests"]["memory"], resources["limits"]["memory"])
                if d["kind"] == "Deployment":
                    self.assertIn("readinessProbe", container)
                    self.assertIn("livenessProbe", container)
                    self.assertIn("startupProbe", container)
        deployment = next(d for d in rendered if d["kind"] == "Deployment")
        bootstrap = [e for e in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
                     if e["name"] == "CATTLE_BOOTSTRAP_PASSWORD"]
        self.assertEqual(len(bootstrap), 1)
        self.assertEqual(bootstrap[0]["valueFrom"]["secretKeyRef"],
                         {"name": "bootstrap-secret", "key": "bootstrapPassword"})
        self.assertEqual(deployment["spec"]["selector"]["matchLabels"], {"app": "rancher"})
        service = next(d for d in rendered if d["kind"] == "Service" and d["metadata"]["name"] == "rancher")
        self.assertEqual(next(p["targetPort"] for p in service["spec"]["ports"] if p["name"] == "https"), 443)


if __name__ == "__main__":
    unittest.main()
