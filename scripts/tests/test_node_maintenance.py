import copy
import datetime as dt
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

PATH=Path(__file__).resolve().parents[1]/'node-maintenance.py'
spec=importlib.util.spec_from_file_location('node_maintenance',PATH);M=importlib.util.module_from_spec(spec);spec.loader.exec_module(M)

def node(name='worker'):
    return {'metadata':{'name':name,'resourceVersion':'1','annotations':{}},'status':{'conditions':[{'type':'Ready','status':'True'}]},'spec':{}}

class FakeKubernetes:
    def __init__(self,nodes):self.nodes={n['metadata']['name']:copy.deepcopy(n) for n in nodes};self.patches=[];self.commands=[]
    def verify_controller(self):pass
    def get(self,args):return copy.deepcopy(self.nodes.get(args[1]))
    def patch(self,n,values):
        name=n['metadata']['name'];self.patches.append((name,values))
        for k,v in values.items():
            if v is None:self.nodes[name]['metadata']['annotations'].pop(k,None)
            else:self.nodes[name]['metadata']['annotations'][k]=v
    def run(self,args):
        self.commands.append(args)
        if args[0]=='uncordon':self.nodes[args[1]]['spec']['unschedulable']=False


class RacingKubernetes(M.Kubernetes):
    """Inject kubelet status writes between a fresh GET and each CAS PATCH."""
    def __init__(self, original, status_updates, transition=None):
        super().__init__('unused')
        self.current = copy.deepcopy(original)
        self.status_updates = status_updates
        self.transition = transition
        self.patch_versions = []
        self.reads = 0

    def get(self, args):
        self.reads += 1
        return copy.deepcopy(self.current)

    def status_update(self):
        version = int(self.current['metadata']['resourceVersion']) + 1
        self.current['metadata']['resourceVersion'] = str(version)
        self.current['status']['conditions'][0]['lastHeartbeatTime'] = str(version)

    def run(self, args):
        if args[:2] != ['patch', 'node']:
            raise AssertionError('Unexpected Kubernetes operation')
        payload = json.loads(args[-1])
        version = payload['metadata']['resourceVersion']
        self.patch_versions.append(version)
        if version != self.current['metadata']['resourceVersion']:
            raise M.ResourceConflict('Stale resourceVersion rejected by server')
        if self.status_updates:
            self.status_updates -= 1
            self.status_update()
            if not self.status_updates and self.transition:
                self.transition(self.current)
            raise M.ResourceConflict('Concurrent kubelet status update')
        self.current['metadata']['annotations'].update(payload['metadata']['annotations'])
        return ''

