"""Exercise resize safety decisions without connecting to infrastructure."""
import argparse
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('resize', Path(__file__).resolve().parents[1] / 'resize-control-planes.py')
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


def plan():
    variables = {'vms': {f'cp-{i}': {'type': 'cp', 'ip': f'192.0.2.{i}', 'node_name': 'host', 'vm_id': 100+i} for i in range(1,4)}, 'resources': {'cp': {'k8s_node': 'controlplane', 'vcpus': 6, 'memory': 12288}}, 'constants': {'talos': {key+'_'+r: value for key in ['api_server','controller_manager','scheduler'] for r,value in [('cpu','1'),('memory','1Gi')]}}}
    before = {'cpu': [{'cores':4,'type':'host'}], 'memory':[{'dedicated':8192}], 'started':True, 'reboot_after_update':True}
    after = copy.deepcopy(before);after['cpu'][0]['cores']=6;after['memory'][0]['dedicated']=12288;after['reboot_after_update']=False
    return {'variables':{k:{'value':v} for k,v in variables.items()}, 'resource_changes':[{'type':'proxmox_virtual_environment_vm','name':'create_pve_vms','index':n,'change':{'before':copy.deepcopy(before),'after':copy.deepcopy(after),'actions':['update']}} for n in variables['vms']]}


