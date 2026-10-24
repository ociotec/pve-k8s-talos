#!/usr/bin/env python3
"""Inventory and retire cluster-prefixed Ceph dependencies after their pools/filesystems."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


def safe_name(value):
    if not re.fullmatch(r'[A-Za-z0-9_.][A-Za-z0-9_.-]*', value) or value in ('.', '..'):
        raise ValueError('Unsafe or empty Ceph object name.')
    return value


def plan_dependencies(prefix, pools, rules, profiles, filesystems, target_pools, target_filesystems, standbys=()):
    safe_name(prefix)
    target_pools, target_filesystems = set(target_pools), set(target_filesystems)
    owned = lambda name: name.startswith(prefix + '-')
    owned_mds = lambda name: owned(name) or name in target_filesystems
    # A prefix is a cluster ownership boundary, not permission to remove resources
    # missing from the caller's explicit pool/filesystem inventory.
    unexpected = [p['pool_name'] for p in pools if owned(p['pool_name']) and p['pool_name'] not in target_pools]
    unexpected += [f['mdsmap']['fs_name'] for f in filesystems if owned(f['mdsmap']['fs_name']) and f['mdsmap']['fs_name'] not in target_filesystems]
    if unexpected:
        raise ValueError('Unconfigured cluster-prefixed pools/filesystems remain; reconcile the inventory before purging.')
    candidates = [r for r in rules if owned(r['rule_name']) or r['rule_name'] in target_pools]
    ids = {r['rule_id'] for r in candidates}
    profile_names = {p for p in profiles if owned(p) or p in {n + '-profile' for n in target_pools}}
    for pool in pools:
        if pool['pool_name'] not in target_pools:
            if pool.get('crush_rule') in ids or pool.get('erasure_code_profile') in profile_names:
                raise ValueError('A candidate CRUSH rule or EC profile is shared with a retained pool; refusing purge.')
    mds = set()
    foreign_ids = {f.get('id') for f in filesystems if f['mdsmap']['fs_name'] not in target_filesystems}
    for standby in standbys:
        if owned_mds(standby.get('name', '')) and standby.get('join_fscid', -1) in foreign_ids:
            raise ValueError('An owned standby MDS is assigned to a retained filesystem; refusing purge.')
    for fs in filesystems:
        mapping = fs['mdsmap']
        info = mapping.get('info', {})
        entries = info.values() if isinstance(info, dict) else info
        names = {x['name'] for x in entries}
        if mapping['fs_name'] in target_filesystems:
            # Ceph may assign a shared global MDS to this filesystem. Membership
            # is not ownership: preserve foreign-named daemons for other users.
            mds.update(n for n in names if owned_mds(n))
        elif any(owned_mds(n) for n in names):
            raise ValueError('A cluster-prefixed MDS serves a retained filesystem; refusing purge.')
    return {'prefix': prefix, 'pools': sorted(target_pools), 'filesystems': sorted(target_filesystems),
            'rules': sorted(r['rule_name'] for r in candidates), 'profiles': sorted(profile_names), 'mds': sorted(mds)}


class Remote:
    def __init__(self, host, user):
        self.host, self.user = host, user

    def run(self, args, host=None, structured=True):
        r = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new',
                            self.user + '@' + (host or self.host), shlex.join(args)],
                           capture_output=True, text=True, timeout=180)
        if r.returncode:
            # auth ls contains keys; never include successful payloads or a full
            # remote environment in an error message.
            raise RuntimeError('Remote Ceph operation failed: ' + ' '.join(args[:3]) + '\n' + r.stderr.strip())
        return json.loads(r.stdout) if structured else r.stdout

    def inventory(self):
        pools = self.run(['ceph', 'osd', 'pool', 'ls', 'detail', '--format', 'json'])
        for pool in pools:
            if pool.get('type') == 3 and not pool.get('erasure_code_profile'):
                pool.update(self.run(['ceph', 'osd', 'pool', 'get', pool['pool_name'], 'erasure_code_profile', '--format', 'json']))
        self.fs_dump = self.run(['ceph', 'fs', 'dump', '--format', 'json'])
        return pools, self.run(['ceph', 'osd', 'crush', 'rule', 'dump', '--format', 'json']), self.run(['ceph', 'osd', 'erasure-code-profile', 'ls', '--format', 'json']), self.fs_dump.get('filesystems', [])

    def daemon_directories(self, host):
        # Fixed script; no caller values are interpolated into shell code.
        return self.run(['sh', '-ec', 'if [ -d /var/lib/ceph/mds ]; then find /var/lib/ceph/mds -mindepth 1 -maxdepth 1 -type d -printf "%f\\n"; fi'], host=host, structured=False).splitlines()


def capture(remote, prefix, pools, filesystems, rbd_pools=()):
    inventory = remote.inventory()
    result = plan_dependencies(prefix, *inventory, pools, filesystems, standbys=remote.fs_dump.get('standbys', []))
    if not set(rbd_pools).issubset(pools):
        raise ValueError('RBD image inventory exceeds the configured pool boundary.')
    result['snapshots'], result['trash'] = [], []
    existing_pools = {p['pool_name'] for p in inventory[0]}
    for pool in rbd_pools:
        if pool not in existing_pools: continue
        for image in remote.run(['rbd', 'ls', pool, '--format', 'json']):
            for snapshot in remote.run(['rbd', 'snap', 'ls', pool + '/' + image, '--format', 'json']):
                result['snapshots'].append({'pool': pool, 'image': image, 'name': snapshot['name']})
        for item in remote.run(['rbd', 'trash', 'ls', pool, '--format', 'json']):
            result['trash'].append({'pool': pool, 'id': item['id']})
    auth = remote.run(['ceph', 'auth', 'ls', '--format', 'json'])
    result['auth'] = sorted(e['entity'] for e in auth.get('auth_dump', []) if e['entity'].startswith('mds.' + prefix + '-') or e['entity'] in {'mds.' + name for name in filesystems})
    daemons = []
    if filesystems or result['mds'] or result['auth'] or any(s.get('name', '').startswith(prefix + '-') for s in remote.fs_dump.get('standbys', [])):
        # Proxmox membership provides authoritative addresses; never infer host
        # domains or connect to hosts supplied by an arbitrary MDS name.
        members = remote.run(['pvesh', 'get', '/cluster/status', '--output-format', 'json'])
        nodes = [m for m in members if m.get('type') == 'node']
        if not nodes or any(not n.get('online') or not n.get('ip') for n in nodes):
            raise ValueError('All Proxmox members must be reachable to inventory MDS directories before purge.')
        for node in nodes:
            for directory in remote.daemon_directories(node['ip']):
                if not directory.startswith('ceph-'):
                    continue
                name = directory.removeprefix('ceph-')
                if not name.startswith(prefix + '-') and name not in filesystems:
                    continue
                safe_name(name)
                daemons.append({'host': node['ip'], 'name': name})
                result['mds'].append(name)
    result['daemons'] = daemons
    result['mds'] = sorted(set(result['mds']))
    for name in result['rules'] + result['profiles'] + result['mds'] + result['auth']:
        safe_name(name)
    return result


def cleanup(remote, plan):
    # Recheck dependencies after pool/filesystem removal, before the first
    # destructive metadata action. A concurrent user must never lose a rule.
    pools, rules, profiles, filesystems = remote.inventory()
    if any(p['pool_name'] in plan['pools'] for p in pools) or any(f['mdsmap']['fs_name'] in plan['filesystems'] for f in filesystems):
        raise ValueError('Target pools/filesystems remain; refusing dependency cleanup.')
    checked = plan_dependencies(plan['prefix'], pools, rules, profiles, filesystems, plan['pools'], plan['filesystems'], standbys=remote.fs_dump.get('standbys', []))
    if not set(plan['rules']).issubset(checked['rules']) or not set(plan['profiles']).issubset(checked['profiles']):
        # Already absent dependencies are allowed; distinguish these below.
        current_rules = {r['rule_name'] for r in rules}
        if (set(plan['rules']) & current_rules) - set(checked['rules']) or (set(plan['profiles']) & set(profiles)) - set(checked['profiles']):
            raise ValueError('Dependency ownership changed during purge.')
    owned_mds = lambda name: name.startswith(plan['prefix'] + '-') or name in plan['filesystems']
    if any(not owned_mds(d['name']) for d in plan['daemons']) or any(not e.startswith('mds.') or not owned_mds(e[4:]) for e in plan['auth']):
        raise ValueError('The cleanup plan contains MDS objects outside its ownership boundary.')
    if plan['daemons']:
        members = remote.run(['pvesh', 'get', '/cluster/status', '--output-format', 'json'])
        current_hosts = {m['ip'] for m in members if m.get('type') == 'node' and m.get('online') and m.get('ip')}
        if any(d['host'] not in current_hosts for d in plan['daemons']):
            raise ValueError('An MDS host is no longer an online member of this Proxmox cluster.')
    for daemon in plan['daemons']:
        name = safe_name(daemon['name'])
        if 'ceph-' + name in remote.daemon_directories(daemon['host']):
            remote.run(['pveceph', 'mds', 'destroy', name], host=daemon['host'], structured=False)
    current_rules = {r['rule_name'] for r in rules}
    for name in plan['rules']:
        if name in current_rules:
            remote.run(['ceph', 'osd', 'crush', 'rule', 'rm', safe_name(name)], structured=False)
    for name in plan['profiles']:
        if name in profiles:
            remote.run(['ceph', 'osd', 'erasure-code-profile', 'rm', safe_name(name)], structured=False)
    auth = remote.run(['ceph', 'auth', 'ls', '--format', 'json'])
    current_auth = {e['entity'] for e in auth.get('auth_dump', [])}
    for entity in plan['auth']:
        if entity in current_auth:
            remote.run(['ceph', 'auth', 'del', safe_name(entity)], structured=False)
    # Verify rather than reporting success merely because deletion was requested.
    after = remote.inventory()
    retained_rules = {r['rule_name'] for r in after[1]} & set(plan['rules'])
    retained_profiles = set(after[2]) & set(plan['profiles'])
    if retained_rules or retained_profiles:
        raise ValueError('Ceph metadata remained after cleanup.')
    for daemon in plan['daemons']:
        if 'ceph-' + daemon['name'] in remote.daemon_directories(daemon['host']):
            raise ValueError('An owned MDS directory remained after cleanup.')
    remaining_auth = {e['entity'] for e in remote.run(['ceph', 'auth', 'ls', '--format', 'json']).get('auth_dump', [])}
    if set(plan['auth']) & remaining_auth:
        raise ValueError('An owned MDS authentication entry remained after cleanup.')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('phase', choices=['inventory', 'cleanup'])
    p.add_argument('--ssh-host', required=True); p.add_argument('--ssh-user', default=os.environ.get('CEPH_SSH_USER', 'root'))
    p.add_argument('--prefix'); p.add_argument('--pool', action='append', default=[])
    p.add_argument('--rbd-pool', action='append', default=[])
    p.add_argument('--filesystem', action='append', default=[]); p.add_argument('--plan', required=True)
    a = p.parse_args(); remote = Remote(a.ssh_host, a.ssh_user)
    if a.phase == 'inventory':
        for name in a.pool + a.filesystem: safe_name(name)
        plan = capture(remote, safe_name(a.prefix or ''), a.pool, a.filesystem, a.rbd_pool)
        fd = os.open(a.plan, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f: json.dump(plan, f)
        print('Inventoried exclusive Ceph metadata dependencies before removing storage.')
    else:
        cleanup(remote, json.loads(Path(a.plan).read_text()))
        print('Exclusive Ceph metadata dependencies removed and verified.')


if __name__ == '__main__':
    try: main()
    except Exception as exc:
        print('Error: Ceph dependency cleanup failed: ' + str(exc), file=sys.stderr)
        sys.exit(1)
