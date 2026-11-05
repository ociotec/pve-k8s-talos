"""Exercise the exact guarded bootstrap path without a cluster or VM mutation."""
import copy
import importlib.util
import json
import os
import re
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('network_bootstrap', ROOT / 'bootstrap-secondary-network.py')
BOOT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOOT)


def fixture():
    workers = {f'worker-{n}': {'ip':f'192.0.2.{20+n}', 'ip2':f'198.51.100.{20+n}',
               'vm_id':100+n, 'node_name':f'pve{n}'} for n in [1,2]}
    return {'workers':workers, 'all_ips':[vm[k] for vm in workers.values() for k in ['ip','ip2']],
            'prefix':'24', 'gateway':'192.0.2.1',
            'secondary':{'bridge_device':'vmbr-data','vlan_tag':'','net_size':'24'}}


class FakeCommands:
    def __init__(self, workspace, inventory):
        self.workspace, self.inventory = workspace, inventory
        self.calls, self.live = [], {}
        self.pending, self.incompatible, self.reboot_on_apply, self.changed_route = None, None, False, False
        self.boot = '00000000-0000-0000-0000-000000000001'
        self.plan = {'resource_changes':[]}
        for name, vm in inventory['workers'].items():
            primary = {'deviceSelector':{'hardwareAddr':'02:00:00:00:00:01'},
                       'addresses':[vm['ip']+'/24'],
                       'routes':[{'network':'0.0.0.0/0','gateway':inventory['gateway']}], 'mtu':1400}
            self.live[vm['ip']] = {'version':'v1alpha1','machine':{'network':{'interfaces':[primary]},
                                   'env':{'PRESERVE':'unchanged'}}}
            old = {'vm_id':vm['vm_id'],'node_name':vm['node_name'], 'reboot_after_update':True,
                   'network_device':[{'bridge':'vmbr-main','mac_address':'02:00:00:00:00:01'}]}
            new = copy.deepcopy(old);new['reboot_after_update']=False
            new['network_device'].append({'bridge':'vmbr-data','vlan_id':0,'mac_address':None})
            self.plan['resource_changes'].append({'mode':'managed','type':'proxmox_virtual_environment_vm',
                'name':'create_pve_vms','index':name,'change':{'actions':['update'],'before':old,'after':new}})
            self.plan['resource_changes'].append({'mode':'managed','type':'local_sensitive_file',
                'name':'secondary_network_worker_machine_config','index':name,
                'change':{'actions':['delete','create'],'before':{},
                          'after':{'filename':'./machineconfig-'+name+'.yaml'}}})

    def tofu(self, *args, **kwargs):
        self.calls.append(('tofu',*args))
        if args[0]=='show':return json.dumps(self.plan)
        if args[0]=='apply':
            for name, vm in self.inventory['workers'].items():
                rendered=copy.deepcopy(self.live[vm['ip']])
                rendered['machine']['network']['interfaces'].append({
                    'deviceSelector':{'hardwareAddr':'02:00:00:00:00:02'},'addresses':[vm['ip2']+'/24']})
                (self.workspace/('machineconfig-'+name+'.yaml')).write_text(yaml.safe_dump(rendered))
            if self.reboot_on_apply:self.boot='00000000-0000-0000-0000-000000000002'
        return ''

    def talos(self, ip, *args):
        self.calls.append(('talos',ip,*args))
        if args[0]=='read':return self.boot+'\n'
        if args[:2]==('get','machineconfig'):
            active={'metadata':{'id':'v1alpha1'},'spec':yaml.safe_dump(self.live[ip])}
            persistent=copy.deepcopy(active);persistent['metadata']['id']='persistent'
            if ip==self.pending:persistent['spec']+='cluster: {pending: true}\n'
            return json.dumps(active)+'\n'+json.dumps(persistent)
        if args[:2]==('get','routespecs'):
            gateway='192.0.2.254' if self.changed_route else '192.0.2.1'
            return json.dumps({'spec':{'dst':'0.0.0.0/0','gateway':gateway,'outLinkName':'eth0','table':254}})
        if args[:2]==('get','addresses'):
            interface=self.live[ip]['machine']['network']['interfaces'][-1]
            return json.dumps({'spec':{'address':interface['addresses'][0]}})
        if args[:2]==('patch','machineconfig'):
            if '--dry-run' in args:
                return 'requires reboot' if ip==self.incompatible else 'Applied configuration without a reboot (skipped in dry-run).'
            if '--mode' not in args or args[args.index('--mode')+1]!='no-reboot':
                raise AssertionError('A live patch must explicitly forbid reboot')
            p=Path(args[args.index('--patch-file')+1]);data=yaml.safe_load(p.read_text())
            self.live[ip]['machine']['network']['interfaces']=data['machine']['network']['interfaces']
            return ''
        raise AssertionError(args)


