#!/usr/bin/env python3
"""Verify the global diff-service setting through Talos's actual containerd imports."""
import argparse
import fnmatch
import re
import subprocess
import sys
import time

FRAGMENT = '/etc/cri/conf.d/20-customization.part'
MERGED = '/etc/cri/conf.d/cri.toml'


def imported_config(base):
    match = re.search(r'(?ms)^imports\s*=\s*\[([^\]]*)\]', base)
    imports = re.findall(r'''["']([^"']+)["']''', match[1]) if match else []
    if MERGED in imports:
        return MERGED  # Talos 1.14 merges physical and in-memory parts.
    if any(fnmatch.fnmatchcase(FRAGMENT, pattern) for pattern in imports):
        return FRAGMENT  # Older releases import the physical parts directly.
    raise ValueError('Containerd does not import the durability fragment or merged CRI config.')


def global_sync_enabled(contents):
    # Read only the known global table, never a similarly named CRI-only setting.
    active = False
    for line in contents.splitlines():
        stripped = line.strip()
        if stripped.startswith('['):
            active = bool(re.fullmatch(r'''\[plugins\.["']io\.containerd\.service\.v1\.diff-service["']\](?:\s*#.*)?''', stripped))
        elif active and re.fullmatch(r'sync_fs\s*=\s*true(?:\s*#.*)?', stripped):
            return True
    return False


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--talosconfig', required=True); p.add_argument('--node-address', required=True)
    p.add_argument('--node-name', required=True); p.add_argument('--timeout', type=int, default=120)
    a = p.parse_args(); command = ['talosctl', '--talosconfig', a.talosconfig, '-n', a.node_address]
    def read(path):
        r = subprocess.run(command + ['read', path], capture_output=True, text=True, timeout=20)
        if r.returncode:
            raise ValueError('Required containerd configuration is not readable yet.')
        return r.stdout
    deadline = time.monotonic() + a.timeout
    while True:
        try:
            effective = imported_config(read('/etc/cri/containerd.toml'))
            if not global_sync_enabled(read(effective)):
                raise ValueError('Global diff-service sync_fs is not enabled in the imported configuration.')
            print(a.node_name + ': global containerd diff-service sync_fs verified.')
            return 0
        except (ValueError, subprocess.TimeoutExpired) as exc:
            if time.monotonic() >= deadline:
                raise RuntimeError(a.node_name + ': ' + str(exc)) from exc
            time.sleep(3)


if __name__ == '__main__':
    try: sys.exit(main())
    except Exception as exc:
        print('Error: image unpack durability check failed: ' + str(exc), file=sys.stderr); sys.exit(1)
