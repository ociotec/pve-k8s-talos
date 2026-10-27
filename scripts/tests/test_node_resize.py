"""Exercise resize safety decisions without connecting to infrastructure."""
import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('resize', Path(__file__).resolve().parents[1] / 'resize-nodes.py')
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


def plan():
    variables = {'vms': {f'cp-{i}': {'type': 'cp', 'ip': f'192.0.2.{i}', 'node_name': 'host', 'vm_id': 100+i} for i in range(1,4)}, 'resources': {'cp': {'k8s_node': 'controlplane', 'vcpus': 6, 'memory': 12288}}, 'constants': {'talos': {key+'_'+r: value for key in ['api_server','controller_manager','scheduler'] for r,value in [('cpu','1'),('memory','1Gi')]}}}
    before = {'cpu': [{'cores':4,'type':'host'}], 'memory':[{'dedicated':8192}], 'started':True, 'reboot_after_update':True}
    after = copy.deepcopy(before);after['cpu'][0]['cores']=6;after['memory'][0]['dedicated']=12288;after['reboot_after_update']=False
    return {'variables':{k:{'value':v} for k,v in variables.items()}, 'resource_changes':[{'type':'proxmox_virtual_environment_vm','name':'create_pve_vms','index':n,'change':{'before':copy.deepcopy(before),'after':copy.deepcopy(after),'actions':['update']}} for n in variables['vms']]}


def worker_plan(count=2):
    p = plan()
    p['variables']['resources']['value']['worker'] = {'k8s_node': 'worker', 'vcpus': 27, 'memory': 40960}
    p['resource_changes'] = []
    for i in range(1, count + 1):
        name = f'wk-{i}'
        p['variables']['vms']['value'][name] = {'type': 'worker', 'ip': f'192.0.2.{10+i}', 'node_name': 'host', 'vm_id': 110+i}
        p['resource_changes'].append({
            'type': 'proxmox_virtual_environment_vm', 'name': 'create_pve_vms', 'index': name,
            'change': {'before': {'cpu': [{'cores': 23}], 'memory': [{'dedicated': 33792}], 'started': True},
                       'after': {'cpu': [{'cores': 27}], 'memory': [{'dedicated': 40960}], 'started': True},
                       'actions': ['update']}})
    return p


def arguments(workspace):
    return argparse.Namespace(workspace=workspace, kubeconfig='unused', talosconfig='unused',
                              stable_seconds=0, timeout=1, workload_baseline='baseline.json',
                              maintenance_state='maintenance.json', maintenance_owner='deployment')


