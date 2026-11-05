"""Read-only convergence checks for monitor propagation and node recovery."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
def load(name,filename):
    spec=importlib.util.spec_from_file_location(name,ROOT/filename)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
CSI=load('csi_monitors','check-csi-monitors.py')
RECOVERY=load('node_recovery','wait-for-node-recovery.py')


class CsiMonitorReadinessTest(unittest.TestCase):
    endpoints={'data':{'data':'a=198.51.100.11:6789,b=198.51.100.12:6789'}}

    def config(self,monitors,cluster='storage',key='config.json'):
        return {'data':{key:json.dumps([{'clusterID':cluster,'monitors':monitors}])}}

    def test_both_legacy_and_modern_configmap_keys_are_supported(self):
        for key in ['config.json','csi-cluster-config-json']:
            self.assertTrue(CSI.matches(self.endpoints,self.config(
                ['198.51.100.12:6789','198.51.100.11:6789'],key=key),'storage'))

    def test_old_extra_missing_and_other_cluster_monitors_are_rejected(self):
        for config in [self.config(['192.0.2.11:6789']),self.config(['198.51.100.11:6789']),
                       self.config(['198.51.100.11:6789','198.51.100.12:6789','192.0.2.11:6789']),
                       self.config(['198.51.100.11:6789','198.51.100.12:6789'],cluster='other'),
                       {'data':{'config.json':'[]'}},{}]:
            with self.subTest(config=config):self.assertFalse(CSI.matches(self.endpoints,config,'storage'))

    def test_waits_for_propagation_instead_of_accepting_the_empty_legacy_map(self):
        calls=[]
        def get(namespace,name):
            calls.append(name)
            if name=='rook-ceph-mon-endpoints':return self.endpoints
            monitors=['192.0.2.11:6789'] if len(calls)==2 else ['198.51.100.11:6789','198.51.100.12:6789']
            return self.config(monitors)
        with patch.object(CSI.time,'sleep') as sleep:
            CSI.wait(get,'rook-ceph','ceph-csi-config','storage',10)
            sleep.assert_called_once()

    def test_timeout_never_treats_a_stale_config_as_ready(self):
        def get(namespace,name):return self.endpoints if name=='rook-ceph-mon-endpoints' else {}
        with self.assertRaisesRegex(ValueError,'no CSI restart'):
            CSI.wait(get,'rook-ceph','ceph-csi-config','storage',0)


class RecoveryWaitTest(unittest.TestCase):
    def node(self,ready=True,state='',cordoned=False):
        return {'metadata':{'name':'worker','annotations':{'remediation.pve-k8s-talos/state':state}},
                'spec':{'unschedulable':cordoned},
                'status':{'conditions':[{'type':'Ready','status':'True' if ready else 'False'}]}}

    def kube(self,node,fences=None):
        class ReadOnly:
            def get(self,args):
                if args==['nodes']:return {'items':[node] if node else []}
                if args==['networkfences']:return {'items':fences or []}
                raise AssertionError('Only node/fence reads are allowed')
        return ReadOnly()

    def test_healthy_unfenced_cluster_passes_without_mutation(self):
        RECOVERY.wait(self.kube(self.node()),0)

    def test_unfinished_recovery_fences_cordons_and_empty_inventory_block(self):
        for node,fences in [(self.node(state='storage-fencing'),[]),(self.node(),[{'metadata':{'name':'worker'}}]),
                            (self.node(ready=False),[]),(self.node(cordoned=True),[]),(None,[])]:
            with self.subTest(node=node,fences=fences):
                with self.assertRaisesRegex(ValueError,'without forcing'):
                    RECOVERY.wait(self.kube(node,fences),0)


if __name__=='__main__':unittest.main()
