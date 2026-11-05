#!/usr/bin/env python3
"""Bootstrap additive worker NICs/IPs without reboot or recovery-state changes."""
import argparse
import copy
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

import yaml


INVENTORY = '''jsonencode({
  workers = {for name, vm in var.vms : name => vm
    if var.resources[vm.type].k8s_node == "worker" && try(trimspace(vm.ip2) != "", false)},
  all_ips = compact(flatten([for vm in values(var.vms) : [vm.ip, try(vm.ip2, null)]])),
  prefix = var.constants["network"]["net_size"],
  gateway = var.constants["network"]["gateway"],
  secondary = var.constants["network2"]
})'''


def objects(source):
    decoder = json.JSONDecoder()
    result = []
    while source.strip():
        item, end = decoder.raw_decode(source.lstrip())
        result.append(item)
        source = source.lstrip()[end:]
    return result


def active_config(items):
    active = next(x for x in items if x['metadata']['id'] == 'v1alpha1')
    current = list(yaml.safe_load_all(active['spec']))
    persistent = next((x for x in items if x['metadata']['id'] == 'persistent'), None)
    if persistent and list(yaml.safe_load_all(persistent['spec'])) != current:
        raise ValueError('A worker already has a staged configuration; finish that rollout first.')
    return next(x for x in current if isinstance(x, dict) and 'machine' in x)


def default_routes(items):
    keys = ('dst', 'gateway', 'outLinkName', 'table', 'priority', 'metric')
    routes = [{k: x['spec'].get(k) for k in keys} for x in items
              if x.get('spec', {}).get('dst') == '0.0.0.0/0'
              or (x.get('spec', {}).get('dst') == '' and x['spec'].get('family') == 'inet4')]
    if not routes:
        raise ValueError('A worker has no primary IPv4 default route.')
    return sorted(routes, key=lambda x: json.dumps(x, sort_keys=True))


def validate_inventory(inventory):
    workers = inventory['workers']
    if not workers or not inventory['secondary'].get('bridge_device'):
        raise ValueError('Configured worker secondary NICs/IPs are required.')
    addresses = inventory['all_ips']
    normalized = [str(ipaddress.IPv4Address(x)) for x in addresses]
    if len(set(normalized)) != len(normalized):
        raise ValueError('Duplicate addresses in the cluster inventory.')
    for name, vm in workers.items():
        if not re.fullmatch(r'[a-z0-9][a-z0-9.-]*', name):
            raise ValueError('Worker names must be safe Kubernetes DNS names.')
        secondary = ipaddress.IPv4Interface(vm['ip2'] + '/' + str(inventory['secondary']['net_size']))
        for primary_vm in workers.values():
            primary = ipaddress.IPv4Interface(primary_vm['ip'] + '/' + str(inventory['prefix']))
            if secondary.network.overlaps(primary.network):
                raise ValueError('Primary and secondary networks must not overlap.')


def validate_plan(plan, inventory, workspace):
    workers = inventory['workers']
    allowed = {'network_device', 'reboot_after_update', 'ipv4_addresses',
               'ipv6_addresses', 'network_interface_names', 'mac_addresses'}
    for resource in plan.get('resource_changes', []):
        change = resource['change']
        if change['actions'] == ['no-op'] or resource.get('mode') == 'data':
            continue
        name = resource.get('index')
        if name not in workers:
            raise ValueError('Bootstrap plan changes a resource outside the selected workers.')
        before, after = change.get('before'), change.get('after')
        if resource['type'] == 'proxmox_virtual_environment_vm':
            if change['actions'] != ['update'] or not before or after.get('reboot_after_update') is not False:
                raise ValueError('Only existing VM updates with reboot disabled are allowed.')
            if resource['name'] != 'create_pve_vms' or before.get('vm_id') != workers[name]['vm_id'] or before.get('node_name') != workers[name]['node_name']:
                raise ValueError('The existing VM identity must match the worker inventory.')
            changed = {k for k in set(before) | set(after) if before.get(k) != after.get(k)}
            if changed - allowed:
                raise ValueError('Bootstrap would change hardware, disks, power or non-network VM settings.')
            old, new = before['network_device'], after['network_device']
            expected = inventory['secondary']
            if len(old) not in (1, 2) or len(new) != 2 or new[0] != old[0]:
                raise ValueError('The primary NIC must remain unchanged.')
            if new[1]['bridge'] != expected['bridge_device'] or new[1].get('vlan_id', 0) != int(expected.get('vlan_tag') or 0):
                raise ValueError('Unexpected secondary bridge or VLAN.')
            if len(old) == 2 and old[1] != new[1]:
                raise ValueError('Replacing or reconfiguring an existing secondary NIC is not additive.')
        elif resource['type'] == 'local_sensitive_file' and resource['name'] == 'secondary_network_worker_machine_config':
            filename = Path(after['filename'])
            if (workspace / filename).is_symlink():
                raise ValueError('Generated machine configuration files must not be symlinks.')
            if (workspace / filename).resolve() != (workspace / ('machineconfig-' + name + '.yaml')).resolve():
                raise ValueError('Unexpected generated machine configuration path.')
        else:
            raise ValueError('Bootstrap cannot apply Talos resources or unrelated infrastructure.')


