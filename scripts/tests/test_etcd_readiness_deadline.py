"""A stuck Talos RPC must not defeat the control-plane health deadline."""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import time
import unittest

SOURCE=Path(__file__).resolve().parents[1].joinpath('deploy.sh').read_text()
FUNCTION=re.search(r'^wait_for_controlplane_etcd_ready\(\) \{\n.*?^\}',SOURCE,re.M|re.S)[0]

class EtcdReadinessDeadlineTest(unittest.TestCase):
    def test_unresponsive_rpc_is_killed_within_the_deadline(self):
        with tempfile.TemporaryDirectory() as tmp:
            tool=Path(tmp)/'talosctl';tool.write_text('#!/bin/sh\nexec sleep 60\n');tool.chmod(0o700)
            harness='cluster_talosconfig_path=unused\nerror() { echo "$*" >&2; }\n'+FUNCTION+'\nwait_for_controlplane_etcd_ready example 192.0.2.1 1\n'
            start=time.monotonic()
            result=subprocess.run(['bash','-c',harness],env={**os.environ,'PATH':tmp+os.pathsep+os.environ['PATH']},capture_output=True,text=True,timeout=8)
            self.assertNotEqual(result.returncode,0);self.assertIn('Timed out waiting for etcd',result.stderr)
            self.assertLess(time.monotonic()-start,7)

if __name__=='__main__':unittest.main()