class OfflineResizer(M.Resizer):
    def renew_maintenance(self):
        pass

    def workloads(self):
        pass


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

    def test_workers_selected_and_unsafe_worker_changes_rejected(self):
        self.assertEqual(M.resize_candidates(worker_plan())[1], ['wk-1', 'wk-2'])
        for unsafe in ('shrink', 'replacement', 'disk'):
            with self.subTest(change=unsafe):
                p = worker_plan()
                change = p['resource_changes'][1]['change']
                if unsafe == 'shrink': change['after']['cpu'][0]['cores'] = 22
                if unsafe == 'replacement': change['actions'] = ['delete', 'create']
                if unsafe == 'disk': change['after']['disk'] = [{'size': 256}]
                with self.assertRaises(M.ResizeError): M.resize_candidates(p)

    def test_stopped_node_is_allowed_only_with_own_pending_journal(self):
        p = worker_plan()
        p['resource_changes'][0]['change']['before']['started'] = False
        with self.assertRaisesRegex(M.ResizeError, 'unrelated'): M.resize_candidates(p)
        journal = {'node': 'wk-1', 'phase': 'stopped'}
        self.assertEqual(M.resize_candidates(p, journal)[1], ['wk-1', 'wk-2'])
        for journal in ({'node': 'wk-2', 'phase': 'stopped'}, {'node': 'wk-1', 'phase': 'prepared'}):
            with self.assertRaisesRegex(M.ResizeError, 'unrelated'): M.resize_candidates(p, journal)

    def test_inconsistent_etcd_leadership_rejected(self):
        with self.assertRaises(M.ResizeError):M.validate_etcd([{'member':'a','leader':'a','term':'1'},{'member':'b','leader':'b','term':'1'}],2)

    def test_etcd_errors_rejected(self):
        with self.assertRaises(M.ResizeError):M.etcd_rows('NODE  MEMBER  DB SIZE  IN USE  LEADER  RAFT INDEX  RAFT TERM  RAFT APPLIED INDEX  LEARNER  PROTOCOL  STORAGE  ERRORS\n192.0.2.1  a  10 MB  4 MB (40%)  a  10  1  10  false  3.6  3.6  alarm:NOSPACE')

    def test_sequence_stops_before_next_member_on_failure(self):
        class Fake(OfflineResizer):
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
        class Fake(OfflineResizer):
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
        class Fake(OfflineResizer):
            def kube_json(self,*args):return {'metadata':{},'spec':{}}
            def command(self,cmd,timeout=60):self.calls.append(cmd);return ''
        with tempfile.TemporaryDirectory() as tmp:
            r=Fake(argparse.Namespace(workspace=tmp,kubeconfig='unused',talosconfig='unused'));r.calls=[];r.endpoint='192.0.2.2';r.release('cp-1')
            self.assertEqual(len(r.calls),1);self.assertIn('uncordon',r.calls[0])

    def test_stopped_member_resumes_hardware_apply_before_recovery(self):
        class Fake(OfflineResizer):
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

    def test_legacy_journal_migrates_and_legacy_markers_are_released(self):
        with tempfile.TemporaryDirectory() as tmp:
            old = Path(tmp) / '.control-plane-resize.json'
            old.write_text(json.dumps({'node': 'cp-1', 'phase': 'stopped'}))
            old.chmod(0o600)
            r = M.Resizer(arguments(tmp))
            self.assertFalse(old.exists())
            self.assertEqual(json.loads(r.journal.read_text())['node'], 'cp-1')
            self.assertEqual(r.journal.stat().st_mode & 0o777, 0o600)
            r.kube_json = lambda *args: {'metadata': {'annotations': {M.LEGACY_MAINTENANCE: 'true'}},
                                        'spec': {'taints': [{'key': M.LEGACY_MAINTENANCE, 'effect': 'NoSchedule'}]}}
            calls = []
            r.command = lambda command: calls.append(command)
            r.release('cp-1')
            self.assertTrue(any(M.LEGACY_MAINTENANCE + ':NoSchedule-' in c for c in calls))
            self.assertTrue(any(M.LEGACY_MAINTENANCE + '-' in c for c in calls))

    def test_conflicting_resize_journals_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in ('.control-plane-resize.json', '.node-resize.json'):
                (Path(tmp) / name).write_text('{}')
            with self.assertRaisesRegex(M.ResizeError, 'Both legacy and current'):
                M.Resizer(arguments(tmp))

    def test_worker_does_not_relax_etcd_membership_check(self):
        class Health(OfflineResizer):
            def command(self, *args, **kwargs): return ''
            def kube_json(self, *args):
                if 'nodes' in args:
                    return {'items': [{'metadata': {'name': name}, 'status': {'conditions': [{'type': 'Ready', 'status': 'True'}]}}
                                      for name in [*self.cps, 'wk-1']]}
                return {'items': [{'metadata': {'name': component + '-' + name}, 'spec': {'nodeName': name},
                                   'status': {'phase': 'Running', 'conditions': [{'type': 'Ready', 'status': 'True'}]}}
                                  for name in self.cps for component in M.COMPONENTS.values()]}
            def talos(self, name, *args):
                member = name[-1]
                return ('HEADER\n192.0.2.1  ' + member + '  10 MB  4 MB  ' + self.leader +
                        '  10  1  10  false  3.6  3.6')
        with tempfile.TemporaryDirectory() as tmp:
            r = Health(arguments(tmp))
            r.cps = plan()['variables']['vms']['value']
            r.leader = '3'
            r.node_health(excluded='wk-1')
            r.node_health(excluded='cp-1')
            r.leader = 'missing'
            with self.assertRaisesRegex(M.ResizeError, 'leader is not one'):
                r.node_health(excluded='wk-1')

    def test_maintenance_is_renewed_during_long_sequences(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = M.Resizer(arguments(tmp))
            calls = []
            r.command = lambda command: calls.append(command)
            for now in (100, 120, 180):
                with patch.object(M.time, 'monotonic', return_value=now): r.renew_maintenance()
            self.assertEqual(len(calls), 2)
            self.assertTrue(all('renew' in c and '--owner' in c and 'deployment' in c for c in calls))

    def test_maintenance_failure_aborts_before_any_infrastructure_operations(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = M.Resizer(arguments(tmp))
            def fail(command):
                self.assertIn('renew', command)
                raise M.ResizeError('maintenance ownership changed')
            r.command = fail
            with self.assertRaisesRegex(M.ResizeError, 'maintenance ownership changed'): r.run()


class WorkerFlow(OfflineResizer):
    """Run the real journal, drain, resize and recovery flow against fake APIs."""
    def __init__(self, args, data=None, failure=None):
        super().__init__(args)
        self.data = data or worker_plan()
        self.failure = failure
        self.events = []
        self.guests = {n: {'metadata': {'name': n}, 'spec': {},
                           'status': {'nodeInfo': {'bootID': 'old'}, 'capacity': {'cpu': '23', 'memory': '33819936Ki'}}}
                       for n in self.data['variables']['vms']['value'] if n.startswith('wk-')}
        self.stopped = set()

    def message(self, text): pass
    def select_endpoint(self, excluded=None): self.endpoint = '192.0.2.1'
    def node_health(self, excluded=None): return list(self.guests.values()), []
    def kube_json(self, *args): return self.guests[args[2]]
    def wait(self, check, description, stable=0): check()

    def command(self, command, timeout=60):
        for action in ('drain', 'uncordon'):
            if action in command:
                name = command[command.index(action) + 1]
                self.events.append((action, name))
                if self.failure == 'drain' and action == 'drain':
                    raise M.ResizeError('PDB blocks drain')
                self.guests[name]['spec']['unschedulable'] = action == 'drain'
        return ''

    def talos(self, name, *args):
        if args[0] == 'get':
            return json.dumps({'metadata': {'id': 'v1alpha1'}, 'spec': 'machine: {}'})
        if args[0] != 'shutdown':
            raise AssertionError('Worker must not receive control-plane patches or etcd requests')
        self.events.append(('shutdown', name))
        self.stopped.add(name)

    def pve(self, name, suffix):
        if suffix == 'status/current': return {'status': 'stopped' if name in self.stopped else 'running'}
        wanted = self.desired(name)
        return {'cores': wanted['cores'], 'memory': wanted['memory']}

    def tofu(self, *args):
        if args[0] == 'show': return json.dumps(self.data)
        if args[0] != 'apply': return ''
        targets = [a for a in args if a.startswith('-target=')]
        assert len(targets) == 1
        name = json.loads(targets[0].split('[', 1)[1][:-1])
        assert name in self.stopped
        self.events.append(('apply', name))
        if self.failure == 'apply': raise M.ResizeError('hardware apply failed')
        self.stopped.remove(name)
        self.guests[name]['status'] = {'nodeInfo': {'bootID': 'new'}, 'capacity': {'cpu': '27', 'memory': '41314304Ki'}}
        if self.failure == 'capacity': self.guests[name]['status']['capacity']['cpu'] = '23'
        if self.failure == 'memory': self.guests[name]['status']['capacity']['memory'] = '33819936Ki'
        return ''

    def workloads(self):
        resumed = [n for n in self.guests if self.guests[n]['status']['nodeInfo']['bootID'] == 'new'
                   and not self.guests[n]['spec'].get('unschedulable')]
        if resumed:
            self.events.append(('services', resumed[-1]))
            if self.failure == 'services': raise M.ResizeError('services not recovered')


class WorkerSequence(unittest.TestCase):
    def test_workers_finish_recovery_and_services_before_next_drain(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = WorkerFlow(arguments(tmp))
            r.data['variables']['constants']['value']['talos'] = {}  # No CP resource patches required.
            r.run()
            self.assertEqual(r.events[:5], [('drain', 'wk-1'), ('shutdown', 'wk-1'), ('apply', 'wk-1'),
                                            ('uncordon', 'wk-1'), ('services', 'wk-1')])
            self.assertLess(r.events.index(('services', 'wk-1')), r.events.index(('drain', 'wk-2')))
            self.assertIn(('services', 'wk-2'), r.events)
            self.assertFalse(r.journal.exists())

    def test_failure_never_touches_the_next_worker(self):
        for failure in ('drain', 'apply', 'capacity', 'memory', 'services'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                r = WorkerFlow(arguments(tmp), failure=failure)
                with self.assertRaises(M.ResizeError): r.run()
                self.assertTrue(r.journal.exists())
                self.assertFalse(any(name == 'wk-2' for _, name in r.events))
                if failure == 'drain': self.assertFalse(any(action == 'shutdown' for action, _ in r.events))
                if failure in ('capacity', 'memory'): self.assertFalse(any(action == 'uncordon' for action, _ in r.events))

    def test_resume_stopped_worker_before_next_worker(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = WorkerFlow(arguments(tmp), failure='apply')
            with self.assertRaisesRegex(M.ResizeError, 'hardware apply failed'): r.run()
            r.failure = None
            r.events.clear()
            r.data['resource_changes'][0]['change']['before']['started'] = False
            r.run()
            self.assertEqual(r.events[0], ('apply', 'wk-1'))
            self.assertLess(r.events.index(('services', 'wk-1')), r.events.index(('drain', 'wk-2')))
            self.assertFalse(r.journal.exists())

    def test_resume_after_hardware_apply_checks_recovery_without_another_shutdown(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = WorkerFlow(arguments(tmp), failure='services')
            with self.assertRaisesRegex(M.ResizeError, 'services not recovered'): r.run()
            r.failure = None
            r.events.clear()
            r.data['resource_changes'][0]['change']['before'] = copy.deepcopy(r.data['resource_changes'][0]['change']['after'])
            r.run()
            self.assertFalse(any(action in ('drain', 'shutdown', 'apply') and name == 'wk-1' for action, name in r.events))
            self.assertLess(r.events.index(('services', 'wk-1')), r.events.index(('drain', 'wk-2')))

    def test_worker_only_resize_supports_a_single_control_plane(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = worker_plan()
            for name in ('cp-2', 'cp-3'): del data['variables']['vms']['value'][name]
            r = WorkerFlow(arguments(tmp), data=data)
            r.run()
            self.assertIn(('services', 'wk-2'), r.events)

    def test_mixed_resize_keeps_control_plane_leader_last_before_workers(self):
        class Ordered(WorkerFlow):
            def talos(self, name, *args):
                member = name[-1]
                return 'HEADER\n192.0.2.1  ' + member + '  10 MB  4 MB  3  10  1  10  false  3.6  3.6'
            def resize(self, name): self.events.append(name)
        with tempfile.TemporaryDirectory() as tmp:
            data = worker_plan()
            data['resource_changes'] = list(reversed(data['resource_changes'] + plan()['resource_changes']))
            r = Ordered(arguments(tmp), data=data)
            r.run()
            self.assertEqual(r.events, ['cp-1', 'cp-2', 'cp-3', 'wk-1', 'wk-2'])


class DeployIntegration(unittest.TestCase):
    source = Path(__file__).resolve().parents[1].joinpath('deploy.sh').read_text()

    def harness(self, directory):
        definitions = '\n'.join(re.search(r'^' + name + r'\(\) \{\n.*?^\}', self.source, re.M | re.S)[0]
                                for name in ('node_resize_pending', 'prepare_root_workload_baseline', 'handle_deploy_exit'))
        return r'''
set -euo pipefail
cluster_root_workspace="$FIXTURES"
root_workload_baseline="$FIXTURES/baseline.json"
node_maintenance_state="$FIXTURES/maintenance.json"
node_maintenance_owner=deployment
cluster_kubeconfig_path=unused
script_dir=unused
state_sync_armed=true
state_sync_finalized=false
error() { echo "$*" >&2; }
report_current_section_failure() { :; }
persist_cluster_runtime_state() { echo "persist $*" >> "$FIXTURES/calls"; }
python3() {
  echo "$*" >> "$FIXTURES/calls"
  if [[ "$*" == *' finish '* ]]; then rm "$node_maintenance_state"; fi
}
''' + definitions

    def run_shell(self, directory, action):
        return subprocess.run(['bash', '-c', self.harness(directory) + '\n' + action],
                              env={**os.environ, 'FIXTURES': str(directory)}, capture_output=True, text=True)

    def test_resume_preserves_baseline_without_a_premature_service_health_check(self):
        for journal in ('.node-resize.json', '.control-plane-resize.json'):
            with self.subTest(journal=journal), tempfile.TemporaryDirectory() as tmp:
                d = Path(tmp)
                (d / journal).write_text('{}')
                (d / 'baseline.json').write_text('original baseline')
                result = self.run_shell(d, 'prepare_root_workload_baseline')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse((d / 'calls').exists())
                self.assertEqual((d / 'baseline.json').read_text(), 'original baseline')

    def test_resume_without_baseline_blocks_but_fresh_deployment_captures_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / '.node-resize.json').write_text('{}')
            result = self.run_shell(d, 'prepare_root_workload_baseline')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('no workload baseline', result.stderr)
            (d / '.node-resize.json').unlink()
            result = self.run_shell(d, 'prepare_root_workload_baseline')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('--capture', (d / 'calls').read_text())

    def test_failure_preserves_pending_resize_protection_and_still_persists_runtime_state(self):
        for journal in ('.node-resize.json', '.control-plane-resize.json', None):
            with self.subTest(journal=journal), tempfile.TemporaryDirectory() as tmp:
                d = Path(tmp)
                (d / 'baseline.json').write_text('{}')
                (d / 'maintenance.json').write_text('{}')
                if journal: (d / journal).write_text('{}')
                result = self.run_shell(d, '(exit 1) || handle_deploy_exit')
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual((d / 'maintenance.json').exists(), bool(journal))
                self.assertEqual((d / 'baseline.json').exists(), bool(journal))
                calls = (d / 'calls').read_text()
                self.assertEqual(' finish ' in calls, not bool(journal))
                self.assertIn('persist failed', calls)


if __name__=='__main__':unittest.main()
