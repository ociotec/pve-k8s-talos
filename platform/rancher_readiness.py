#!/usr/bin/env python3
"""Bounded webhook preparation and readiness gates for Rancher bootstrap."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import time
import urllib.error


def wait(check, description, timeout=1800, interval=5, stable=1):
    deadline = time.monotonic() + timeout
    pending = description
    successes = 0
    while True:
        try:
            pending = check()
        except subprocess.TimeoutExpired:
            pending = "readiness query timed out"
        successes = successes + 1 if not pending else 0
        if successes >= stable:
            return
        if time.monotonic() >= deadline:
            raise RuntimeError("Timed out waiting for " + description + ": " + (pending or "stability check"))
        time.sleep(min(interval, max(0, deadline - time.monotonic())))


def kubectl(*args):
    result = subprocess.run(["kubectl", "--request-timeout=30s", *args],
                            capture_output=True, text=True, timeout=40)
    if result.returncode:
        if any(word in result.stderr.lower() for word in ("forbidden", "unauthorized")):
            raise RuntimeError("Kubernetes denied the readiness query")
        return None
    return json.loads(result.stdout) if result.stdout.strip() else None


def auth_pending():
    config = kubectl("get", "authconfigs.management.cattle.io", "local", "-o", "json", "--ignore-not-found")
    if config and config.get("enabled") is False:
        raise RuntimeError("Rancher local authentication is explicitly disabled")
    return None if config and config.get("enabled") is True else "authconfigs/local is not initialized"


def retry_http(action, timeout=180):
    """Retry transport/startup failures, never invalid credentials or permissions."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            return action()
        except urllib.error.HTTPError as error:
            if error.code not in {404, 429, 500, 502, 503, 504}:
                raise
            error.close()
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            pass
        if time.monotonic() >= deadline:
            raise RuntimeError("Rancher authentication API did not become available")
        time.sleep(2)


def deployment_ready(obj, replicas=None):
    if not obj:
        return False
    status, spec = obj.get("status", {}), obj["spec"]
    desired = spec.get("replicas", 1)
    return (desired > 0 and desired == (desired if replicas is None else replicas)
            and status.get("observedGeneration", 0) >= obj["metadata"]["generation"]
            and status.get("updatedReplicas", 0) == desired
            and status.get("availableReplicas", 0) == desired
            and status.get("replicas", 0) == desired)


def prepare_webhook(patch, timeout=600):
    # Stabilize existing replicas before changing Helm values, not afterwards.
    objects = kubectl("get", "deployments", "-n", "cattle-system", "-o", "json")
    if objects is None:
        raise RuntimeError("Cannot inspect the existing Rancher webhook")
    if not any(o["metadata"]["name"] == "rancher-webhook" for o in objects["items"]):
        return  # A fresh webhook is created exclusively by its Helm chart.
    result = kubectl("patch", "deployment", "rancher-webhook", "-n", "cattle-system",
                     "--type=strategic", "-p", json.dumps(patch), "-o", "json")
    if result is None:
        raise RuntimeError("Failed to prepare Rancher webhook availability")
    def pending():
        obj = kubectl("get", "deployment", "rancher-webhook", "-n", "cattle-system", "-o", "json")
        if deployment_ready(obj, 2) and obj["spec"].get("minReadySeconds", 0) >= 10:
            return None
        return "two stable webhook replicas are not yet available"
    wait(pending, "webhook availability before Helm", timeout=timeout, stable=2)


def systems_pending(deployments, releases, replicas=None):
    repos = kubectl("get", "clusterrepos.catalog.cattle.io", "-o", "json")
    if repos is None:
        return "catalog API unavailable"
    downloaded = {r["metadata"]["name"] for r in repos["items"] if any(
        c.get("type") == "Downloaded" and c.get("status") == "True"
        for c in (r.get("status") or {}).get("conditions") or [])}
    missing = {"rancher-charts", "rancher-partner-charts", "rancher-rke2-charts"} - downloaded
    if missing:
        return "catalogs: " + ", ".join(sorted(missing))
    result = subprocess.run(["helm", "list", "-A", "--max", "10000", "-o", "json"],
                            capture_output=True, text=True, timeout=40)
    if result.returncode:
        return "Helm release query unavailable"
    statuses = {(r["namespace"] + "/" + r["name"]): r["status"] for r in json.loads(result.stdout)}
    pending = [name + "=" + statuses.get(name, "missing")
               for name in releases if statuses.get(name) != "deployed"]
    if pending:
        return "Helm: " + ", ".join(pending)
    objects = kubectl("get", "deployments", "-A", "-o", "json")
    if objects is None:
        return "Deployment API unavailable"
    ready = set()
    for obj in objects["items"]:
        name = obj["metadata"]["namespace"] + "/" + obj["metadata"]["name"]
        if deployment_ready(obj, (replicas or {}).get(name)):
            ready.add(name)
    missing = set(deployments) - ready
    return "Deployments: " + ", ".join(sorted(missing)) if missing else None


def openapi_pending():
    result = subprocess.run(["kubectl", "get", "--raw", "/openapi/v2?timeout=30s",
                             "--request-timeout=35s"], stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE, text=True, timeout=40)
    if any(word in result.stderr.lower() for word in ("forbidden", "unauthorized")):
        raise RuntimeError("Kubernetes denied the OpenAPI query")
    return "OpenAPI unavailable" if result.returncode else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["systems", "openapi", "prepare-webhook"])
    parser.add_argument("--checks-file", type=Path)
    parser.add_argument("--patch-file", type=Path)
    parser.add_argument("--timeout", type=int, default=1800)
    args = parser.parse_args()
    if args.phase == "systems" and not args.checks_file:
        parser.error("systems requires --checks-file")
    if args.phase == "prepare-webhook" and not args.patch_file:
        parser.error("prepare-webhook requires --patch-file")
    def check():
        try:
            return (openapi_pending() if args.phase == "openapi"
                    else systems_pending(**json.loads(args.checks_file.read_text())))
        except subprocess.TimeoutExpired:
            return "readiness query timed out"
    try:
        if args.phase == "prepare-webhook":
            prepare_webhook(json.loads(args.patch_file.read_text()), timeout=args.timeout)
            print("Rancher webhook prepared before Helm.")
            return 0
        wait(check, "Rancher " + args.phase, args.timeout, stable=2 if args.phase == "systems" else 1)
        print("Rancher " + args.phase + " readiness verified.")
        return 0
    except Exception as error:
        # Only our own diagnostics contain output; subprocess bodies may contain secrets.
        print(str(error) if isinstance(error, RuntimeError) else
              "Rancher readiness failed (" + type(error).__name__ + ")", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
