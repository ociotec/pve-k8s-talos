"""Evaluate the real Rancher patch catalog against the observed cleanup namespaces."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("tofu"), "OpenTofu is required")
class RancherCleanupNamespaceTest(unittest.TestCase):
    def catalog(self, version):
        source = (ROOT / "platform/main.tf").read_text()
        start = source.index("  rancher_managed_resource_patches_v212 =")
        end = source.index("  rancher_managed_probe_exceptions =", start)
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "main.tf").write_text(
                'locals {\n  rancher_version_major_minor = "' + version + '"\n'
                + source[start:end] + "\n}\n"
            )
            subprocess.run(["tofu", "init", "-backend=false", "-input=false", "-no-color"],
                           cwd=directory, check=True, capture_output=True, text=True)
            result = subprocess.run(
                ["tofu", "console", "-no-color"], cwd=directory, check=True,
                input='jsonencode({for k, p in local.rancher_managed_resource_patches : k => {namespace = p.namespace, name = p.name, patch = jsondecode(p.patch)} if p.resource == "cronjob" && p.name == "rke2-machineconfig-cleanup-cronjob"})\n',
                capture_output=True, text=True,
            )
        return json.loads(json.loads(result.stdout))

    def test_rancher_215_patches_cleanup_in_local_workspace(self):
        jobs = self.catalog("2.15")
        self.assertEqual(list(jobs), ["fleet-local/rke2-machineconfig-cleanup-cronjob"])
        job = next(iter(jobs.values()))
        self.assertEqual(job["namespace"], "fleet-local")
        container = job["patch"]["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(container["resources"]["requests"]["memory"],
                         container["resources"]["limits"]["memory"])

    def test_older_rancher_cleanup_namespace_is_preserved(self):
        for version in ["2.12", "2.14"]:
            with self.subTest(version=version):
                jobs = self.catalog(version)
                self.assertEqual(list(jobs), ["fleet-default/rke2-machineconfig-cleanup-cronjob"])
                self.assertEqual(next(iter(jobs.values()))["namespace"], "fleet-default")


if __name__ == "__main__":
    unittest.main()
