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


def admission_pending():
    config = kubectl("get", "validatingwebhookconfiguration", "rancher.cattle.io",
                     "--ignore-not-found", "-o", "json")
    if not config or not any(w.get("name") == "rancher.cattle.io.secrets"
                             for w in config.get("webhooks", [])):
        return "Rancher Secret admission is not registered"
    # Exercise API server -> Service -> webhook, not just pod health. Nothing is stored.
    probe = {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
             "metadata": {"generateName": "rancher-admission-check-", "namespace": "cattle-system"}}
    result = subprocess.run(["kubectl", "--request-timeout=30s", "create",
                             "--dry-run=server", "-f", "-", "-o", "name"],
                            input=json.dumps(probe), capture_output=True, text=True, timeout=40)
    if result.returncode and any(word in result.stderr.lower() for word in ("forbidden", "unauthorized")):
        raise RuntimeError("Kubernetes denied the admission readiness check")
    return "Rancher Secret admission unavailable" if result.returncode else None


def check_stalled_operations(pending, stalled_since):
    """Detect a terminated Helm container even if its proxy keeps the pod Running."""
    operations = kubectl("get", "operations.catalog.cattle.io", "-A", "-o", "json")
    if operations is None:
        stalled_since.clear()
        return
    latest = {}
    for operation in sorted(operations["items"], key=lambda o: o["metadata"].get("creationTimestamp", "")):
        status = operation.get("status") or {}
        release = status.get("namespace", "") + "/" + status.get("releaseName", "")
        if release in pending:
            latest[release] = operation
    observed = set()
    for release, operation in latest.items():
        status = operation.get("status") or {}
        if not status.get("podName") or not status.get("podNamespace"):
            continue
        pod = kubectl("get", "pod", status["podName"], "-n", status["podNamespace"],
                      "--ignore-not-found", "-o", "json")
        for container in ((pod or {}).get("status") or {}).get("containerStatuses") or []:
            terminated = (container.get("state") or {}).get("terminated")
            if container.get("name") != "helm" or terminated is None:
                continue
            key = (release, pending[release], operation["metadata"]["name"])
            observed.add(key)
            now = time.monotonic()
            since = stalled_since.setdefault(key, now)
            # Allow reconciliation; a new revision/operation resets this clock.
            if now - since >= 90:
                raise RuntimeError("Rancher Helm stalled: " + release + "=" + pending[release]
                                   + "; operation " + operation["metadata"]["name"]
                                   + " helm container terminated (exit " + str(terminated.get("exitCode"))
                                   + "). Inspect its helm container logs; release state was not changed.")
    for key in list(stalled_since):
        if key not in observed:
            del stalled_since[key]


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
            return admission_pending()
        return "two stable webhook replicas are not yet available"
    wait(pending, "webhook availability before Helm", timeout=timeout, stable=2)


def systems_pending(deployments, releases, replicas=None, stalled_since=None):
    repos = kubectl("get", "clusterrepos.catalog.cattle.io", "-o", "json")
    if repos is None:
        return "catalog API unavailable"
    downloaded = {r["metadata"]["name"] for r in repos["items"] if any(
        c.get("type") == "Downloaded" and c.get("status") == "True"
        for c in (r.get("status") or {}).get("conditions") or [])}
    missing = {"rancher-charts", "rancher-partner-charts", "rancher-rke2-charts"} - downloaded
    if missing:
        return "catalogs: " + ", ".join(sorted(missing))
    # Explicit filters work with Helm 3 and 4; Helm 4 removed --all.
    result = subprocess.run(["helm", "list", "-A", "--deployed", "--pending", "--failed",
                             "--uninstalling", "--uninstalled", "--superseded",
                             "--max", "10000", "-o", "json"],
                            capture_output=True, text=True, timeout=40)
    if result.returncode:
        if "unknown flag" in result.stderr.lower():
            raise RuntimeError("Installed Helm does not support the release readiness query")
        return "Helm release query unavailable"
    inventory = {r["namespace"] + "/" + r["name"]: r for r in json.loads(result.stdout)}
    statuses = {name: release["status"] for name, release in inventory.items()}
    pending = [name + "=" + statuses.get(name, "missing")
               for name in releases if statuses.get(name) != "deployed"]
    if pending:
        if stalled_since is not None:
            check_stalled_operations({name: statuses[name] + " (revision " + str(inventory[name].get("revision", "unknown")) + ")"
                                      for name in releases if name in statuses and statuses[name] != "deployed"}, stalled_since)
        return "Helm: " + ", ".join(pending)
    if stalled_since is not None:
        stalled_since.clear()
    objects = kubectl("get", "deployments", "-A", "-o", "json")
    if objects is None:
        return "Deployment API unavailable"
    ready = set()
    for obj in objects["items"]:
        name = obj["metadata"]["namespace"] + "/" + obj["metadata"]["name"]
        if deployment_ready(obj, (replicas or {}).get(name)):
            ready.add(name)
    missing = set(deployments) - ready
    return "Deployments: " + ", ".join(sorted(missing)) if missing else admission_pending()


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
    stalled_since = {}
    def check():
        try:
            return (openapi_pending() if args.phase == "openapi"
                    else systems_pending(**json.loads(args.checks_file.read_text()), stalled_since=stalled_since))
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
