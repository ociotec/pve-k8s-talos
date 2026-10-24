#!/usr/bin/env python3
"""Reject failed Tempo block polls even when the workload and global poll report ready."""
import argparse
from contextlib import contextmanager
import json
import re
import selectors
import subprocess
import sys
import time
import uuid
import urllib.error
import urllib.request

POLL_COMPLETE = re.compile(r'blocklist poll(?:ing)? complete', re.I)
POLL_ERROR = re.compile(r'failed reading unknown blocks|unexpected end of JSON input|failed to poll (?:or create index|tenant|block|index)', re.I)


def healthy_poll(logs):
    if POLL_ERROR.search(logs):
        raise ValueError('Tempo reports failed block/index reads. Preserve its volume and validate a snapshot/clone before any repair.')
    return bool(POLL_COMPLETE.search(logs))


def has_probe_span(value, name):
    if isinstance(value, dict):
        return value.get('name') == name or any(has_probe_span(v, name) for v in value.values())
    if isinstance(value, list): return any(has_probe_span(v, name) for v in value)
    return False


@contextmanager
def api_proxy(kube):
    # kubectl authenticates to the API; only the loopback proxy is exposed.
    # Raw kubectl POST uses a Kubernetes content type, rejected by OTLP.
    process = subprocess.Popen(kube + ['proxy', '--address=127.0.0.1', '--port=0'],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=20):
                raise RuntimeError('Timed out starting the local Kubernetes API proxy.')
            line = process.stdout.readline()
        match = re.search(r'Starting to serve on 127\.0\.0\.1:(\d+)', line)
        if not match:
            raise RuntimeError('The local Kubernetes API proxy did not report its loopback port.')
        yield 'http://127.0.0.1:' + match[1]
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait(timeout=5)
        process.stdout.close(); process.stderr.close()


def post_json(url, payload):
    request = urllib.request.Request(url, data=payload.encode(), method='POST',
                                     headers={'Content-Type': 'application/json', 'Accept': 'application/json'})
    try:
        # A loopback request must never pass through an environment HTTP proxy.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request, timeout=30) as response:
            return response.read().decode()
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f'OTLP deployment probe rejected with HTTP {exc.code}.') from exc


def verify_trace(namespace, execute, timeout=120):
    # OTLP/HTTP JSON and the trace-by-ID API are supported by Tempo 2 and 3.
    trace_id, span_id = uuid.uuid4().hex, uuid.uuid4().hex[:16]
    name, now = 'platform-deployment-probe', time.time_ns()
    payload = {'resourceSpans': [{'resource': {'attributes': [{'key': 'service.name', 'value': {'stringValue': name}}]},
        'scopeSpans': [{'scope': {'name': 'platform-deployment'}, 'spans': [{'traceId': trace_id, 'spanId': span_id,
            'name': name, 'kind': 1, 'startTimeUnixNano': str(now), 'endTimeUnixNano': str(now + 1000000)}]}]}]}
    reply = json.loads(execute(['post-json', f'/api/v1/namespaces/{namespace}/services/http:otel-collector:4318/proxy/v1/traces'], json.dumps(payload)) or '{}')
    if int(reply.get('partialSuccess', {}).get('rejectedSpans', 0)):
        raise ValueError('OpenTelemetry rejected the deployment probe span.')
    deadline = time.monotonic() + timeout
    while True:
        try:
            result = json.loads(execute(['get', '--raw', f'/api/v1/namespaces/{namespace}/services/http:tempo:3200/proxy/api/traces/{trace_id}']))
            if has_probe_span(result, name):
                print('OpenTelemetry ingestion and Tempo trace-by-ID query verified.')
                return
        except (RuntimeError, json.JSONDecodeError):
            pass  # A newly accepted span may not be queryable immediately.
        if time.monotonic() >= deadline:
            raise ValueError('The accepted deployment probe trace could not be queried from Tempo.')
        time.sleep(2)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--kubeconfig', required=True); p.add_argument('--namespace', default='monitoring')
    p.add_argument('--since-time'); p.add_argument('--timeout', type=int, default=660)
    p.add_argument('--trace-probe', action='store_true', help='Emit and query one synthetic trace through the repository collector.')
    a = p.parse_args()
    kube = ['kubectl', '--kubeconfig', a.kubeconfig, '--request-timeout=20s']
    def run(args, payload=None):
        if args[0] == "post-json":
            with api_proxy(kube) as base:
                return post_json(base + args[1], payload)
        r = subprocess.run(kube + args, input=payload, capture_output=True, text=True, timeout=40)
        if r.returncode: raise RuntimeError(f'Kubernetes {args[0]} failed while checking Tempo (exit {r.returncode}).')
        return r.stdout
    deadline = time.monotonic() + a.timeout
    while True:
        pods = json.loads(run(['get', 'pods', '-n', a.namespace, '-l', 'app=tempo', '-o', 'json']))['items']
        pods = [pod for pod in pods if not pod['metadata'].get('deletionTimestamp')]
        all_healthy = bool(pods)
        for pod in pods:
            args = ['logs', pod['metadata']['name'], '-n', a.namespace, '-c', 'tempo']
            args += ['--since-time', a.since_time] if a.since_time else ['--since=10m']
            logs = run(args)
            if not healthy_poll(logs): all_healthy = False
        if all_healthy:
            print('Tempo blocklist polling verified without block/index errors.')
            if a.trace_probe: verify_trace(a.namespace, run)
            return 0
        if time.monotonic() >= deadline:
            raise ValueError('No successful Tempo blocklist poll was observed before the health-check deadline.')
        time.sleep(5)

if __name__ == '__main__':
    try: sys.exit(main())
    except Exception as exc:
        print('Error: ' + str(exc), file=sys.stderr); sys.exit(1)
