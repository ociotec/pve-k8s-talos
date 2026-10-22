"""Exercise the ownership guard and the rendered, digest-pinned Rancher chart."""

import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
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


@unittest.skipUnless(os.environ.get("RANCHER_TEST_WORKSPACE"), "Set RANCHER_TEST_WORKSPACE to a 2.15 Helm workspace")
class RancherVersionIntegrationTest(unittest.TestCase):
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
