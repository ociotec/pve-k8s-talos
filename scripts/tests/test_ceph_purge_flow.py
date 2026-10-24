"""Run the real destructive orchestration exclusively against a local fake transport."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]

class CephPurgeFlowTest(unittest.TestCase):
    def run_purge(self,fail=False,inspect=False,backup=False,preflight=False):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);ssh=root/'ssh';shutil.copy(Path(__file__).with_name('fixtures')/'ceph_purge_ssh.py',ssh);ssh.chmod(0o755)
            state={'mon':False,'explicit':False,'pools':[{'pool_name':'example-fs-meta','crush_rule':1},{'pool_name':'example-fs-data','crush_rule':2},{'pool_name':'example-rbd','crush_rule':1},{'pool_name':'other-data','crush_rule':1}],
                   'filesystems':[{'id':1,'mdsmap':{'fs_name':'example-fs','info':{'gid1':{'name':'example-fs'}}}}],
                   'rules':[{'rule_id':1,'rule_name':'replicated_rule'},{'rule_id':2,'rule_name':'example-fs-data'}],
                   'profiles':['example-fs-data-profile','other-profile'],'auth':['mds.example-fs','client.admin'],
                   'directories':{'192.0.2.10':[],'192.0.2.11':['ceph-example-fs']},'destroyed_mds_hosts':[]}
            if backup:state.update(images={'example-rbd':['recovery-parent']},snapshots={'example-rbd/recovery-parent':[{'name':'recovery-snapshot'}]})
            statepath=root/'state.json';statepath.write_text(json.dumps(state))
            constants=root/'ceph.tf';constants.write_text('''locals {
 ceph_mode = "external"
 ceph_name_prefix = "example"
 ceph_external = {
  ssh_host = "192.0.2.10"
 }
 ceph_block_replicated = {
  enabled = true
  pool_name = "example-rbd"
 }
 ceph_filesystem_replicated = {
  enabled = true
  filesystem_name = "example-fs"
  metadata_pool_name = "example-fs-meta"
  data_pool_name = "example-fs-data"
 }
}
''')
            env={**os.environ,'PATH':str(root)+os.pathsep+os.environ['PATH'],'CEPH_TEST_STATE':str(statepath)}
            if fail:env['CEPH_TEST_FAIL_DELETE']='example-rbd'
            cmd=['bash',str(ROOT/'scripts/purge-external-ceph.sh'),'--cluster-name','example','--ceph-constants',str(constants)]
            if inspect:cmd.append('--inspect-only')
            if preflight:cmd.append('--preflight-only')
            result=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=30)
            after=json.loads(statepath.read_text())
            second=None if fail or result.returncode else subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=30)
            return result,after,second

    def test_cross_host_dependencies_removed_and_shared_objects_preserved(self):
        r,state,second=self.run_purge();self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual([p['pool_name'] for p in state['pools']],['other-data'])
        self.assertEqual(state['rules'],[{'rule_id':1,'rule_name':'replicated_rule'}]);self.assertEqual(state['profiles'],['other-profile'])
        self.assertEqual(state['auth'],['client.admin']);self.assertEqual(state['destroyed_mds_hosts'],['192.0.2.11'])
        self.assertFalse(state['mon']);self.assertFalse(state['explicit'])
        self.assertNotIn('FIXTURE-SECRET',r.stdout+r.stderr)
        self.assertIsNotNone(second);self.assertEqual(second.returncode,0,second.stdout+second.stderr)

    def test_inspection_does_not_mutate_any_resources(self):
        r,state,_=self.run_purge(inspect=True);self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual(len(state['pools']),4);self.assertEqual(len(state['filesystems']),1)
        self.assertEqual(len(state['profiles']),2);self.assertFalse(state['destroyed_mds_hosts'])
        self.assertFalse(state['mon']);self.assertFalse(state['explicit'])

    def test_backup_dependencies_block_before_any_storage_is_removed(self):
        r,state,_=self.run_purge(backup=True);self.assertNotEqual(r.returncode,0)
        self.assertIn('snapshots or trashed images',r.stderr)
        self.assertEqual(len(state['pools']),4);self.assertEqual(len(state['filesystems']),1)
        self.assertFalse(state['mon']);self.assertFalse(state['destroyed_mds_hosts'])

    def test_preflight_checks_backups_without_mutations(self):
        for backup in (False, True):
            r,state,_=self.run_purge(preflight=True,backup=backup)
            self.assertEqual(r.returncode == 0, not backup, r.stdout+r.stderr)
            self.assertEqual(len(state['pools']),4);self.assertEqual(len(state['filesystems']),1)
            self.assertFalse(state['mon']);self.assertFalse(state['destroyed_mds_hosts'])

    def test_pool_deletion_failure_restores_global_ceph_option(self):
        r,state,_=self.run_purge(fail=True);self.assertNotEqual(r.returncode,0)
        self.assertFalse(state['mon']);self.assertFalse(state['explicit'])
        self.assertEqual(state['destroyed_mds_hosts'],[])

if __name__=='__main__':unittest.main()
