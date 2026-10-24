"""Cluster map string readers must respect HCL boolean-to-string coercion too."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SOURCE=Path(__file__).resolve().parents[1].joinpath('deploy.sh').read_text()
FUNCTION=re.search(r'^tf_map_string_value\(\) \{\n.*?^\}',SOURCE,re.M|re.S)[0]

class ClusterMapValuesTest(unittest.TestCase):
    def test_string_and_boolean_spellings_have_the_same_flag_value(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'constants.tfvars'
            for value in ('true','false','"true"','"false"'):
                for key in ('image_unpack_sync_fs','"image_unpack_sync_fs"'):
                    p.write_text('constants = {\n  talos = {\n    '+key+' = '+value+' # comment\n  }\n}\n')
                    r=subprocess.run(['bash','-c',FUNCTION+'\ntf_map_string_value "$1" talos image_unpack_sync_fs','test',str(p)],capture_output=True,text=True,check=True)
                    self.assertEqual(r.stdout.strip(),value.strip('"'))

if __name__=='__main__':unittest.main()