class NetworkBootstrapTest(unittest.TestCase):
    def test_failed_command_reports_error_category_without_exposing_provider_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            commands=BOOT.Commands(Path(directory),Path('unused'),Path(directory))
            failure=subprocess.CompletedProcess(['tofu'],1,'','Error: Resource precondition failed\nsecret-sentinel')
            with patch.object(BOOT.subprocess,'run',return_value=failure):
                with self.assertRaisesRegex(RuntimeError,'resource precondition failed') as caught:
                    commands.tofu('plan')
            self.assertNotIn('secret-sentinel',str(caught.exception))
            self.assertIn('secret-sentinel',Path(directory,'1.log').read_text())

    @unittest.skipUnless(shutil.which('tofu'), 'OpenTofu is required for HCL evaluation')
    def test_capacity_gate_exempts_only_explicit_bootstrap_or_operator_override(self):
        source=ROOT.parent.joinpath('vms_pve.tf').read_text()
        expression=re.search(r'condition\s*=\s*(.*local.cp_capacity_fits)',source)[1]
        with tempfile.TemporaryDirectory() as directory:
            Path(directory,'main.tf').write_text('variable "bootstrap_secondary_network" {default=false}\n'
                'variable "allow_control_plane_overcommit" {default=false}\nlocals {cp_capacity_fits=false}\n')
            env={k:v for k,v in os.environ.items() if not k.startswith('TF_VAR_')}
            for bootstrap,override,expected in [('false','false',False),('true','false',True),('false','true',True)]:
                result=subprocess.run(['tofu','console'],cwd=directory,
                    env={**env,'TF_VAR_bootstrap_secondary_network':bootstrap,
                         'TF_VAR_allow_control_plane_overcommit':override},
                    input=expression+'\n',capture_output=True,text=True,timeout=30)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(json.loads(result.stdout),expected)

    def test_talos_empty_destination_default_route_keeps_ipv4_family(self):
        ipv4={'dst':'','family':'inet4','gateway':'192.0.2.1','outLinkName':'eth0','table':'main'}
        ipv6={'dst':'','family':'inet6','gateway':'2001:db8::1','outLinkName':'eth0','table':'main'}
        routes=BOOT.default_routes([{'spec':ipv4},{'spec':ipv6}])
        self.assertEqual(len(routes),1)
        self.assertEqual(routes[0]['gateway'],'192.0.2.1')

    def test_matching_secondary_patch_is_idempotent_but_renumbering_is_rejected(self):
        inventory=fixture();vm=inventory['workers']['worker-1']
        current={'machine':{'network':{'interfaces':[
            {'addresses':[vm['ip']+'/24'],'routes':[{'network':'0.0.0.0/0','gateway':inventory['gateway']}]},
            {'addresses':[vm['ip2']+'/24'],'deviceSelector':{'hardwareAddr':'02:00:00:00:00:02'}}]}}}
        rendered=copy.deepcopy(current)
        self.assertEqual(BOOT.network_patch(current,rendered,vm,inventory)['machine'],current['machine'])
        current['machine']['network']['interfaces'][1]['addresses']=['198.51.100.99/24']
        with self.assertRaisesRegex(ValueError,'already match'):
            BOOT.network_patch(current,rendered,vm,inventory)

    @unittest.skipUnless(shutil.which('tofu'), 'OpenTofu is required for HCL evaluation')
    def test_inventory_expression_is_evaluated_by_actual_opentofu(self):
        inventory=fixture();vms=copy.deepcopy(inventory['workers'])
        for vm in vms.values():vm['type']='worker'
        values={'vms':vms,'resources':{'worker':{'k8s_node':'worker'}},
                'constants':{'network':{'net_size':'24','gateway':inventory['gateway']},
                             'network2':inventory['secondary']}}
        with tempfile.TemporaryDirectory() as directory:
            Path(directory,'variables.tf.json').write_text(json.dumps({'variable':{
                key:{'default':value} for key,value in values.items()}}))
            env={k:v for k,v in os.environ.items() if not k.startswith('TF_VAR_')}
            r=subprocess.run(['tofu','console'],cwd=directory,env=env,
                input=' '.join(BOOT.INVENTORY.split())+'\n',capture_output=True,text=True,timeout=30)
            self.assertEqual(r.returncode,0,r.stderr)
            result=json.loads(json.loads(r.stdout));BOOT.validate_inventory(result)
            self.assertEqual(result['workers'],vms)

    def run_bootstrap(self, configure=None, order='ascending'):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory);inventory=fixture();commands=FakeCommands(path,inventory)
            if configure:configure(commands)
            BOOT.bootstrap(commands,inventory,path,path,order)
            return commands

    def test_real_orchestration_preserves_primary_config_and_only_applies_network(self):
        c=self.run_bootstrap()
        for config in c.live.values():
            self.assertEqual(config['machine']['env'],{'PRESERVE':'unchanged'})
            self.assertEqual(config['machine']['network']['interfaces'][0]['mtu'],1400)
            self.assertEqual(len(config['machine']['network']['interfaces']),2)
        apply=next(i for i,x in enumerate(c.calls) if x[:2]==('tofu','apply'))
        dry=[i for i,x in enumerate(c.calls) if '--dry-run' in x]
        live=[i for i,x in enumerate(c.calls) if 'no-reboot' in x]
        self.assertTrue(all(apply<i for i in dry))
        self.assertLess(max(dry),min(live))
        self.assertFalse(any('reboot' in x for x in c.calls))

    def test_hardware_or_primary_changes_are_rejected_before_apply(self):
        for key,value in [('cpu',{'cores':999}),('disk',[]),('started',False),('pool_id','other')]:
            with self.subTest(field=key):
                def change(c):c.plan['resource_changes'][0]['change']['after'][key]=value
                with self.assertRaisesRegex(ValueError,'hardware, disks, power'):
                    self.run_bootstrap(change)
        def primary(c):c.plan['resource_changes'][0]['change']['after']['network_device'][0]['bridge']='other'
        with self.assertRaisesRegex(ValueError,'primary NIC'):self.run_bootstrap(primary)

    def test_a_talos_apply_or_vm_replacement_cannot_enter_the_plan(self):
        def talos(c):c.plan['resource_changes'].append({'mode':'managed','type':'talos_machine_configuration_apply',
            'name':'worker','index':'worker-1','change':{'actions':['update'],'before':{},'after':{}}})
        with self.assertRaisesRegex(ValueError,'cannot apply Talos'):self.run_bootstrap(talos)
        def replacement(c):c.plan['resource_changes'][0]['change']['actions']=['delete','create']
        with self.assertRaisesRegex(ValueError,'existing VM'):self.run_bootstrap(replacement)

    def test_staged_worker_configuration_blocks_before_nic_changes(self):
        def pending(c):c.pending='192.0.2.22'
        with self.assertRaisesRegex(ValueError,'staged configuration'):self.run_bootstrap(pending)

    def test_incompatible_dry_run_does_not_apply_any_talos_patch(self):
        held=[]
        def incompatible(c):c.incompatible='192.0.2.22';held.append(c)
        with self.assertRaisesRegex(ValueError,'no-reboot'):self.run_bootstrap(incompatible)
        self.assertFalse(any('no-reboot' in x for x in held[0].calls))

    def test_unexpected_provider_reboot_stops_before_talos_patches(self):
        def reboot(c):c.reboot_on_apply=True
        with self.assertRaisesRegex(ValueError,'rebooted during NIC'):self.run_bootstrap(reboot)

    def test_current_primary_default_route_must_be_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            inventory=fixture();c=FakeCommands(Path(directory),inventory);original=c.talos
            def command(ip,*args):
                result=original(ip,*args)
                if 'no-reboot' in args:c.changed_route=True
                return result
            c.talos=command
            with self.assertRaisesRegex(ValueError,'Primary default routing changed'):
                BOOT.bootstrap(c,inventory,Path(directory),Path(directory),'ascending')

    def test_duplicate_secondary_address_is_rejected(self):
        inventory=fixture();inventory['all_ips'][-1]=inventory['all_ips'][1]
        with self.assertRaisesRegex(ValueError,'Duplicate'):BOOT.validate_inventory(inventory)

    def test_distinct_addresses_in_overlapping_subnets_are_rejected(self):
        inventory=fixture()
        inventory['workers']['worker-1']['ip2']='192.0.2.121'
        with self.assertRaisesRegex(ValueError,'must not overlap'):BOOT.validate_inventory(inventory)

    def test_cli_rejects_modes_that_can_reboot_or_expand_sections(self):
        for flag in ['--services-only','--talos-only','--destroy','--purge-external-ceph',
                     '--reboot-for-registry-auth','--development','--consolidate-development']:
            with self.subTest(flag=flag):
                r=subprocess.run(['bash',str(ROOT/'deploy.sh'),'--bootstrap-secondary-network',flag],capture_output=True,text=True)
                self.assertNotEqual(r.returncode,0);self.assertIn('cannot be combined',r.stderr)


if __name__=='__main__':unittest.main()