def network_patch(current, rendered, vm, inventory):
    live = copy.deepcopy(current['machine']['network']['interfaces'])
    desired = rendered['machine']['network']['interfaces']
    if len(desired) != 2 or not 1 <= len(live) <= 2:
        raise ValueError('Bootstrap requires the generated primary-plus-secondary NIC topology.')
    primary = vm['ip'] + '/' + str(inventory['prefix'])
    secondary = vm['ip2'] + '/' + str(inventory['secondary']['net_size'])
    if primary not in live[0].get('addresses', []) or primary not in desired[0].get('addresses', []):
        raise ValueError('The live primary address differs from the source inventory.')
    if secondary in live[0].get('addresses', []):
        raise ValueError('The secondary address is already assigned to the primary NIC.')
    if not any(r.get('network') == '0.0.0.0/0' and r.get('gateway') == inventory['gateway']
               for r in live[0].get('routes', [])):
        raise ValueError('The live primary gateway differs from the source inventory.')
    extra = desired[1]
    if extra.get('addresses') != [secondary] or not extra.get('deviceSelector', {}).get('hardwareAddr'):
        raise ValueError('The generated secondary NIC must select its actual MAC and desired address.')
    if extra.get('routes') or extra.get('vip') or extra.get('dhcp'):
        raise ValueError('A secondary gateway, VIP or DHCP setting is not allowed.')
    if len(live) == 2:
        if (live[1].get('addresses') != [secondary] or live[1].get('routes') or live[1].get('dhcp')
                or live[1].get('deviceSelector', {}).get('hardwareAddr', '').lower()
                != extra['deviceSelector']['hardwareAddr'].lower()):
            raise ValueError('Existing secondary addresses must already match; use the ordered renumbering flow otherwise.')
    else:
        live.append(extra)
    return {'version': 'v1alpha1', 'machine': {'network': {'interfaces': live}}}


class Commands:
    def __init__(self, workspace, talosconfig, logs):
        self.workspace, self.talosconfig, self.logs = workspace, talosconfig, logs
        self.sequence = 0

    def run(self, args, source=None, timeout=60):
        self.sequence += 1
        env = {**os.environ, 'TF_VAR_bootstrap_secondary_network': 'true',
               'TF_VAR_defer_node_config_activation': 'true'}
        result = subprocess.run(args, cwd=self.workspace, input=source, env=env,
                                text=True, capture_output=True, timeout=timeout)
        path = self.logs / (str(self.sequence) + '.log')
        path.write_text(result.stdout + result.stderr)
        if result.returncode:
            # Print actionable error categories, never raw provider/configuration
            # diagnostics: they can contain credentials or machine configuration.
            diagnostics = [
                ('Resource precondition failed', 'resource precondition failed'),
                ('Invalid function argument', 'invalid HCL function argument'),
                ('Unsupported attribute', 'unsupported HCL attribute'),
                ('Unauthorized|authentication failed', 'authentication failed'),
                ('PermissionDenied|permission denied|Forbidden', 'access denied'),
                ('context deadline exceeded|timed out', 'request timed out'),
                ('connection refused|no route to host', 'endpoint unreachable'),
            ]
            diagnostic = next((label for pattern, label in diagnostics
                               if re.search(pattern, result.stdout + result.stderr, re.I)),
                              'command rejected; detailed output retained privately')
            raise RuntimeError(f'{args[0]} failed (exit {result.returncode}): {diagnostic}; see private log {path}.')
        return result.stdout + (result.stderr if args[0] == 'talosctl' and '--dry-run' in args else '')

    def tofu(self, *args, source=None):
        return self.run(['tofu', *args], source=source, timeout=240)

    def talos(self, node, *args):
        return self.run(['talosctl', '--talosconfig', str(self.talosconfig), '-n', node, *args])


