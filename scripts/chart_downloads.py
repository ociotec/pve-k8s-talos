#!/usr/bin/env python3
"""Cache pinned Helm charts and retry only transient download failures."""

import argparse
import hashlib
import http.client
import json
from pathlib import Path, PurePosixPath
import re
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request


def transient(error):
    if isinstance(error, urllib.error.HTTPError):
        return error.code in {408, 429, 500, 502, 503, 504}
    if isinstance(error, urllib.error.URLError):
        return transient(error.reason)
    if isinstance(error, (TimeoutError, ConnectionError, http.client.IncompleteRead, subprocess.TimeoutExpired)):
        return True
    if isinstance(error, socket.gaierror):
        return error.errno == socket.EAI_AGAIN
    message = str(error)
    if isinstance(error, subprocess.CalledProcessError):
        message = (error.stderr or '') + '\n' + (error.stdout or '')
    if re.search(r'unauthorized|forbidden|\b(?:401|403|404)\b|x509:|certificate verify|checksum|digest mismatch', message, re.I):
        return False
    return bool(re.search(
        r'timed? out|timeout|connection (?:refused|reset|closed)|temporary failure|'
        r'temporary (?:network|name resolution)|TLS handshake timeout|unexpected EOF|'
        r'\bEOF\b|\b(?:408|429|500|502|503|504)\b|service unavailable', message, re.I))


def retry_download(action, label, *, attempts=4, sleep=time.sleep):
    for attempt in range(1, attempts + 1):
        try:
            return action()
        except Exception as error:
            if isinstance(error, urllib.error.HTTPError):
                error.close()
            detail = (error.stderr or error.stdout or str(error)).strip() if isinstance(error, subprocess.CalledProcessError) else str(error)
            print(f'Error: {label} download attempt {attempt}/{attempts} failed: {detail}', file=sys.stderr)
            if attempt == attempts or not transient(error):
                raise
            sleep(2 ** attempt)


def fetch_bytes(url):
    def fetch():
        with urllib.request.urlopen(url, timeout=60) as response:
            return response.read()
    return retry_download(fetch, 'Helm chart')


def validate_archive(path, name, version):
    with tarfile.open(path, 'r:gz') as archive:
        entries = [entry for entry in archive.getmembers()
                   if entry.isfile() and len(PurePosixPath(entry.name).parts) == 2
                   and PurePosixPath(entry.name).name == 'Chart.yaml']
        if len(entries) != 1:
            raise ValueError('Chart archive must contain one root Chart.yaml')
        text = archive.extractfile(entries[0]).read().decode()
    for field, expected in [('name', name), ('version', version)]:
        match = re.search(r'^' + field + r':\s*([^\n]+)', text, re.M)
        if not match or match[1].strip().strip('\"\'') != expected:
            raise ValueError(f'Chart archive {field} does not match the pinned source')


def prepare_chart(source, output):
    name, version, repository = (source[key] for key in ['chart', 'version', 'repository'])
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]*', name) or not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?', version):
        raise ValueError('Chart name and an exact chart version are required')
    if not repository.startswith(('https://', 'oci://')):
        raise ValueError('Chart repository must use HTTPS or OCI')
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    record = output.with_suffix('.json')
    identity = {key: source[key] for key in ['chart', 'version', 'repository']}
    try:
        previous = json.loads(record.read_text())
        if all(previous.get(key) == value for key, value in identity.items()) and previous['sha256'] == hashlib.sha256(output.read_bytes()).hexdigest():
            validate_archive(output, name, version)
            return
    except (OSError, ValueError, KeyError, tarfile.TarError):
        pass
    with tempfile.TemporaryDirectory(prefix='.chart-download-', dir=output.parent) as directory:
        command = ['helm', 'pull']
        if repository.startswith('oci://'):
            command.append(repository.rstrip('/') + '/' + name)
        else:
            command += [name, '--repo', repository]
        command += ['--version', version, '--destination', directory]
        retry_download(lambda: subprocess.run(command, capture_output=True, text=True, check=True, timeout=90), name)
        downloaded = Path(directory) / f'{name}-{version}.tgz'
        validate_archive(downloaded, name, version)
        metadata = dict(identity, sha256=hashlib.sha256(downloaded.read_bytes()).hexdigest())
        downloaded.replace(output)
        temporary = record.with_suffix('.tmp')
        temporary.write_text(json.dumps(metadata, sort_keys=True) + '\n')
        temporary.replace(record)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', required=True, type=Path)
    args = parser.parse_args()
    workspace = args.workspace.resolve()
    result = subprocess.run(['tofu', f'-chdir={workspace}', 'console', '-no-color'],
                            input='jsonencode(local.helm_chart_downloads)\n',
                            capture_output=True, text=True, timeout=60)
    if result.returncode:
        # Source diagnostics can include secrets; print only error summaries.
        summaries = [line.strip() for line in result.stderr.splitlines() if line.startswith('Error:')]
        raise ValueError('Cannot evaluate Helm chart sources: ' + '; '.join(summaries))
    charts = json.loads(json.loads(result.stdout))
    for source in charts.values():
        if source['enabled']:
            output = (workspace / source['path']).resolve()
            if not output.is_relative_to(workspace / '.charts'):
                raise ValueError('Chart cache must remain inside the generated workspace')
            prepare_chart(source, output)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(f'Error: Helm chart preparation failed ({type(error).__name__}): {error}', file=sys.stderr)
        sys.exit(1)
