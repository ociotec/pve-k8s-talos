#!/usr/bin/env python3
"""Resolve the exact configured Talos CLI without changing the global installation."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request


def client_version(executable):
    try:
        r = subprocess.run([str(executable), 'version', '--client'],
                           capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return None
    match = re.search(r'(?:\bTalos\s+|^\s*Tag:\s*)(v\d+\.\d+\.\d+(?:-[\w.-]+)?)', r.stdout, re.M)
    return match[1] if r.returncode == 0 and match else None


def fetch(url):
    return urllib.request.urlopen(url, timeout=60)


def resolve(version, cache_dir):
    if not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?', version):
        raise ValueError('Talos version must be an explicit release version, for example v1.13.0.')
    installed = shutil.which('talosctl')
    if installed and client_version(installed) == version:
        # Keep the talosctl entry point: a symlink target may have another
        # basename, while deploy.sh prepends this directory to PATH.
        return os.path.abspath(installed)
    system = platform.system().lower()
    architecture = {'x86_64': 'amd64', 'aarch64': 'arm64', 'arm64': 'arm64'}.get(platform.machine())
    if system not in ('linux', 'darwin') or architecture is None:
        raise ValueError('No supported Talos CLI release asset for this host.')
    asset = f'talosctl-{system}-{architecture}'
    directory = Path(cache_dir) / version / f'{system}-{architecture}'
    binary, checksum_file = directory / 'talosctl', directory / 'sha256'
    if binary.is_file() and checksum_file.is_file():
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        if digest == checksum_file.read_text().strip() and client_version(binary) == version:
            return str(binary.resolve())
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    base = f'https://github.com/siderolabs/talos/releases/download/{version}/'
    with fetch(base + 'sha256sum.txt') as response:
        checksums = response.read(4 * 1024 * 1024).decode()
    expected = None
    for line in checksums.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].lstrip('*') == asset and re.fullmatch('[a-fA-F0-9]{64}', parts[0]):
            expected = parts[0].lower()
    if expected is None:
        raise ValueError('Official checksum list does not contain the requested Talos CLI asset.')
    fd, temporary = tempfile.mkstemp(prefix='.download-', dir=directory)
    temporary = Path(temporary)
    try:
        digest = hashlib.sha256()
        size = 0
        with os.fdopen(fd, 'wb') as target, fetch(base + asset) as response:
            while chunk := response.read(1024 * 1024):
                size += len(chunk)
                if size > 512 * 1024 * 1024:
                    raise ValueError('Talos CLI asset exceeds the expected maximum size.')
                digest.update(chunk)
                target.write(chunk)
            target.flush()
            os.fsync(target.fileno())
        if digest.hexdigest() != expected:
            raise ValueError('Talos CLI checksum mismatch; refusing to execute it.')
        temporary.chmod(0o700)
        if client_version(temporary) != version:
            raise ValueError('Downloaded Talos CLI does not report the configured version.')
        os.replace(temporary, binary)
        checksum_file.write_text(expected + '\n')
        checksum_file.chmod(0o600)
        return str(binary.resolve())
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--cache-dir', required=True)
    args = parser.parse_args()
    try:
        print(resolve(args.version, args.cache_dir))
    except Exception as exc:
        # Network errors may contain proxy endpoints; keep the failure actionable
        # without reproducing credentials or environment values.
        detail = str(exc) if type(exc) is ValueError else 'Check release availability, proxy access, and local cache permissions.'
        print(f'Error: cannot resolve verified Talos CLI ({type(exc).__name__}). {detail}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
