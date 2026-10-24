"""Render the real Tempo template for existing and fresh storage configurations."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("tofu"), "OpenTofu is required")
class TempoBlockFormatTest(unittest.TestCase):
    def test_existing_formats_and_new_vparquet5(self):
        source = (ROOT / "monitoring/main.tf").read_text()
        block_local = next(line for line in source.splitlines() if line.strip().startswith("tempo_block_version_value ="))
        check = 'check "tempo_block_format" {' + source.split('check "tempo_block_format" {', 1)[1].split('\ncheck ', 1)[0]
        fixture = '''
variable "tag" { default = "3.1.1" }
variable "settings" { default = "" }
locals {
  monitoring_constants_source = var.settings
  tempo_image_tag = var.tag
'''
        fixture += block_local + '\n'
        fixture += '''
  rendered = templatefile(TEMPLATE_PATH, {
    tempo_image_tag = var.tag
    tempo_v3_enabled = tonumber(split(".", var.tag)[0]) >= 3
    tempo_block_version = local.tempo_block_version_value
    tempo_config_hash = sha256(var.settings)
    tempo_retention = "24h"
    storage_class = "example-rbd"
    tempo_storage_size = "1Gi"
    tempo_cpu_request = "100m"
    tempo_cpu_limit = "500m"
    tempo_mem_request = "256Mi"
    tempo_mem_limit = "256Mi"
    otel_collector_image_tag = "0.163.2"
    otel_collector_cpu_request = "100m"
    otel_collector_cpu_limit = "500m"
    otel_collector_mem_request = "256Mi"
    otel_collector_mem_limit = "256Mi"
    otel_collector_memory_limit_mib = 192
    otel_collector_memory_spike_mib = 32
  })
  documents = [for doc in split("\\n---\\n", local.rendered) : yamldecode(doc)]
  tempo_config = yamldecode([for doc in local.documents : doc.data["tempo.yaml"] if doc.kind == "ConfigMap" && doc.metadata.name == "tempo-config"][0])
}
output "config" { value = local.tempo_config }
'''.replace('TEMPLATE_PATH', json.dumps(str(ROOT / "monitoring/tempo.yaml")))
        fixture += '\n' + check
        tests = '''
run "old_tempo_keeps_its_default" {
  command = plan
  variables { tag = "2.10.8" }
  assert {
    condition = !can(output.config.storage.trace.block)
    error_message = "An existing cluster must not acquire an explicit storage format."
  }
}
run "new_tempo_keeps_default_when_unset" {
  command = plan
  assert {
    condition = !can(output.config.storage.trace.block)
    error_message = "Unconfigured clusters must follow their selected image default."
  }
}
run "fresh_storage_uses_vparquet5" {
  command = plan
  variables { settings = "tempo_block_version = \\"vParquet5\\"" }
  assert {
    condition = output.config.storage.trace.block.version == "vParquet5"
    error_message = "The requested new storage format must reach the Tempo configuration."
  }
}
run "existing_vparquet4_remains_selectable" {
  command = plan
  variables { settings = "tempo_block_version = \\"vParquet4\\"" }
  assert {
    condition = output.config.storage.trace.block.version == "vParquet4"
    error_message = "New Tempo must allow an explicit legacy vParquet4 write format."
  }
}
run "removed_vparquet3_writer_is_rejected" {
  command = plan
  variables { settings = "tempo_block_version = \\"vParquet3\\"" }
  expect_failures = [check.tempo_block_format]
}
run "unknown_format_is_rejected" {
  command = plan
  variables { settings = "tempo_block_version = \\"unknown\\"" }
  expect_failures = [check.tempo_block_format]
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "main.tf").write_text(fixture)
            (path / "formats.tftest.hcl").write_text(tests)
            initialized = subprocess.run(["tofu", "init", "-backend=false", "-no-color"], cwd=path, capture_output=True, text=True)
            self.assertEqual(initialized.returncode, 0, initialized.stdout + initialized.stderr)
            result = subprocess.run(["tofu", "test", "-no-color"], cwd=path, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
