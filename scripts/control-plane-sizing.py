#!/usr/bin/env python3
"""Evaluate the shared OpenTofu sizing model without providers or cluster access."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def evaluate(cluster):
    # Do not parse HCL with regexes, load live state, or expose constants (which
    # may contain credentials). Only the allowlisted sizing output is returned.
    with tempfile.TemporaryDirectory(prefix='control-plane-sizing-') as directory:
        workspace = Path(directory)
        for source in [ROOT / 'vms_variables.tf', ROOT / 'control-plane-sizing.tf']:
            (workspace / source.name).symlink_to(source)
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(('TF_VAR_', 'TF_CLI_ARGS', 'TF_LOG'))
                       and key not in ('TF_DATA_DIR', 'TF_WORKSPACE')}
        command = ['tofu', f'-chdir={workspace}', 'console', '-no-color']
        for name in ['constants', 'vms', 'resources']:
            command.append(f'-var-file={cluster / (name + ".auto.tfvars")}')
        result = subprocess.run(command, input='jsonencode(local.control_plane_sizing)\n',
                                capture_output=True, text=True, env=environment, timeout=60)
        if result.returncode:
            # HCL diagnostics may echo credential-bearing source lines. Keep
            # those private; include only summary diagnostics in console output.
            summaries = [line.strip() for line in result.stderr.splitlines() if line.startswith('Error:')]
            raise ValueError('OpenTofu could not evaluate control-plane sizing: ' + '; '.join(summaries))
        report = json.loads(json.loads(result.stdout))
    if report['invalid_resources']:
        raise ValueError('Invalid control-plane CPU/memory pairs: ' + ', '.join(report['invalid_resources'])
                         + '. Set both values or neither; use canonical cores/millicores and Mi/Gi quantities.')
    if report['invalid_settings']:
        raise ValueError('Invalid settings: ' + ', '.join(report['invalid_settings'])
                         + '. max_pods must be an integer from 1 to 65535; '
                         'control_plane_recommended_headroom_percent must be an integer from 0 to 99. '
                         'Empty values select defaults of 110 and 20 respectively.')
    if not report['nodes']:
        raise ValueError('No control-plane VMs are declared.')
    return report


def check(report, force=False):
    required = report['required']
    for name, node in report['nodes'].items():
        if not node['fits']:
            print(f'Error: control plane {name} needs {required["cpu_m"]}m CPU / '
                  f'{required["memory_mib"]}Mi RAM including service budgets, without percentage headroom; '
                  f'VM has {node["cpu_m"]}m / {node["memory_mib"]}Mi; '
                  f'deficit {node["cpu_deficit_m"]}m / {node["memory_deficit_mib"]}Mi.', file=sys.stderr)
    if not report['fits']:
        if not force:
            raise ValueError('Insufficient control-plane capacity; deployment aborted. Increase the CP VM '
                             'profile or review explicit resource settings. Use --force-control-plane-capacity '
                             'only to bypass this capacity check.')
        print('WARNING: --force-control-plane-capacity bypasses insufficient capacity; '
              'calculated component resources are unchanged.', file=sys.stderr)
    recommended = report['recommended']
    for name, node in report['nodes'].items():
        if node['oversized']:
            print(f'WARNING: possible control-plane oversizing for {name}: '
                  f'VM has {node["cpu_m"] / 1000:g} vCPU / {node["memory_mib"] / 1024:g}Gi; '
                  f'recommended upper size is {recommended["cpu_m"] // 1000} vCPU / '
                  f'{recommended["memory_mib"] // 1024}Gi including '
                  f'{report["recommended_headroom_percent"]}% free headroom. '
                  'Continuing without changing VM resources.', file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cluster-dir', type=Path, default=Path.cwd())
    parser.add_argument('--force-control-plane-capacity', action='store_true')
    parser.add_argument('--check', action='store_true', help='Fail if any declared CP VM is too small.')
    parser.add_argument('--format', choices=['summary', 'json', 'values'], default='summary')
    args = parser.parse_args()
    try:
        report = evaluate(args.cluster_dir.resolve())
        if args.check or args.format == 'summary' or args.force_control_plane_capacity:
            check(report, args.force_control_plane_capacity)
        if args.format == 'json':
            print(json.dumps(report))
        elif args.format == 'values':
            for name in ['api_server', 'controller_manager', 'scheduler']:
                print(report['components'][name]['cpu'])
                print(report['components'][name]['memory'])
        else:
            required = report['required']
            recommended = report['recommended']
            workers = report['workers']
            print(f'Control plane: {workers["count"]} workers, {workers["vcpu"]} vCPU / '
                  f'{workers["memory_gib"]:g}Gi.')
            for label, values in [('Component requests/limits (counted once)', report['totals']['components']),
                                  ('Etcd, OS and node-agent reserves', report['totals']['services'])]:
                print(f'  {label}: {values["cpu_m"]}m / {values["memory_mib"]}Mi per CP.')
            print(f'  Minimum VM: {required["cpu_m"] // 1000} vCPU / '
                  f'{required["memory_mib"] // 1024}Gi; no percentage headroom.')
            print(f'  Recommended upper VM size: {recommended["cpu_m"] // 1000} vCPU / '
                  f'{recommended["memory_mib"] // 1024}Gi including '
                  f'{report["recommended_headroom_percent"]}% free headroom; exceeding it only warns.')
        return 0
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print(f'Error: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
