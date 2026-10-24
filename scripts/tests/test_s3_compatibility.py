"""Render the production Garage config with omitted and explicit optional inputs."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("s3_defaults", ROOT / "scripts/prepare-s3-defaults.py")
DEFAULTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DEFAULTS)


@unittest.skipUnless(shutil.which("tofu"), "OpenTofu is required")
class GarageCompatibilityTest(unittest.TestCase):
    def test_optional_endpoint_preserves_legacy_and_cluster_expressions(self):
        source = (ROOT / "s3-storage/main.tf").read_text()
        endpoint = next(line for line in source.splitlines()
                        if line.strip().startswith("garage_s3_public_endpoint_value ="))
        toml = "  garage_config_toml = <<-EOT" + source.split("  garage_config_toml = <<-EOT", 1)[1].split("\n  EOT", 1)[0] + "\n  EOT\n"
        fixture = '''
locals {
  garage_replication_factor_value = 3
  s3_namespace_value = "s3"
  garage_name_value = "garage"
  garage_s3_region_value = "example"
  garage_s3_hostname = "s3.example.com"
  garage_s3_hostname_value = local.garage_s3_hostname
'''
        fixture += endpoint + "\n" + toml + "}\n"
        cases = [("", None), ('garage_s3_public_endpoint = ""', None),
                 ('garage_s3_public_endpoint = format("https://%s", local.garage_s3_hostname)', "https://s3.example.com"),
                 ('garage_s3_public_endpoint = "https://objects.example.net"', "https://objects.example.net")]
        env = {k: v for k, v in os.environ.items() if not k.startswith("TF_VAR_")}
        for setting, expected in cases:
            with self.subTest(setting=setting or "omitted"), tempfile.TemporaryDirectory() as directory:
                path = Path(directory)
                constants = "locals {\n" + setting + "\n}\n"
                (path / "main.tf").write_text(fixture)
                (path / "constants.tf").write_text(constants)
                (path / "compatibility-defaults.tf").write_text(DEFAULTS.render(constants))
                result = subprocess.run(["tofu", "console", "-no-color"], cwd=path, env=env,
                                        input="jsonencode(local.garage_config_toml)\n",
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                rendered = json.loads(json.loads(result.stdout))
                parsed = tomllib.loads(rendered)
                self.assertEqual(parsed["s3_api"].get("public_endpoint"), expected)
                if expected is None:
                    self.assertIn('root_domain = ".s3.example.com"\n\n[admin]', rendered)
                else:
                    self.assertIn("\npublic_endpoint = ", rendered)


if __name__ == "__main__":
    unittest.main()
