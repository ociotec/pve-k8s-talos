"""Exercise production Talos data templates with current and older API versions."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(os.environ.get("RUN_TALOS_PROVIDER_COMPATIBILITY_TESTS") == "1" and shutil.which("tofu"),
                     "Set RUN_TALOS_PROVIDER_COMPATIBILITY_TESTS=1 for the local provider integration test")
class TalosProviderCompatibilityTest(unittest.TestCase):
    def test_legacy_and_current_configuration_generation(self):
        fixture = '''
terraform {
  required_providers {
    talos = { source = "siderolabs/talos", version = "0.12.0" }
  }
}
variable "constants" { type = map(any) }
variable "proxy_disabled" { default = false }
# Disposable local credentials only. No machine apply or bootstrap resource exists.
resource "talos_machine_secrets" "machine_secrets" {
  talos_version = var.constants["talos"]["version"]
}
locals {
  image_unpack_sync_fs = false
  image_unpack_sync_fs_supported = true
  image_unpack_sync_fs_patch = ""
  controlplane_vms = { cp = { ip = "192.0.2.10" } }
  network_interface_patches = { for name in ["cp", "worker"] : name => (
    tonumber(split(".", trimprefix(var.constants["talos"]["version"], "v"))[1]) >= 14 ?
    yamlencode({apiVersion="v1alpha1",kind="KubeProxyConfig",enabled=!var.proxy_disabled}) :
    yamlencode({cluster={proxy={disabled=var.proxy_disabled}}})
  ) }

}
'''
        for role, name in (("controlplane", "cp"), ("worker", "worker")):
            template = (ROOT / "templates" / (role + "-data.template.tf")).read_text()
            fixture += template.replace("__SAFE_NAME__", name).replace("__NAME__", name).replace("__PRIMARY_CONTROLPLANE__", "cp")
        fixture += '''
locals {
  configurations = {
    cp = data.talos_machine_configuration.machineconfig_cp
    worker = data.talos_machine_configuration.machineconfig_worker
  }
}
locals {
  controlplane_machine_config = { cp = local.configurations.cp.machine_configuration }
}
output "requested_version_used" {
  value = alltrue([for config in local.configurations :
    trimprefix(config.talos_version, "v") == trimprefix(var.constants["talos"]["version"], "v")])
}
output "configuration_generated" {
  value = alltrue([for config in local.configurations : length(config.machine_configuration) > 0])
  sensitive = true
}
output "legacy_layout" {
  value = alltrue([for config in local.configurations :
    length(regexall("(?m)^kind: KubeNodeConfig$", config.machine_configuration)) == 0])
  sensitive = true
}
'''
        # Use the production version-aware proxy document selector and output too.
        proxy_source = (ROOT / "templates/talos.template.tf").read_text()
        fixture += "locals {" + proxy_source.split("locals {", 1)[1].split('data "talos_client_configuration"', 1)[0]
        cases = [("110", "v1.10.9", "1.32.9"), ("113", "v1.13.5", "1.36.2"), ("114", "v1.14.4", "1.36.5")]
        tests = ""
        for case, talos, kubernetes in cases:
            tests += '''
run "talos_CASE" {
  command = apply
  variables {
    constants = { talos = {
      cluster_name = "compatibility.example"
      version = "TALOS"
      kubernetes_version = "KUBERNETES"
    } }
  }
  assert {
    condition = output.configuration_generated && output.requested_version_used
    error_message = "Both production templates must generate the requested Talos version."
  }
'''.replace("CASE", case).replace("TALOS", talos).replace("KUBERNETES", kubernetes)
            tests += '\n  assert {\n    condition = output.kube_proxy_configuration.enabled && output.kube_proxy_configuration.image == "registry.k8s.io/kube-proxy:v' + kubernetes + '"\n    error_message = "Proxy reconciliation must read the selected image from old and new Talos layouts."\n  }\n'
            if case != "114":
                tests += '''
  assert {
    condition = output.legacy_layout
    error_message = "Older Talos clusters must not acquire 1.14-only configuration documents."
  }
'''
            tests += "}\n"
        tests += '\nrun "disabled_proxy_114" {\n command = apply\n variables {\n  constants = { talos = { cluster_name = "compatibility.example", version = "v1.14.4", kubernetes_version = "1.36.5" } }\n  proxy_disabled = true\n }\n assert {\n  condition = !output.kube_proxy_configuration.enabled\n  error_message = "Disabled kube-proxy must remain disabled on Talos 1.14."\n }\n}\n'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            path.chmod(0o700)
            (path / "main.tf").write_text(fixture)
            (path / "compatibility.tftest.hcl").write_text(tests)
            patches = path / "patches"
            patches.mkdir()
            for name in ("machine-cp.yaml", "machine-worker.yaml", "disable-aslr.yaml", "qemu.yaml"):
                (patches / name).write_text("machine: {}\n")
            shutil.copyfile(ROOT / ".terraform.lock.hcl", path / ".terraform.lock.hcl")
            for command in (["tofu", "init", "-backend=false", "-no-color", "-input=false"],
                            ["tofu", "test", "-no-color"]):
                result = subprocess.run(command, cwd=path, capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