class MaintenanceTest(unittest.TestCase):
    def test_all_nodes_checked_before_any_are_marked(self):
        a=node('a');b=node('b');b['metadata']['annotations'][M.STATE]='fencing';k=FakeKubernetes([a,b])
        with tempfile.TemporaryDirectory() as tmp,self.assertRaisesRegex(ValueError,'recovery'):
            M.begin(k,Path(tmp)/'state.json','owner',['a','b'],600)
        self.assertFalse(k.patches)

    def test_foreign_maintenance_or_cordon_is_not_overwritten(self):
        for mode in ('maintenance','cordon'):
            n=node()
            if mode=='maintenance':n['metadata']['annotations'].update({M.OWNER:'other',M.UNTIL:(M.timestamp()+dt.timedelta(minutes=5)).isoformat()})
            else:n['spec']['unschedulable']=True
            k=FakeKubernetes([n])
            with tempfile.TemporaryDirectory() as tmp,self.assertRaises(ValueError):M.begin(k,Path(tmp)/'state.json','owner',['worker'],600)
            self.assertFalse(k.patches)

    def test_success_restores_annotations_and_cordon(self):
        k=FakeKubernetes([node()])
        with tempfile.TemporaryDirectory() as tmp:
            state=Path(tmp)/'state.json';M.begin(k,state,'owner',['worker','new-unregistered'],600)
            self.assertEqual(k.nodes['worker']['metadata']['annotations'][M.OWNER],'owner')
            k.nodes['worker']['spec']['unschedulable']=True
            M.finish(k,state,'owner')
            self.assertFalse(state.exists());self.assertFalse(k.nodes['worker']['spec']['unschedulable']);self.assertEqual(k.nodes['worker']['metadata']['annotations'],{})

    def test_unready_node_keeps_bounded_lease_and_resumable_state(self):
        k=FakeKubernetes([node()])
        with tempfile.TemporaryDirectory() as tmp:
            state=Path(tmp)/'state.json';M.begin(k,state,'owner',['worker'],600)
            k.nodes['worker']['status']['conditions'][0]['status']='Unknown';M.finish(k,state,'owner')
            self.assertTrue(state.exists());self.assertIn(M.UNTIL,k.nodes['worker']['metadata']['annotations'])

    @mock.patch.object(M.time, 'sleep')
    def test_metadata_conflicts_retry_only_unrelated_status_changes(self, sleep):
        for changed in ('status','recovery','owner','unready'):
            original=node();fresh=copy.deepcopy(original);fresh['metadata']['resourceVersion']='2'
            if changed=='recovery':fresh['metadata']['annotations'][M.STATE]='fencing'
            if changed=='owner':fresh['metadata']['annotations'][M.OWNER]='other'
            if changed=='unready':fresh['status']['conditions'][0]['status']='False'
            k=M.Kubernetes('unused');calls=[]
            def run(args):
                calls.append(args)
                if len(calls)==1:raise M.ResourceConflict('concurrent update')
                return ''
            k.run=run;k.get=lambda _:copy.deepcopy(fresh)
            if changed=='status':
                k.patch(original,{M.OWNER:'mine'});self.assertEqual(json.loads(calls[-1][-1])['metadata']['resourceVersion'],'2')
            else:
                with self.assertRaises(ValueError):k.patch(original,{M.OWNER:'mine'})
                self.assertEqual(len(calls),1)

    def test_fencing_started_during_maintenance_prevents_renewal(self):
        k=FakeKubernetes([node()])
        with tempfile.TemporaryDirectory() as tmp:
            state=Path(tmp)/'state.json';M.begin(k,state,'owner',['worker'],600)
            k.nodes['worker']['metadata']['annotations'][M.STATE]='fencing'
            with self.assertRaisesRegex(ValueError,'recovery'):M.renew(k,state,'owner',600)

    @mock.patch.object(M.time, 'sleep')
    def test_renew_survives_burst_of_unrelated_status_conflicts(self, sleep):
        original = node()
        original['metadata']['annotations'].update({
            M.OWNER: 'mine', M.UNTIL: (M.timestamp() + dt.timedelta(minutes=5)).isoformat()})
        kube = RacingKubernetes(original, status_updates=8)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'state.json'
            M.save(path, {'owner': 'mine', 'nodes': {'worker': {}}})
            M.renew(kube, path, 'mine', 600)
        self.assertEqual(kube.patch_versions, [str(v) for v in range(1, 10)])
        self.assertEqual(kube.reads, 9)  # Renewal's initial GET plus eight retries.
        self.assertEqual(sleep.call_count, 8)
        self.assertEqual(kube.current['metadata']['annotations'][M.OWNER], 'mine')
        self.assertGreater(kube.current['metadata']['annotations'][M.UNTIL],
                           original['metadata']['annotations'][M.UNTIL])

    @mock.patch.object(M.time, 'sleep')
    def test_status_conflict_retries_exhaust_bounded_attempts(self, sleep):
        kube = RacingKubernetes(node(), status_updates=1000)
        with self.assertRaises(M.ResourceConflict):
            kube.patch(node(), {M.OWNER: 'mine'})
        self.assertEqual(kube.patch_versions, [str(v) for v in range(1, 21)])
        self.assertEqual(kube.reads, 19)
        self.assertEqual(sleep.call_count, 19)
        self.assertTrue(all(0 < call.args[0] <= 1 for call in sleep.call_args_list))
        self.assertEqual(kube.current['metadata']['annotations'], {})

    @mock.patch.object(M.time, 'sleep')
    def test_backoff_status_writes_are_refreshed_before_retry(self, sleep):
        kube = RacingKubernetes(node(), status_updates=1)
        sleep.side_effect = lambda _: kube.status_update()
        try:
            kube.patch(node(), {M.OWNER: 'mine'})
        except M.ResourceConflict as exc:
            self.fail(f'Status writes during backoff exhausted {len(kube.patch_versions)} attempts: {exc}')
        self.assertEqual(kube.patch_versions, ['1', '3'])
        self.assertEqual(kube.reads, 1)
        self.assertEqual(sleep.call_count, 1)
        self.assertEqual(kube.current['metadata']['annotations'][M.OWNER], 'mine')

    @mock.patch.object(M.time, 'sleep')
    def test_backoff_guard_changes_are_rejected_before_another_patch(self, sleep):
        for guard in (M.OWNER, M.UNTIL, M.STATE, 'cordon', 'unready'):
            with self.subTest(guard=guard):
                original = node()
                now = M.timestamp()
                if guard != 'unready':
                    original['metadata']['annotations'].update({
                        M.OWNER: 'mine', M.UNTIL: (now + dt.timedelta(minutes=5)).isoformat()})
                kube = RacingKubernetes(original, status_updates=1)
                def update_during_backoff(_):
                    kube.status_update()
                    if guard == 'cordon':
                        kube.current['spec']['unschedulable'] = True
                    elif guard == 'unready':
                        kube.current['status']['conditions'][0]['status'] = 'False'
                    else:
                        kube.current['metadata']['annotations'][guard] = {
                            M.OWNER: 'another-operator',
                            M.UNTIL: (now + dt.timedelta(minutes=15)).isoformat(),
                            M.STATE: 'fencing'}[guard]
                sleep.reset_mock()
                sleep.side_effect = update_during_backoff
                with self.assertRaises(ValueError):
                    kube.patch(original, {M.OWNER: 'mine', M.UNTIL: (now + dt.timedelta(minutes=10)).isoformat()})
                self.assertEqual(len(kube.patch_versions), 1)
                self.assertEqual(kube.reads, 1)
                self.assertEqual(sleep.call_count, 1)

    @mock.patch.object(M.time, 'sleep')
    def test_status_burst_never_bypasses_maintenance_or_cordon_guards(self, sleep):
        for guard in (M.OWNER, M.UNTIL, M.STATE, 'cordon'):
            with self.subTest(guard=guard):
                original = node()
                now = M.timestamp()
                original['metadata']['annotations'].update({
                    M.OWNER: 'mine', M.UNTIL: (now + dt.timedelta(minutes=5)).isoformat()})
                renewed_until = (now + dt.timedelta(minutes=10)).isoformat()
                def transition(fresh):
                    if guard == 'cordon':
                        fresh['spec']['unschedulable'] = True
                    else:
                        fresh['metadata']['annotations'][guard] = {
                            M.OWNER: 'another-operator',
                            M.UNTIL: (now + dt.timedelta(minutes=15)).isoformat(),
                            M.STATE: 'fencing'}[guard]
                kube = RacingKubernetes(original, status_updates=6, transition=transition)
                with self.assertRaisesRegex(ValueError, 'ownership or cordon changed'):
                    kube.patch(original, {M.UNTIL: renewed_until})
                self.assertEqual(kube.patch_versions, [str(v) for v in range(1, 7)])
                self.assertEqual(kube.reads, 6)
                self.assertNotEqual(kube.current['metadata']['annotations'][M.UNTIL], renewed_until)

    @mock.patch.object(M.time, 'sleep')
    def test_status_burst_never_acquires_owner_on_unready_node(self, sleep):
        def become_unready(fresh):
            fresh['status']['conditions'][0]['status'] = 'False'
        kube = RacingKubernetes(node(), status_updates=6, transition=become_unready)
        with self.assertRaisesRegex(ValueError, 'ownership while the node is unready'):
            kube.patch(node(), {M.OWNER: 'mine'})
        self.assertEqual(kube.patch_versions, [str(v) for v in range(1, 7)])
        self.assertEqual(kube.reads, 6)
        self.assertNotIn(M.OWNER, kube.current['metadata']['annotations'])

if __name__=='__main__':unittest.main()
