import importlib.util
import json
from pathlib import Path
import unittest
PATH=Path(__file__).resolve().parents[1]/'reconcile-kubernetes-components.py'
spec=importlib.util.spec_from_file_location('kubernetes_components',PATH);M=importlib.util.module_from_spec(spec);spec.loader.exec_module(M)

class ComponentsTest(unittest.TestCase):
    def test_existing_custom_registry_is_preserved_when_updating_proxy(self):
        calls=[]
        def run(args,**kwargs):
            calls.append(args)
            return json.dumps({'spec':{'template':{'spec':{'containers':[{'name':'kube-proxy','image':'registry.example.com/proxy:v1.32.1'}]}}}}) if args[0]=='get' else ''
        M.reconcile_proxy({'enabled':True,'image':'registry.example.com/proxy:v1.32.5'},[],execute=run)
        self.assertEqual(calls[1],['set','image','daemonset/kube-proxy','kube-proxy=registry.example.com/proxy:v1.32.5','-n','kube-system'])
        self.assertFalse(any('coredns' in str(c) for c in calls))

    def test_disabled_proxy_does_not_create_or_delete_anything(self):
        calls=[]
        def run(args,**kwargs):calls.append(args);return ''
        M.reconcile_proxy({'enabled':False},[],execute=run);self.assertEqual(len(calls),1)

    def test_missing_enabled_proxy_is_an_error(self):
        with self.assertRaisesRegex(ValueError,'missing'):M.reconcile_proxy({'enabled':True,'image':'example.com/proxy:v1.32.5'},[],execute=lambda *_:'' )

    def test_patch_upgrades_work_on_old_and_new_kubernetes(self):
        for version in ('1.28','1.32','1.36'):M.check_version_transition('v'+version+'.1','v'+version+'.5')

    def test_minor_changes_and_downgrades_need_review_before_mutation(self):
        for current,target in (('v1.32.1','v1.33.1'),('v1.36.5','v1.36.2')):
            with self.assertRaises(ValueError):M.check_version_transition(current,target)

    def test_master_label_and_ipv6_api_address_are_supported(self):
        calls=[]
        def run(args,**kwargs):
            calls.append(args)
            if args[0]=='get':return json.dumps({'items':[{'metadata':{'labels':{'node-role.kubernetes.io/master':''}},'status':{'addresses':[{'type':'InternalIP','address':'2001:db8::1'}]}}]})
            return '{"gitVersion":"v1.28.5"}'
        M.verify_control_planes([],'v1.28.5',execute=run)
        self.assertIn('--server=https://[2001:db8::1]:6443',calls[1])

if __name__=='__main__':unittest.main()
