"""Only owned, unshared Ceph metadata may be removed; recheck before mutation."""
import importlib.util
from pathlib import Path
import unittest

PATH=Path(__file__).resolve().parents[1]/'ceph-purge-dependencies.py'
spec=importlib.util.spec_from_file_location('purge_dependencies',PATH);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class CephDependencyTest(unittest.TestCase):
    def plan(self,pools=None,filesystems=None,standbys=()):
        return module.plan_dependencies('example',pools or [],[{'rule_id':1,'rule_name':'replicated_rule'},{'rule_id':2,'rule_name':'example-data'}],['example-data-profile','other-data-profile'],filesystems or [],['example-data'],['example-fs'],standbys=standbys)

    def test_shared_default_rule_and_foreign_profiles_are_preserved(self):
        p=self.plan([{'pool_name':'example-data','crush_rule':2},{'pool_name':'other-data','crush_rule':1}])
        self.assertEqual(p['rules'],['example-data']);self.assertEqual(p['profiles'],['example-data-profile'])

    def test_shared_crush_rule_or_profile_aborts(self):
        for fields in ({'crush_rule':2},{'erasure_code_profile':'example-data-profile'}):
            with self.assertRaisesRegex(ValueError,'shared'):self.plan([{'pool_name':'other-data',**fields}])

    def test_unconfigured_owned_pool_is_not_silently_deleted(self):
        with self.assertRaisesRegex(ValueError,'Unconfigured'):self.plan([{'pool_name':'example-legacy'}])

    def test_mds_serving_foreign_filesystem_blocks(self):
        fs={'id':8,'mdsmap':{'fs_name':'other-fs','info':{'gid1':{'name':'example-mds'}}}}
        with self.assertRaisesRegex(ValueError,'retained filesystem'):self.plan(filesystems=[fs])

    def test_standby_reserved_for_foreign_filesystem_blocks(self):
        fs={'id':8,'mdsmap':{'fs_name':'other-fs','info':{}}}
        with self.assertRaisesRegex(ValueError,'standby'):self.plan(filesystems=[fs],standbys=[{'name':'example-mds','join_fscid':8}])

    def test_shared_mds_serving_target_filesystem_is_preserved(self):
        fs={'id':1,'mdsmap':{'fs_name':'example-fs','info':{'gid1':{'name':'other-mds'}}}}
        self.assertEqual(self.plan(filesystems=[fs])['mds'],[])

    def test_explicit_custom_filesystem_name_owns_its_matching_daemon(self):
        fs={'id':1,'mdsmap':{'fs_name':'custom-fs','info':{'gid1':{'name':'custom-fs'}}}}
        plan=module.plan_dependencies('example',[],[],[],[fs],[],['custom-fs'])
        self.assertEqual(plan['mds'],['custom-fs'])

    def test_unsafe_names_rejected(self):
        for name in ('','-bad','example;touch x','../example'):
            with self.assertRaises(ValueError):module.safe_name(name)

    def test_concurrent_rule_reuse_aborts_before_any_delete(self):
        plan=self.plan();plan.update(daemons=[],auth=[])
        class Remote:
            fs_dump={}
            def inventory(self):
                return ([{'pool_name':'other-data','crush_rule':2}],[{'rule_id':2,'rule_name':'example-data'}],['example-data-profile'],[])
            def run(self,*args,**kwargs):raise AssertionError('must not mutate before checking shared resources')
        with self.assertRaisesRegex(ValueError,'shared'):module.cleanup(Remote(),plan)

if __name__=='__main__':unittest.main()
