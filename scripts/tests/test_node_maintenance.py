import copy
import datetime as dt
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

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

    def test_metadata_conflicts_retry_only_unrelated_status_changes(self):
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

if __name__=='__main__':unittest.main()
