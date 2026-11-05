"""Verify infra guest networking and distinguish updates from first provisioning."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1].joinpath("deploy-infra-vm.sh").read_text()
VERIFY = re.search(r"^verify_infra_vm_ready\(\) \{\n.*?(?=^clear_stale_lock_if_present\(\))",
                   SOURCE, re.M | re.S)[0]


class InfraReadinessTest(unittest.TestCase):
    def verify(self, existing="old-boot", secondary="198.51.100.10", default_device="eth0"):
        with tempfile.TemporaryDirectory() as directory:
            ip = Path(directory, "ip")
            ip.write_text('''#!/usr/bin/env python3
import os, sys
print(os.environ["ADDRESSES"] if sys.argv[-1] == "addr" else os.environ["ROUTES"])
''')
            ip.chmod(0o755)
            links = [dict(ifname="eth0", addr_info=[dict(local="192.0.2.10", prefixlen=24)])]
            if secondary:
                links.append(dict(ifname="eth1", addr_info=[dict(local=secondary, prefixlen=24)]))
            harness = r'''
set -euo pipefail
infra_vm_ip=192.0.2.10
infra_vm_name=bootstrap-example
infra_vm_workspace=unused
discovery_enabled=false
docker_enabled=false
start_timer() { echo 0; }
render_elapsed() { echo 0; }
message() { :; }
reset_infra_vm_known_host() { :; }
wait_for_infra_vm_ssh() { :; }
wait_for_infra_vm_reboot_if_needed() { echo reboot >> "$CALLS"; }
tofu() { echo 198.51.100.10/24; }
ssh_infra_vm() {
  case "$*" in
    *boot_id*) echo new-boot ;;
    *cloud-init*) : ;;
    python3*) bash -c "$*" ;;
    *systemctl*) : ;;
    *) echo 'Unexpected guest command' >&2; return 1 ;;
  esac
}
'''
            calls = Path(directory, "calls")
            env = {**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"],
                   "infra_vm_existing_boot_id": existing, "CALLS": str(calls),
                   "ADDRESSES": json.dumps(links),
                   "ROUTES": json.dumps([dict(dst="default", dev=default_device)])}
            result = subprocess.run(["bash", "-c", harness + VERIFY + "\nverify_infra_vm_ready"],
                                    env=env, capture_output=True, text=True)
            return result, calls.exists()

    def test_existing_guest_does_not_wait_for_another_provisioning_reboot(self):
        result, reboot = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(reboot)

    def test_new_guest_still_waits_for_its_provisioning_reboot(self):
        result, reboot = self.verify(existing="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(reboot)

    def test_missing_guest_address_is_a_deployment_failure(self):
        result, _ = self.verify(secondary="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("secondary IPv4 address", result.stderr)

    def test_a_default_route_on_the_secondary_nic_is_rejected(self):
        result, _ = self.verify(default_device="eth1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("default routing", result.stderr)


if __name__ == "__main__":
    unittest.main()
