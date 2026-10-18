"""Evaluate the production sizing expressions with provider-free OpenTofu tests."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("tofu"), "OpenTofu is required")
class RecommenderSizingTest(unittest.TestCase):
    def test_capacity_headroom_overrides_and_canonical_units(self):
        source = (ROOT / "monitoring/vpa-goldilocks.tf").read_text()
        # Exercise the actual variable contract and sizing locals, isolated from
        # providers and cluster credentials. No cluster plan or apply is run.
        sizing = source.split("  # KSM v2", 1)[0] + "\n}\n"
        release = source.split('resource "helm_release" "vpa" {', 1)[1]
        values = release.split("values = [yamlencode({", 1)[1].split("\n  })]", 1)[0]
        fixture = '''
variable "test_vcpu" { default = 0 }
variable "test_memory_gib" { default = 0 }
locals {
  total_worker_vcpu = var.test_vcpu
  total_worker_memory_gib = var.test_memory_gib
  monitoring_baseline_worker_vcpu = 328
  monitoring_baseline_worker_memory_gib = 420
}
output "resources" { value = local.vpa_recommender_effective_resources }
output "automatic" { value = local.vpa_recommender_automatic_resources }
output "tier" { value = local.vpa_recommender_cpu_tier }
'''
        fixture += '\noutput "helm_values" { value = yamlencode({' + values + '\n}) }\n'
        tests = '''
run "empty_cluster_uses_baseline" {
  command = plan
  assert {
    condition = output.tier == 1 && output.resources.cpu_request == "100m" && output.resources.cpu_limit == "500m" && output.resources.memory == "128Mi"
    error_message = "Empty clusters must use a small reservation."
  }
}
run "small_cluster_uses_128mi" {
  command = plan
  variables {
    test_vcpu = 64
    test_memory_gib = 64
  }
  assert {
    condition = output.resources.memory == "128Mi" && output.resources.cpu_request == "100m"
    error_message = "Small clusters must not inherit a 512Mi floor."
  }
}
run "just_above_small_boundary_rounds_up" {
  command = plan
  variables {
    test_vcpu = 64
    test_memory_gib = 64.1
  }
  assert {
    condition = output.resources.memory == "192Mi"
    error_message = "Capacity above a boundary must still round up."
  }
}
run "growing_small_cluster_rounds_to_64mi" {
  command = plan
  variables {
    test_vcpu = 96
    test_memory_gib = 128
  }
  assert {
    condition = output.resources.memory == "192Mi"
    error_message = "Intermediate capacity must retain 64Mi memory granularity."
  }
}
run "baseline_boundary" {
  command = plan
  variables {
    test_vcpu = 328
    test_memory_gib = 420
  }
  assert {
    condition = output.tier == 1 && output.resources.memory == "448Mi"
    error_message = "Baseline memory must include discovery overhead and 20% headroom."
  }
}
run "limiting_capacity_bounds_the_tier" {
  command = plan
  variables {
    test_vcpu = 1000
    test_memory_gib = 200
  }
  assert {
    condition = output.tier == 1 && output.resources.memory == "256Mi"
    error_message = "CPU capacity alone must not inflate memory-limited clusters."
  }
}
run "capacity_grows_without_power_of_two_jump" {
  command = plan
  variables {
    test_vcpu = 400
    test_memory_gib = 500
  }
  assert {
    condition = output.tier == 1 && output.resources.cpu_request == "100m" && output.resources.cpu_limit == "500m" && output.resources.memory == "512Mi"
    error_message = "Memory must grow gradually without inflating CPU at baseline capacity."
  }
}
run "large_capacity_uses_canonical_core_and_gib" {
  command = plan
  variables {
    test_vcpu = 1000
    test_memory_gib = 1500
  }
  assert {
    condition = output.tier == 2 && output.resources.cpu_request == "200m" && output.resources.cpu_limit == "1" && output.resources.memory == "1152Mi"
    error_message = "Large capacity must use whole-core CPU and retain non-whole-Gi memory in Mi."
  }
  assert {
    condition = yamldecode(output.helm_values).recommender.resources.requests.cpu == "200m" && yamldecode(output.helm_values).recommender.resources.requests.memory == "1152Mi" && yamldecode(output.helm_values).recommender.resources.limits.cpu == "1" && yamldecode(output.helm_values).recommender.resources.limits.memory == "1152Mi"
    error_message = "The Helm release must consume the effective automatic resources with equal memory request and limit."
  }
  assert {
    condition = !yamldecode(output.helm_values).updater.enabled && !yamldecode(output.helm_values).admissionController.enabled
    error_message = "Sizing must preserve recommendation-only VPA behavior."
  }
}
run "whole_gib_memory_uses_gi" {
  command = plan
  variables {
    test_vcpu = 900
    test_memory_gib = 1200
  }
  assert {
    condition = output.resources.memory == "1Gi"
    error_message = "Exact whole-Gi memory must use canonical Gi units."
  }
}
run "explicit_overrides_are_preserved" {
  command = plan
  variables {
    test_vcpu = 1000
    test_memory_gib = 1500
    vpa_goldilocks = {
      recommender_cpu_request = "150m"
      recommender_cpu_limit = "1500m"
      recommender_memory = "1536Mi"
    }
  }
  assert {
    condition = output.resources.cpu_request == "150m" && output.resources.cpu_limit == "1500m" && output.resources.memory == "1536Mi" && output.automatic.memory == "1152Mi"
    error_message = "Explicit overrides must remain independent of automatic sizing."
  }
  assert {
    condition = yamldecode(output.helm_values).recommender.resources.requests.memory == "1536Mi" && yamldecode(output.helm_values).recommender.resources.limits.cpu == "1500m"
    error_message = "The Helm release must consume explicit resource overrides."
  }
}
run "partial_override_keeps_other_fields_automatic" {
  command = plan
  variables {
    test_vcpu = 400
    test_memory_gib = 500
    vpa_goldilocks = { recommender_cpu_request = "50m" }
  }
  assert {
    condition = output.resources.cpu_request == "50m" && output.resources.cpu_limit == "500m" && output.resources.memory == "512Mi"
    error_message = "A CPU override must not disable automatic memory or CPU limits."
  }
}
run "reject_noncanonical_whole_cpu" {
  command = plan
  variables { vpa_goldilocks = { recommender_cpu_limit = "1000m" } }
  expect_failures = [var.vpa_goldilocks]
}
run "reject_noncanonical_whole_gib" {
  command = plan
  variables { vpa_goldilocks = { recommender_memory = "1024Mi" } }
  expect_failures = [var.vpa_goldilocks]
}
'''
        with tempfile.TemporaryDirectory(prefix="vpa-sizing-tests-") as directory:
            Path(directory, "main.tf").write_text(sizing + fixture)
            Path(directory, "sizing.tftest.hcl").write_text(tests)
            for command in [
                ["tofu", "init", "-backend=false", "-input=false", "-no-color"],
                ["tofu", "test", "-no-color"],
            ]:
                result = subprocess.run(command, cwd=directory, capture_output=True, text=True, timeout=90)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
