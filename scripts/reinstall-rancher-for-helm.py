#!/usr/bin/env python3
"""Opt-in, local-cluster-only replacement of legacy Rancher before Helm install."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


spec = importlib.util.spec_from_file_location("prepare_rancher", Path(__file__).with_name("prepare-rancher-chart.py"))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)

# These namespaces are retained. No namespace, application PVC, or generic CAPI
# CRD is deleted. Unknown controllers/storage in these namespaces block cleanup.
NAMESPACES = {
    "cattle-system", "cattle-global-data", "cattle-impersonation-system",
    "cattle-provisioning-capi-system", "cattle-ui-plugin-system",
    "cattle-fleet-system", "cattle-fleet-local-system", "cattle-fleet-clusters-system",
    "fleet-default", "fleet-local", "local",
}
GROUPS = {
    "management.cattle.io", "catalog.cattle.io", "fleet.cattle.io",
    "auditlog.cattle.io", "ui.cattle.io", "provisioning.cattle.io",
    "rke.cattle.io", "rke-machine.cattle.io", "rke-machine-config.cattle.io",
    "telemetry.cattle.io", "upgrade.cattle.io",
}
RELEASES = {
    ("cattle-system", "rancher-webhook"), ("cattle-system", "remotedialer-proxy"),
    ("cattle-fleet-system", "fleet"), ("cattle-fleet-system", "fleet-crd"),
    ("cattle-fleet-local-system", "fleet-agent-local"),
    ("cattle-provisioning-capi-system", "rancher-provisioning-capi"),
}
CONTROLLERS = {
    ("cattle-system", "rancher"), ("cattle-system", "rancher-webhook"),
    ("cattle-system", "api-extension"), ("cattle-fleet-system", "fleet-controller"),
    ("cattle-fleet-system", "gitjob"), ("cattle-fleet-system", "helmops"),
    ("cattle-fleet-local-system", "fleet-agent"),
    ("cattle-provisioning-capi-system", "capi-controller-manager"),
}
CRONJOBS = {
    ("cattle-fleet-system", "fleet-cleanup-gitrepo-jobs"),
    ("fleet-default", "rke2-machineconfig-cleanup-cronjob"),
}
NATIVE = "deployments,statefulsets,daemonsets,cronjobs,services,persistentvolumeclaims"


def run(args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        # Do not include command input or object contents: backups contain secrets.
        raise RuntimeError(f"{args[0]} {args[1]} failed: {result.stderr.strip()}")
    return result.stdout


def get(resource, name=None, namespace=None):
    args = ["kubectl", "get", resource, "-o", "json"]
    if name:
        args += [name, "--ignore-not-found"]
    if namespace:
        args += ["-n", namespace]
    elif not name:
        args += ["-A"]
    output = run(args)
    return json.loads(output) if output.strip() else None


def identity(obj):
    metadata = obj["metadata"]
    return (obj["kind"], metadata.get("namespace", ""), metadata["name"])


def group(obj):
    return obj.get("apiVersion", "").split("/")[0]


def qualified_kind(obj):
    api = obj.get("apiVersion", "")
    return obj["kind"] + ("." + group(obj) if "/" in api else "")


def validate_inventory(objects, releases, namespaces, clusters, gitrepos, bundles, capi):
    if any(c["metadata"]["name"] != "local" for c in clusters):
        raise ValueError("Automatic replacement supports only Rancher's local cluster; downstream registrations exist")
    if gitrepos or any((b["metadata"].get("namespace"), b["metadata"]["name"]) !=
                       ("fleet-local", "fleet-agent-local") for b in bundles):
        raise ValueError("User GitOps content exists; use a separately reviewed migration")
    if capi:
        raise ValueError("CAPI provisioning resources exist; automatic Rancher replacement is unsafe")
    for release in releases:
        key = (release["namespace"], release["name"])
        if release["namespace"] in NAMESPACES and key not in RELEASES:
            raise ValueError("Unexpected Helm release in a Rancher namespace: " + "/".join(key))
    for obj in objects:
        kind, namespace, name = identity(obj)
        if namespace not in NAMESPACES:
            if any(group(owner) in GROUPS for owner in (obj["metadata"].get("ownerReferences") or [])):
                raise ValueError("Application resource is owned by Rancher: " + "/".join(identity(obj)))
            continue
        if kind == "Deployment" and (namespace, name) in CONTROLLERS:
            continue
        if kind == "CronJob" and (namespace, name) in CRONJOBS:
            continue
        if kind == "Service":
            continue
        raise ValueError("Unexpected workload/storage in a Rancher namespace: " + "/".join(identity(obj)))
    for namespace in namespaces:
        if namespace["metadata"]["name"] not in NAMESPACES and any(
            group(owner) in GROUPS for owner in (namespace["metadata"].get("ownerReferences") or [])
        ):
            raise ValueError("Application namespace is owned by Rancher; refusing cascading deletion")


def write_private(path, value):
    temporary = path.with_suffix(".tmp")
    with open(temporary, "w", opener=lambda p, flags: os.open(p, flags, 0o600)) as stream:
        json.dump(value, stream)
    temporary.replace(path)


def state_objects(state, addresses):
    result = []
    for resource in state.get("resources", []):
        for instance in resource.get("instances", []):
            address = prepare.state_address(resource, instance)
            if address not in addresses:
                continue
            attributes = instance.get("attributes", {})
            if resource["type"] == "kubernetes_deployment_v1":
                metadata = attributes["metadata"][0]
                result.append({"kind": "Deployment", "metadata": metadata})
            else:
                manifest = attributes["manifest"]
                result.append(manifest.get("value", manifest))
    return result


def snapshot(state, addresses, tls_secret):
    crds = [c for c in get("crds")["items"] if c["spec"]["group"] in GROUPS]
    definitions = {c["metadata"]["name"]: c for c in crds}
    custom = {name: get(name)["items"] for name in definitions}
    objects = get(NATIVE)["items"]
    namespaces = get("namespaces")["items"]
    releases = json.loads(run(["helm", "list", "-A", "-o", "json"]))
    capi = []
    for name in ["clusters", "machines", "machinedeployments", "machinesets"]:
        resource = name + ".cluster.x-k8s.io"
        if get("crd", resource):
            capi.extend(get(resource)["items"])
    validate_inventory(objects, releases, namespaces,
        custom.get("clusters.management.cattle.io", []),
        custom.get("gitrepos.fleet.cattle.io", []),
        custom.get("bundles.fleet.cattle.io", []), capi)
    secrets = {}
    for name in {"bootstrap-secret", "tls-ca", tls_secret}:
        secret = get("secret", name, "cattle-system")
        if secret:
            secrets[name] = secret
    if tls_secret not in secrets or "bootstrap-secret" not in secrets:
        raise ValueError("Required repository-managed TLS/bootstrap secrets are missing")
    apis = [obj for obj in get("apiservices")["items"]
            if obj["spec"].get("group") in GROUPS]
    webhooks = []
    for kind in ["validatingwebhookconfigurations", "mutatingwebhookconfigurations"]:
        for obj in get(kind)["items"]:
            if any(w.get("clientConfig", {}).get("service", {}).get("namespace") in NAMESPACES
                   for w in obj.get("webhooks", [])):
                webhooks.append(obj)
    internal_secrets = {namespace: get("secrets", namespace=namespace)["items"]
                        for namespace in ["cattle-system", "cattle-global-data", "cattle-impersonation-system"]
                        if get("namespace", namespace)}
    return {"phase": "prepared", "objects": objects, "namespaces": namespaces,
        "internal_secrets": internal_secrets,
        "secrets": secrets, "crds": crds, "custom": custom, "apis": apis,
        "webhooks": webhooks, "releases": [r for r in releases if (r["namespace"], r["name"]) in RELEASES],
        "legacy": state_objects(state, addresses),
        "cluster_uid": get("namespace", "kube-system")["metadata"]["uid"]}


def delete(obj):
    kind, namespace, name = identity(obj)
    if kind in {"Namespace", "PersistentVolumeClaim", "PersistentVolume"}:
        raise ValueError("Namespace and volume deletion is forbidden during Rancher replacement")
    args = ["kubectl", "delete", qualified_kind(obj), name, "--ignore-not-found", "--wait=false"]
    if namespace:
        args += ["-n", namespace]
    run(args)


def patch(obj, values):
    kind, namespace, name = identity(obj)
    args = ["kubectl", "patch", qualified_kind(obj), name, "--type=merge", "-p", json.dumps(values)]
    if namespace:
        args += ["-n", namespace]
    run(args)


def execute(plan, journal, workspace):
    print("Stopping legacy Rancher controllers; application workloads and namespaces are retained.", flush=True)
    for obj in plan["objects"]:
        kind, namespace, name = identity(obj)
        if namespace in NAMESPACES and kind == "Deployment" and get(kind, name, namespace):
            patch(obj, {"spec": {"replicas": 0}})
        if namespace in NAMESPACES and kind == "CronJob" and get(kind, name, namespace):
            patch(obj, {"spec": {"suspend": True}})
    deadline = time.monotonic() + 90
    while any(p["metadata"]["namespace"] in NAMESPACES and p["status"].get("phase") not in
              {"Succeeded", "Failed"} for p in get("pods")["items"]):
        if time.monotonic() > deadline:
            raise RuntimeError("Rancher controllers did not stop; no CRDs have been deleted")
        time.sleep(2)
    print("Removing only Rancher API registrations and nested releases.", flush=True)
    for obj in plan["webhooks"] + plan["apis"]:
        delete(obj)
    # Do this before uninstalling fleet-crd: deleting a Fleet CRD can also
    # trigger garbage collection of namespaces owned by its custom resources.
    for namespace in plan["namespaces"]:
        owners = namespace["metadata"].get("ownerReferences") or []
        retained = [o for o in owners if group(o) not in GROUPS]
        if retained != owners and get("namespace", namespace["metadata"]["name"]):
            patch(namespace, {"metadata": {"ownerReferences": retained}})
    for release in plan["releases"]:
        # --ignore-not-found makes interrupted retries safe in Helm 3 and 4.
        run(["helm", "uninstall", release["name"], "-n", release["namespace"],
             "--no-hooks", "--ignore-not-found", "--timeout", "60s"])
    print("Removing backed-up Rancher management data (no generic CAPI or application CRDs).", flush=True)
    for definition in plan["crds"]:
        name = definition["metadata"]["name"]
        if not get("crd", name):
            continue
        for obj in get(name)["items"]:
            if obj["metadata"].get("finalizers"):
                patch(obj, {"metadata": {"finalizers": []}})
        delete(definition)
    for obj in plan["legacy"]:
        delete(obj)
    project_ids = {p["metadata"]["name"] for p in plan["custom"].get("projects.management.cattle.io", [])}
    for namespace in plan["namespaces"]:
        metadata_patch = {}
        for field in ["labels", "annotations"]:
            value = (namespace["metadata"].get(field) or {}).get("field.cattle.io/projectId", "")
            if value.split(":")[-1] in project_ids:
                metadata_patch[field] = {"field.cattle.io/projectId": None}
        if metadata_patch:
            patch(namespace, {"metadata": metadata_patch})
    # These are Rancher credential stores, not application Secrets. Repository
    # secrets are retained byte-for-byte; all other namespaces are untouched.
    for namespace in ["cattle-system", "cattle-global-data", "cattle-impersonation-system"]:
        for secret in get("secrets", namespace=namespace)["items"]:
            if namespace == "cattle-system" and secret["metadata"]["name"] in plan["secrets"]:
                continue
            delete(secret)
    deadline = time.monotonic() + 90
    removed = {c["metadata"]["name"] for c in plan["crds"]}
    while removed & {c["metadata"]["name"] for c in get("crds")["items"]}:
        if time.monotonic() > deadline:
            raise RuntimeError("Rancher CRD cleanup is incomplete; rerun the same deployment after inspection")
        time.sleep(2)
    current = {identity(o): o["metadata"]["uid"] for o in get(NATIVE)["items"]}
    for obj in plan["objects"]:
        if obj["metadata"].get("namespace") not in NAMESPACES and current.get(identity(obj)) != obj["metadata"]["uid"]:
            raise RuntimeError("A protected application object changed during migration; stop and inspect")
    namespaces = {n["metadata"]["name"]: n["metadata"]["uid"] for n in get("namespaces")["items"]}
    if any(namespaces.get(n["metadata"]["name"]) != n["metadata"]["uid"] for n in plan["namespaces"]):
        raise RuntimeError("A namespace changed during migration; stop and inspect")
    for name, expected in plan["secrets"].items():
        actual = get("secret", name, "cattle-system")
        if not actual or actual.get("data") != expected.get("data"):
            raise RuntimeError("Protected Rancher secret changed during migration")
    # Remove only the exact legacy addresses, using OpenTofu on a private copy.
    state_file = workspace / "terraform.tfstate"
    state = json.loads(state_file.read_text())
    addresses = prepare.state_conflicts(state, "helm")
    for resource in state.get("resources", []):
        if resource["type"] in {"null_resource", "local_file", "local_sensitive_file", "kubernetes_annotations"} and resource["name"].startswith("rancher_"):
            addresses.extend(prepare.state_address(resource, instance) for instance in resource.get("instances", []))
    if addresses:
        working = journal.parent / "working.tfstate"
        shutil.copy2(state_file, working)
        run(["tofu", f"-chdir={workspace}", "state", "rm", f"-state={working}",
             f"-backup={journal.parent / 'state-rm.backup'}", *addresses])
        temporary = state_file.with_suffix(".migration.tmp")
        shutil.copy2(working, temporary)
        temporary.replace(state_file)
    plan["phase"] = "legacy-cleared"
    write_private(journal, plan)
    print("Legacy Rancher removed; application objects and protected secrets verified unchanged; all namespaces retained.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--constants", required=True)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--cluster-dir", required=True)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    try:
        source = Path(args.constants).read_text()
        enabled = bool(re.search(r'(?m)^\s*rancher_helm_reinstall_legacy\s*=\s*true\s*(?:#.*)?$', source))
        if not enabled or prepare.setting(source, "rancher_deployment_mode", "legacy") != "helm":
            return 0
        workspace = Path(args.workspace).resolve()
        state_file = workspace / "terraform.tfstate"
        state = json.loads(state_file.read_text()) if state_file.exists() else {}
        if any(r["type"] == "helm_release" and r["name"] == "rancher" for r in state.get("resources", [])):
            return 0
        addresses = prepare.state_conflicts(state, "helm")
        if not addresses:
            return 0
        git_dir = Path(run(["git", "-C", args.cluster_dir, "rev-parse", "--absolute-git-dir"]).strip())
        backup = git_dir / "rancher-helm-reinstall"
        journal = backup / "journal.json"
        if journal.exists():
            plan = json.loads(journal.read_text())
            if plan["cluster_uid"] != get("namespace", "kube-system")["metadata"]["uid"]:
                raise ValueError("Migration journal belongs to another cluster")
        else:
            plan = snapshot(state, addresses, prepare.setting(source, "rancher_tls_secret_name", "tls-rancher-ingress"))
        print(f"Rancher replacement preflight: {len(addresses)} legacy state addresses, "
              f"{len(plan['crds'])} Rancher CRDs, {len(plan['releases'])} nested releases.", flush=True)
        if not args.execute:
            print("Read-only preflight complete; no resources or state changed.")
            return 0
        if not journal.exists():
            backup.mkdir(mode=0o700, parents=True, exist_ok=True)
            shutil.copy2(state_file, backup / "original.tfstate")
            os.chmod(backup / "original.tfstate", 0o600)
            write_private(journal, plan)
        if plan["phase"] != "legacy-cleared":
            execute(plan, journal, workspace)
    except Exception as error:
        print(f"Rancher replacement failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