class Decisions(unittest.TestCase):
    def test_resource_patch_preserves_legacy_and_native_active_contracts(self):
        patch = {'cluster': {field: {'resources': {'requests': {'cpu': '1', 'memory': '1Gi'}}} for field in M.COMPONENTS}}
        self.assertEqual(json.loads(M.resource_patch('machine: {}\n', patch)), patch)
        native = '\n---\n'.join('apiVersion: v1alpha1\nkind: ' + kind for kind in M.DOCUMENTS.values())
        documents = [json.loads(doc) for doc in M.resource_patch(native, patch).split('\n---\n')]
        self.assertEqual([doc['kind'] for doc in documents], list(M.DOCUMENTS.values()))
        self.assertTrue(all(doc['resources']['requests']['cpu'] == '1' for doc in documents))

    def test_resource_patch_handles_components_with_different_formats(self):
        patch = {'cluster': {'apiServer': {'resources': {}}, 'scheduler': {'resources': {}}}}
        documents = [json.loads(doc) for doc in M.resource_patch('kind: KubeAPIServerConfig\n', patch).split('\n---\n')]
        self.assertEqual(documents[0], {'cluster': {'scheduler': {'resources': {}}}})
        self.assertEqual(documents[1]['kind'], 'KubeAPIServerConfig')

    def test_all_existing_members_selected(self):
        self.assertEqual(M.resize_candidates(plan())[1],['cp-1','cp-2','cp-3'])

    def test_replacement_rejected_before_any_shutdown(self):
        p=plan();p['resource_changes'][1]['change']['actions']=['delete','create']
        with self.assertRaisesRegex(M.ResizeError,'replacement'):M.resize_candidates(p)

    def test_shrink_rejected(self):
        p=plan();p['resource_changes'][0]['change']['after']['memory'][0]['dedicated']=4096
        with self.assertRaisesRegex(M.ResizeError,'shrinking'):M.resize_candidates(p)

    def test_mixed_change_rejected(self):
        p=plan();p['resource_changes'][0]['change']['after']['started']=False
        with self.assertRaisesRegex(M.ResizeError,'unrelated'):M.resize_candidates(p)

    def test_initial_creation_left_to_bootstrap(self):
        p=plan()
        for r in p['resource_changes']:r['change']['before']=None;r['change']['actions']=['create']
        self.assertEqual(M.resize_candidates(p)[1],[])

    def test_inconsistent_etcd_leadership_rejected(self):
        with self.assertRaises(M.ResizeError):M.validate_etcd([{'member':'a','leader':'a','term':'1'},{'member':'b','leader':'b','term':'1'}],2)

    def test_etcd_errors_rejected(self):
        with self.assertRaises(M.ResizeError):M.etcd_rows('NODE  MEMBER  DB SIZE  IN USE  LEADER  RAFT INDEX  RAFT TERM  RAFT APPLIED INDEX  LEARNER  PROTOCOL  STORAGE  ERRORS\n192.0.2.1  a  10 MB  4 MB (40%)  a  10  1  10  false  3.6  3.6  alarm:NOSPACE')

    def test_sequence_stops_before_next_member_on_failure(self):
        class Fake(M.Resizer):
            def tofu(self,*args):return json.dumps(plan()) if args[0]=='show' else ''
            def select_endpoint(self,excluded=None):pass
            def node_health(self,excluded=None):pass
            def talos(self,name,*args):
                member=name[-1]
                return 'NODE  MEMBER  DB SIZE  IN USE  LEADER  RAFT INDEX  RAFT TERM  RAFT APPLIED INDEX  LEARNER  PROTOCOL  STORAGE\n192.0.2.'+member+'  '+member+'  10 MB  4 MB (40%)  3  10  1  10  false  3.6  3.6'
            def resize(self,name):
                self.calls.append(name)
                if name=='cp-2':raise M.ResizeError('recovery failed')
        with tempfile.TemporaryDirectory() as tmp:
            r=Fake(argparse.Namespace(workspace=tmp,kubeconfig='unused',talosconfig='unused',stable_seconds=30,timeout=1));r.calls=[]
            with self.assertRaisesRegex(M.ResizeError,'recovery failed'):r.run()
            self.assertEqual(r.calls,['cp-1','cp-2'])

    def test_failed_recovery_keeps_journal_and_does_not_release_node(self):
        class Fake(M.Resizer):
            def command(self, cmd, timeout=60):
                self.calls.append(cmd)
                return ''
            def select_endpoint(self, excluded=None):self.endpoint='192.0.2.2'
            def node_health(self, excluded=None):pass
            def kube_json(self,*args):return {'metadata':{},'spec':{}}
            def desired(self,name):return self.entry['desired']
            def recovered(self,entry):raise M.ResizeError('unhealthy etcd')
            def wait(self,check,description,stable=0):check()
            def message(self,text):pass
        with tempfile.TemporaryDirectory() as tmp:
            r=Fake(argparse.Namespace(workspace=tmp,kubeconfig='unused',talosconfig='unused',stable_seconds=30,timeout=1));r.calls=[]
            r.entry={'node':'cp-1','phase':'applied','desired':{'cores':6,'memory':12288},'boot_id':'old'};r.save(r.entry)
            with self.assertRaisesRegex(M.ResizeError,'unhealthy etcd'):r.resize('cp-1')
            self.assertTrue(r.journal.exists());self.assertFalse(any('uncordon' in cmd for cmd in r.calls))

    def test_release_is_safe_after_partial_cleanup(self):
        class Fake(M.Resizer):
            def kube_json(self,*args):return {'metadata':{},'spec':{}}
            def command(self,cmd,timeout=60):self.calls.append(cmd);return ''
        with tempfile.TemporaryDirectory() as tmp:
            r=Fake(argparse.Namespace(workspace=tmp,kubeconfig='unused',talosconfig='unused'));r.calls=[];r.endpoint='192.0.2.2';r.release('cp-1')
            self.assertEqual(len(r.calls),1);self.assertIn('uncordon',r.calls[0])

    def test_stopped_member_resumes_hardware_apply_before_recovery(self):
        class Fake(M.Resizer):
            def command(self,cmd,timeout=60):self.calls.append(cmd);return ''
            def select_endpoint(self,excluded=None):self.endpoint='192.0.2.2'
            def node_health(self,excluded=None):pass
            def kube_json(self,*args):return {'metadata':{},'spec':{}}
            def desired(self,name):return self.entry['desired']
            def recovered(self,entry):self.calls.append(['recovered'])
            def tofu(self,*args):self.calls.append(['tofu',*args])
            def wait(self,check,description,stable=0):check()
            def message(self,text):pass
        with tempfile.TemporaryDirectory() as tmp:
            r=Fake(argparse.Namespace(workspace=tmp,kubeconfig='unused',talosconfig='unused',stable_seconds=30,timeout=1));r.calls=[]
            r.entry={'node':'cp-1','phase':'stopped','desired':{'cores':6,'memory':12288},'boot_id':'old'};r.save(r.entry);r.resize('cp-1')
            self.assertFalse(r.journal.exists());self.assertIn('-target='+M.VM+'["cp-1"]',r.calls[0]);self.assertEqual(r.calls[1],['recovered'])


if __name__=='__main__':unittest.main()
