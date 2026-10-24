"""Protect legacy clusters and immutable upstream manifest preparation."""

import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("infra_releases", ROOT / "scripts/prepare-infrastructure-manifests.py")
RELEASES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASES)


class InfrastructureReleaseTest(unittest.TestCase):
    def test_documented_probe_exceptions_survive_release_updates(self):
        baseline = next(d for d in RELEASES.yaml.safe_load_all((ROOT / "k8s-net/cert-manager.yaml").read_text())
                        if d and d.get("kind") == "Deployment" and d["metadata"]["name"] == "cert-manager-cainjector")
        updated = RELEASES.copy.deepcopy(baseline)
        updated["metadata"].pop("annotations", None)
        container = updated["spec"]["template"]["spec"]["containers"][0]
        container["image"] = "quay.io/jetstack/cert-manager-cainjector:v1.21.3"
        container.pop("resources", None)
        RELEASES.workload_policy([updated], [baseline], "k8s-net")
        self.assertEqual(updated["metadata"]["annotations"], baseline["metadata"]["annotations"])
        self.assertTrue(container["image"].endswith(":v1.21.3"))
        self.assertEqual(container["resources"]["requests"]["memory"], container["resources"]["limits"]["memory"])

    def test_legacy_network_manifests_are_byte_identical_and_offline(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            constants = root / "constants.tf"
            constants.write_text("locals {}\n")
            output = root / "out"
            output.mkdir()
            with patch.object(RELEASES, "yaml", None), patch.object(RELEASES.urllib.request, "urlopen", side_effect=AssertionError("Legacy preparation must be offline")):
                RELEASES.prepare("k8s-net", constants, output, output / ".upstream")
            for name in ("cert-manager.yaml", "metrics-server.yaml", "metallb-native.yaml"):
                self.assertEqual((output / name).read_bytes(), (ROOT / "k8s-net" / name).read_bytes())

    def test_legacy_rook_directory_link_is_replaced_without_writing_source(self):
        source = ROOT / "rook/manifests"
        before = {p.relative_to(source): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in source.rglob("*") if p.is_file()}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            constants = root / "constants.tf"
            constants.write_text("locals {}\n")
            output = root / "manifests"
            output.symlink_to(source)
            with patch.object(RELEASES.urllib.request, "urlopen", side_effect=AssertionError("Legacy preparation must be offline")):
                RELEASES.prepare("rook", constants, output, output / ".upstream")
            self.assertFalse(output.is_symlink())
            for path, checksum in before.items():
                self.assertEqual(hashlib.sha256((output / path).read_bytes()).hexdigest(), checksum)
                self.assertEqual(hashlib.sha256((source / path).read_bytes()).hexdigest(), checksum)

    def test_unverified_download_is_never_cached_or_parsed(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            with patch.object(RELEASES.urllib.request, "urlopen", return_value=io.BytesIO(b"unexpected upstream content")):
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    RELEASES.fetch({"url": "https://example.com/release.yaml", "sha256": "0" * 64}, cache)
            self.assertEqual(list(cache.iterdir()), [])

    def test_workspace_file_symlinks_do_not_overwrite_shared_manifests(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shared = root / "source.yaml"
            shared.write_bytes(b"original")
            workspace = root / "workspace.yaml"
            workspace.symlink_to(shared)
            RELEASES.atomic_write(workspace, b"new release")
            self.assertEqual(shared.read_bytes(), b"original")
            self.assertEqual(workspace.read_bytes(), b"new release")

    def test_unknown_or_computed_release_does_not_fall_back_silently(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for value in ('"99.0.0"', 'var.version'):
                constants = root / "constants.tf"
                constants.write_text("locals {\n cert_manager_version = " + value + "\n}\n")
                output = root / "out"
                output.mkdir(exist_ok=True)
                with self.assertRaises(ValueError):
                    RELEASES.prepare("k8s-net", constants, output, output / ".upstream")


if __name__ == "__main__":
    unittest.main()