def bootstrap(commands, inventory, workspace, logs, order):
    validate_inventory(inventory)
    names = sorted(inventory['workers'], reverse=order == 'descending')
    before = {}
    for name in names:
        vm = inventory['workers'][name]
        boot = commands.talos(vm['ip'], 'read', '/proc/sys/kernel/random/boot_id').strip()
        if not re.fullmatch(r'[0-9a-fA-F-]{36}', boot):
            raise ValueError('Cannot verify the running worker boot ID.')
        active_config(objects(commands.talos(vm['ip'], 'get', 'machineconfig', '-o', 'json')))
        before[name] = (boot, default_routes(objects(commands.talos(vm['ip'], 'get', 'routespecs', '-o', 'json'))))
    plan = logs / 'bootstrap.tfplan'
    targets = ['-target=local_sensitive_file.secondary_network_worker_machine_config[' + json.dumps(n) + ']' for n in names]
    commands.tofu('plan', '-input=false', '-no-color', '-out=' + str(plan), *targets)
    validate_plan(json.loads(commands.tofu('show', '-json', str(plan))), inventory, workspace)
    commands.tofu('apply', '-input=false', '-no-color', str(plan))
    patches = []
    # Review every network-only patch before applying any Talos configuration.
    for name in names:
        vm = inventory['workers'][name]
        if commands.talos(vm['ip'], 'read', '/proc/sys/kernel/random/boot_id').strip() != before[name][0]:
            raise ValueError('Worker rebooted during NIC creation; no Talos patch will be applied.')
        current = active_config(objects(commands.talos(vm['ip'], 'get', 'machineconfig', '-o', 'json')))
        rendered = next(d for d in yaml.safe_load_all((workspace / ('machineconfig-' + name + '.yaml')).read_text())
                        if isinstance(d, dict) and 'machine' in d)
        patch = logs / (name + '.yaml')
        patch.write_text(yaml.safe_dump(network_patch(current, rendered, vm, inventory), sort_keys=False))
        args = ('patch', 'machineconfig', '--patch-file', str(patch))
        dry = commands.talos(vm['ip'], *args, '--mode', 'auto', '--dry-run')
        if 'Applied configuration without a reboot (skipped in dry-run).' not in dry:
            raise ValueError('Talos did not confirm a no-reboot network patch; no patch will be applied.')
        patches.append((name, args))
    for name, args in patches:
        vm = inventory['workers'][name]
        commands.talos(vm['ip'], *args, '--mode', 'no-reboot')
        deadline = time.monotonic() + 60
        while True:
            boot = commands.talos(vm['ip'], 'read', '/proc/sys/kernel/random/boot_id').strip()
            if boot != before[name][0]:
                raise ValueError('Worker rebooted unexpectedly; stop and review its state.')
            routes = default_routes(objects(commands.talos(vm['ip'], 'get', 'routespecs', '-o', 'json')))
            if routes != before[name][1]:
                raise ValueError('Primary default routing changed; stop and review its state.')
            addresses = objects(commands.talos(vm['ip'], 'get', 'addresses', '-o', 'json'))
            expected = vm['ip2'] + '/' + str(inventory['secondary']['net_size'])
            if any(x.get('spec', {}).get('address') == expected for x in addresses):
                break
            if time.monotonic() >= deadline:
                raise ValueError('Secondary address did not become active without reboot.')
            time.sleep(2)
        print(name + ': secondary address active; boot ID and primary default route preserved.', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--talosconfig', type=Path, required=True)
    parser.add_argument('--state-dir', type=Path, required=True)
    parser.add_argument('--order', choices=['ascending', 'descending'], default='ascending')
    args = parser.parse_args()
    workspace = args.workspace.resolve()
    if not (workspace.parent / '.talos-bootstrap-complete').is_file() or not args.talosconfig.is_file():
        raise ValueError('Network bootstrap requires an existing cluster and Talos configuration.')
    os.umask(0o077)
    logs = Path(tempfile.mkdtemp(prefix='secondary-network-', dir=args.state_dir))
    commands = Commands(workspace, args.talosconfig.resolve(), logs)
    # Console evaluates the actual HCL inputs instead of parsing tfvars with regex.
    inventory = json.loads(json.loads(commands.tofu('console', source=' '.join(INVENTORY.split()) + '\n')))
    bootstrap(commands, inventory, workspace, logs, args.order)
    shutil.rmtree(logs)


if __name__ == '__main__':
    try:
        main()
    except yaml.YAMLError:
        print('Error: secondary network bootstrap failed: invalid private machine configuration YAML.', file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        print('Error: secondary network bootstrap failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
