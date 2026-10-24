"""Check image selection with existing constants that omit new settings."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("tofu"), "OpenTofu is required")
class ClusterImageVersionsTest(unittest.TestCase):
    def test_benchmark_accepts_legacy_constants_and_cluster_overrides(self):
        source = (ROOT / "benchmark/main.tf").read_text()
        selection = next(line for line in source.splitlines()
                         if line.strip().startswith("benchmark_kafka_image_value "))
        env = {key: value for key, value in os.environ.items() if not key.startswith("TF_VAR_")}
        for cluster, expected in ((None, "v26.1.6"), ("sample", "v26.2.5")):
            with self.subTest(cluster=cluster or "legacy"), tempfile.TemporaryDirectory() as directory:
                constants = "locals {}\n"
                if cluster:
                    # Use the example's actual pin without importing unrelated settings.
                    override = next(line for line in (ROOT / "clusters" / cluster / "benchmark_constants.tf").read_text().splitlines()
                                    if line.strip().startswith("benchmark_kafka_image "))
                    constants = "locals {\n" + override + "\n}\n"
                path = Path(directory)
                (path / "main.tf").write_text("locals {\n" + selection + "\n}\n")
                (path / "constants.tf").write_text(constants)
                result = subprocess.run(["tofu", "console", "-no-color"], cwd=directory,
                                        input="jsonencode(local.benchmark_kafka_image_value)\n",
                                        capture_output=True, text=True, env=env, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                # Console can exit successfully after a static evaluation error;
                # decoding also rejects its '(known after apply)' placeholder.
                image = json.loads(json.loads(result.stdout))
                self.assertEqual(image, "docker.redpanda.com/redpandadata/redpanda:" + expected)


if __name__ == "__main__":
    unittest.main()
