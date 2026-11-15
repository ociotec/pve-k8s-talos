"""Check pinned hook adaptation without changing Helm tests or maintenance logic."""

import hashlib
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import yaml


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
SPEC = importlib.util.spec_from_file_location("kyverno_chart", ROOT / "scripts/prepare-kyverno-chart.py")
CHART = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHART)


def archive(members):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as chart:
        for name, data in members.items():
            member = tarfile.TarInfo(name)
            member.size = len(data)
            chart.addfile(member, io.BytesIO(data))
    return buffer.getvalue()


def members(data):
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as chart:
        return {member.name: chart.extractfile(member).read() for member in chart.getmembers() if member.isfile()}


class HookPreparationTest(unittest.TestCase):
    def fixture(self, version="3.7.0"):
        result = {"kyverno/templates/hooks/" + name: b"kind: Job\nspec:\n  template:\n    spec:\n      restartPolicy: Never\n"
                  for name in CHART.HOOKS[version]}
        result["kyverno/templates/tests/metrics.yaml"] = b"kind: Pod\nspec:\n  restartPolicy: Never\n"
        result["kyverno/templates/rbac.yaml"] = b"kind: Role\n"
        return result

    def test_only_automatic_hook_pod_specs_are_changed(self):
        original = self.fixture()
        updated = dict(CHART.patch_members(archive(original), "3.7.0"))
        for name, content in original.items():
            if "/templates/hooks/" in name:
                self.assertEqual(updated[name].replace(b"      priorityClassName: infra-k8s\n", b""), content)
            else:
                self.assertEqual(updated[name], content)

    def test_missing_or_changed_hooks_stop_preparation(self):
        for changed in (False, True):
            original = self.fixture()
            name = next(iter(original))
            if changed:
                original[name] = b"kind: Job\nspec: {}\n"
            else:
                del original[name]
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                CHART.patch_members(archive(original), "3.7.0")

    def test_verified_cache_is_reused_and_output_is_stable(self):
        data = archive(self.fixture())
        with tempfile.TemporaryDirectory() as directory, patch.dict(CHART.CHART_DIGESTS, {"3.7.0": hashlib.sha256(data).hexdigest()}):
            output = Path(directory) / "chart.tgz"
            with patch.object(CHART, "fetch_bytes", return_value=data):
                CHART.prepare_chart("3.7.0", output)
            before = output.read_bytes(), output.stat().st_mtime_ns
            with patch.object(CHART, "fetch_bytes", side_effect=AssertionError("Cache should be reused")):
                CHART.prepare_chart("3.7.0", output)
            self.assertEqual((output.read_bytes(), output.stat().st_mtime_ns), before)

    def test_bad_download_preserves_previous_output_and_is_not_cached(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "chart.tgz"
            output.write_bytes(b"previous")
            with patch.object(CHART, "fetch_bytes", return_value=b"unverified"):
                with self.assertRaisesRegex(ValueError, "checksum"):
                    CHART.prepare_chart("3.7.0", output)
            self.assertEqual(output.read_bytes(), b"previous")
            self.assertFalse((Path(directory) / ".upstream").exists())

    def test_disabled_kyverno_does_not_download_a_chart(self):
        with tempfile.TemporaryDirectory() as directory:
            constants = Path(directory) / "constants.tf"
            constants.write_text("locals {\n enable_kyverno_audit = false\n enable_kyverno_enforce = false\n}\n")
            output = Path(directory) / "chart.tgz"
            with patch.object(CHART.sys, "argv", ["prepare", "--constants", str(constants), "--output", str(output)]), \
                    patch.object(CHART, "fetch_bytes", side_effect=AssertionError("Kyverno is disabled")):
                self.assertEqual(CHART.main(), 0)
            self.assertFalse(output.exists())


@unittest.skipUnless(os.environ.get("KYVERNO_TEST_CHARTS_DIR") and shutil.which("helm"),
                     "Set KYVERNO_TEST_CHARTS_DIR to verified upstream archives; Helm is required")
class RenderedHooksTest(unittest.TestCase):
    def test_supported_charts_keep_maintenance_behavior_and_prioritize_automatic_hooks(self):
        hook_resources = {"requests": {"cpu": "10m", "memory": "256Mi"}, "limits": {"cpu": "100m", "memory": "256Mi"}}
        values = {
            "admissionController": {"priorityClassName": "infra-k8s"},
            "reportsController": {"priorityClassName": "infra-monitoring"},
            "backgroundController": {"enabled": False}, "cleanupController": {"enabled": False},
            "crds": {"migration": {"podResources": hook_resources}},
            "webhooksCleanup": {"resources": hook_resources},
        }
        for version, digest in CHART.CHART_DIGESTS.items():
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                source = Path(os.environ["KYVERNO_TEST_CHARTS_DIR"]) / f"kyverno-{version}.tgz"
                self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), digest)
                output = Path(directory) / "prepared.tgz"
                with patch.object(CHART, "fetch_bytes", return_value=source.read_bytes()):
                    CHART.prepare_chart(version, output)

                def render(path):
                    result = subprocess.run(["helm", "template", "kyverno", str(path), "--namespace", "kyverno",
                                             "--kube-version", "1.36.5", "-f", "-"], input=yaml.safe_dump(values),
                                            capture_output=True, text=True, check=True, timeout=30)
                    return {(obj["kind"], obj["metadata"]["name"]): obj
                            for obj in yaml.safe_load_all(result.stdout) if obj}

                before, after = render(source), render(output)
                self.assertEqual(before.keys(), after.keys())
                hooks = 0
                for key, obj in after.items():
                    hook = obj.get("metadata", {}).get("annotations", {}).get("helm.sh/hook", "")
                    if obj["kind"] == "Job" and hook and "test" not in hook:
                        hooks += 1
                        spec = obj["spec"]["template"]["spec"]
                        self.assertEqual(spec.pop("priorityClassName"), "infra-k8s")
                        for container in spec["containers"] + spec.get("initContainers", []):
                            resources = container["resources"]
                            self.assertEqual(resources["requests"]["memory"], resources["limits"]["memory"])
                            for side in ("requests", "limits"):
                                self.assertIn("cpu", resources[side])
                    self.assertEqual(obj, before[key])
                self.assertEqual(hooks, len(CHART.HOOKS[version]))


if __name__ == "__main__":
    unittest.main()
