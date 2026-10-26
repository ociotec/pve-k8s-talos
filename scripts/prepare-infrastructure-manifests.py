#!/usr/bin/env python3
"""Prepare checksum-pinned releases while retaining legacy cluster manifests."""

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import urllib.request

try:
    import yaml
except ImportError:
    yaml = None  # Legacy link-only preparation retains its previous dependencies.


ROOT = Path(__file__).resolve().parents[1]
CATALOG = json.loads((ROOT / "scripts/infrastructure-manifest-releases.json").read_text())
OWNERSHIP = ("app.kubernetes.io/part-of", "app.kubernetes.io/component",
             "app.kubernetes.io/managed-by", "pve-k8s-talos/section")


def setting(source, key, default):
    match = re.search(r'^\s*' + re.escape(key) + r'\s*=\s*"([^"\n]+)"\s*(?:#.*)?$', source, re.M)
    if not match and re.search(r'^\s*' + re.escape(key) + r'\s*=', source, re.M):
        raise ValueError(f"{key} must be a literal release version.")
    return match[1] if match else default


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".manifest-")
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
        os.replace(temporary, path)  # Replace workspace symlinks, never their source.
    finally:
        Path(temporary).unlink(missing_ok=True)


def fetch(asset, cache):
    if yaml is None:
        raise ValueError("Explicit manifest release overrides require PyYAML (install python3-yaml).")
    path = cache / (asset["sha256"] + ".yaml")
    data = path.read_bytes() if path.is_file() else b""
    if hashlib.sha256(data).hexdigest() != asset["sha256"]:
        with urllib.request.urlopen(asset["url"], timeout=45) as response:
            data = response.read(16 * 1024 * 1024)
        if hashlib.sha256(data).hexdigest() != asset["sha256"]:
            raise ValueError("Official manifest checksum mismatch; refusing the release.")
        atomic_write(path, data)
    return [d for d in yaml.safe_load_all(data) if d]


def legacy_links(source, output):
    if output.is_symlink():
        if output.resolve() != source.resolve():
            raise ValueError("Unexpected workspace manifest directory symlink.")
        output.unlink()
    output.mkdir(parents=True, exist_ok=True)
    for path in source.rglob("*"):
        if not path.is_file():
            continue
        target = output / path.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() or target.is_symlink():
            target.unlink()
        target.symlink_to(path.resolve())


def resource_key(document):
    return document["kind"], document["metadata"]["name"]


def workload_policy(documents, baseline, section):
    """Retain repository sizing/probes; keep upstream images, args, RBAC and CRDs."""
    previous = {resource_key(d): d for d in baseline}
    for document in documents:
        metadata = document.setdefault("metadata", {})
        # Upstream exports sometimes include an unset, server-owned timestamp.
        # Leaving it in the manifest makes the provider plan an update forever.
        if metadata.get("creationTimestamp") is None:
            metadata.pop("creationTimestamp", None)
        old = previous.get(resource_key(document), {})
        labels = metadata.setdefault("labels", {})
        labels.update({k: v for k, v in old.get("metadata", {}).get("labels", {}).items()
                       if k in OWNERSHIP or k.startswith("pod-security.kubernetes.io/")})
        labels.update({"app.kubernetes.io/managed-by": "infrastructure", "pve-k8s-talos/section": section})
        exceptions = {k: v for k, v in old.get("metadata", {}).get("annotations", {}).items()
                      if k.startswith("policy.pve-k8s-talos.io/")}
        if exceptions:
            metadata.setdefault("annotations", {}).update(exceptions)
        if document["kind"] not in ("Deployment", "DaemonSet", "StatefulSet"):
            continue
        name = labels.setdefault("app.kubernetes.io/name", metadata["name"])
        labels.setdefault("app.kubernetes.io/instance", name)
        labels.setdefault("app.kubernetes.io/component", "controller")
        labels.setdefault("app.kubernetes.io/part-of", "rook-ceph" if section == "rook" else name)
        template = document["spec"]["template"]
        template.setdefault("metadata", {}).setdefault("labels", {}).update(
            {k: v for k, v in labels.items() if k in OWNERSHIP or k in ("app.kubernetes.io/name", "app.kubernetes.io/instance")})
        annotations = old.get("spec", {}).get("template", {}).get("metadata", {}).get("annotations", {})
        if annotations:
            template["metadata"].setdefault("annotations", {}).update(
                {k: v for k, v in annotations.items() if k.startswith("prometheus.io/")})
        spec = template["spec"]
        old_spec = old.get("spec", {}).get("template", {}).get("spec", {})
        spec["priorityClassName"] = old_spec.get("priorityClassName", "infra-high")
        if spec["priorityClassName"] in ("system-node-critical", "system-cluster-critical"):
            spec["priorityClassName"] = "infra-high"
        for key in ("tolerations", "securityContext"):
            if key in old_spec:
                spec[key] = copy.deepcopy(old_spec[key])
        old_containers = {c["name"]: c for c in old_spec.get("containers", [])}
        for container in spec.get("containers", []) + spec.get("initContainers", []):
            # Kubernetes omits empty EnvVar.value fields in its API response.
            for variable in container.get("env", []):
                if variable.get("value") == "":
                    variable.pop("value")
            previous_container = old_containers.get(container["name"], {})
            for key in ("resources", "ports", "readinessProbe", "livenessProbe", "startupProbe"):
                if key in previous_container and (key == "resources" or key not in container):
                    container[key] = copy.deepcopy(previous_container[key])
            resources = container.setdefault("resources", {})
            if not all(resources.get(side, {}).get(key) for side in ("requests", "limits") for key in ("cpu", "memory")):
                raise ValueError(f"Missing resource requirements for {container['name']}.")
            resources["requests"]["memory"] = resources["limits"]["memory"]
            for key in ("readinessProbe", "livenessProbe", "startupProbe"):
                if key in container:
                    probe = container[key]
                    probe.setdefault("timeoutSeconds", 1)
                    probe.setdefault("successThreshold", 1)
                    if "httpGet" in probe:
                        probe["httpGet"].setdefault("scheme", "HTTP")
            if container["name"] == "metrics-server":
                container.setdefault("args", []).append("--kubelet-insecure-tls")



def modern_metallb(documents, probe_image):
    """0.16 secures metrics and binds health to loopback in distroless images."""
    if not probe_image:
        raise ValueError("MetalLB 0.16 requires an explicit metallb_probe_image in cluster constants.")
    labels = {"app.kubernetes.io/name": "metallb", "app.kubernetes.io/instance": "metallb",
              "app.kubernetes.io/part-of": "metallb", "app.kubernetes.io/component": "metrics-auth",
              "app.kubernetes.io/managed-by": "infrastructure", "pve-k8s-talos/section": "k8s-net"}
    for document in documents:
        if document["kind"] not in ("Deployment", "DaemonSet"):
            continue
        template = document["spec"]["template"]
        spec = template["spec"]
        template["metadata"].setdefault("annotations", {}).update({
            "prometheus.io/scrape": "true", "prometheus.io/path": "/metrics",
            "prometheus.io/port": "9120", "prometheus.io/scheme": "https"})
        spec.setdefault("volumes", []).append({"name": "metrics-tls", "secret": {
            "secretName": "metallb-metrics-tls", "defaultMode": 288}})
        for container in spec["containers"]:
            if container["name"] not in ("controller", "speaker"):
                continue
            container.setdefault("args", []).append("--metrics-cert-dir=/etc/metallb/metrics-tls")
            container.setdefault("volumeMounts", []).append({"name": "metrics-tls",
                "mountPath": "/etc/metallb/metrics-tls", "readOnly": True})
            if container["name"] != "controller":
                continue
            # The kubelet's HTTP probe runs from the host namespace; 127.0.0.1
            # would hit the speaker instead of this non-hostNetwork controller.
            security = spec.setdefault("securityContext", {})
            uid = security.get("runAsUser", 65534)
            gid = security.get("runAsGroup", uid)
            security["fsGroup"] = gid
            security.setdefault("seccompProfile", {"type": "RuntimeDefault"})
            spec["volumes"].append({"name": "health-probe", "emptyDir": {"sizeLimit": "8Mi"}})
            spec.setdefault("initContainers", []).append({
                "name": "install-health-probe", "image": probe_image,
                "command": ["/bin/busybox", "cp", "/bin/busybox", "/probe/busybox"],
                "resources": {"requests": {"cpu": "10m", "memory": "8Mi"},
                              "limits": {"cpu": "100m", "memory": "8Mi"}},
                "securityContext": {"runAsNonRoot": True, "runAsUser": uid, "runAsGroup": gid,
                    "readOnlyRootFilesystem": True, "allowPrivilegeEscalation": False,
                    "capabilities": {"drop": ["ALL"]}},
                "volumeMounts": [{"name": "health-probe", "mountPath": "/probe"}]})
            container["volumeMounts"].append({"name": "health-probe", "mountPath": "/probe", "readOnly": True})
            for name, path in [("startupProbe", "healthz"), ("livenessProbe", "healthz"), ("readinessProbe", "readyz")]:
                container[name] = {"exec": {"command": ["/probe/busybox", "wget", "-q", "-O", "/dev/null",
                    "http://127.0.0.1:17472/" + path]}, "periodSeconds": 2 if name == "startupProbe" else 10,
                    "timeoutSeconds": 2, "successThreshold": 1, "failureThreshold": 60 if name == "startupProbe" else 3}
    documents.extend([
        {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole",
         "metadata": {"name": "metallb-metrics-auth", "labels": labels}, "rules": [
             {"apiGroups": ["authentication.k8s.io"], "resources": ["tokenreviews"], "verbs": ["create"]},
             {"apiGroups": ["authorization.k8s.io"], "resources": ["subjectaccessreviews"], "verbs": ["create"]}]},
        {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding",
         "metadata": {"name": "metallb-metrics-auth", "labels": labels},
         "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "metallb-metrics-auth"},
         "subjects": [{"kind": "ServiceAccount", "name": name, "namespace": "metallb-system"}
                      for name in ["controller", "speaker"]]}])


def dump(path, documents):
    atomic_write(path, yaml.safe_dump_all(documents, sort_keys=False).encode())


def modern_rook(documents, baseline, addons_version):
    config = next(d["data"] for d in baseline if d["kind"] == "ConfigMap")
    roles = {"driver-registrar": "registrar", "csi-provisioner": "provisioner",
             "csi-resizer": "resizer", "csi-attacher": "attacher", "csi-snapshotter": "snapshotter",
             "csi-rbdplugin": "plugin", "csi-cephfsplugin": "plugin", "csi-addons": "addons"}
    for document in documents:
        if document["kind"] == "ConfigMap":
            if document["metadata"]["name"] == "rook-ceph-operator-config":
                document["data"]["ROOK_OPERATOR_METRICS_BIND_ADDRESS"] = ":8080"
            else:
                document["data"]["addons"] = f"quay.io/csiaddons/k8s-sidecar:v{addons_version}"
        elif document["kind"] == "OperatorConfig":
            defaults = document["spec"]["driverSpecDefaults"]
            defaults["deployCsiAddons"] = "${csi_addons_enabled}"
            for plugin in ("nodePlugin", "controllerPlugin"):
                defaults[plugin]["priorityClassName"] = "infra-high"
                defaults[plugin]["labels"] = {
                    "app.kubernetes.io/part-of": "rook-ceph",
                    "app.kubernetes.io/managed-by": "infrastructure",
                    "pve-k8s-talos/section": "rook"}
        elif document["kind"] == "Driver":
            family = "RBD" if ".rbd." in document["metadata"]["name"] else "CEPHFS"
            for plugin, suffix in (("nodePlugin", "PLUGIN"), ("controllerPlugin", "PROVISIONER")):
                entries = yaml.safe_load(config[f"CSI_{family}_{suffix}_RESOURCE"])
                resources = {roles[entry["name"]]: entry["resource"] for entry in entries}
                for name in ("liveness", "logRotator", "omapGenerator", "addons"):
                    resources.setdefault(name, {"requests": {"cpu": "50m", "memory": "64Mi"},
                                                "limits": {"cpu": "200m", "memory": "64Mi"}})
                if plugin == "nodePlugin":
                    resources.pop("omapGenerator", None)
                document["spec"][plugin]["resources"] = resources


def prepare(section, constants, output, cache):
    source = constants.read_text()
    legacy = ROOT / ("k8s-net" if section == "k8s-net" else "rook/manifests")
    if output.is_symlink() and section == "rook" and output.resolve() == legacy.resolve():
        output.unlink()
    if output.resolve().is_relative_to(legacy.resolve()):
        raise ValueError("Refusing to write release assets into shared source.")
    if section == "rook":
        legacy_links(legacy, output)
    keys = ("cert_manager_version", "metrics_server_version", "metallb_version") if section == "k8s-net" else ("rook_version", "csi_addons_version")
    for key in keys:
        component = CATALOG[key]
        version = setting(source, key, component["default"])
        files = component["releases"].get(version)
        if version == component["default"]:
            if section == "k8s-net":
                filename = {"cert_manager_version": "cert-manager.yaml", "metrics_server_version": "metrics-server.yaml", "metallb_version": "metallb-native.yaml"}[key]
                target = output / filename
                if target.exists() or target.is_symlink():
                    target.unlink()
                target.symlink_to((legacy / filename).resolve())
            continue
        if files is None:
            raise ValueError(f"Unsupported pinned release for {key}: {version}.")
        releases = {name: fetch(asset, cache) for name, asset in files.items()}
        if key == "rook_version":
            csi = releases.pop("rook/csi-operator.yaml")
            releases["rook/crds.yaml"].extend(d for d in csi if d["kind"] == "CustomResourceDefinition")
            releases["rook/common.yaml"].extend(d for d in csi if d["kind"] not in ("CustomResourceDefinition", "Deployment"))
            releases["rook/operator.yaml"].extend(d for d in csi if d["kind"] == "Deployment")
            baseline = list(yaml.safe_load_all((legacy / "operator.yaml").read_text()))
            modern_rook(releases["rook/operator.yaml"], [d for d in baseline if d], setting(source, "csi_addons_version", CATALOG["csi_addons_version"]["default"]))
            atomic_write(output / "crds-nvmeof.yaml", b"# Included in the selected release CRDs when supported.\n")
        for name, documents in releases.items():
            relative = name.removeprefix("rook/")
            old = legacy / relative
            baseline = [d for d in yaml.safe_load_all(old.read_text()) if d] if old.exists() else []
            if key == "rook_version" and relative == "operator.yaml":
                # New CSI operator has no legacy counterpart; its official probes are retained.
                for d in documents:
                    if d["kind"] == "Deployment" and d["metadata"]["name"] == "ceph-csi-controller-manager":
                        d["spec"]["template"]["spec"]["containers"][0]["resources"]["requests"]["memory"] = "128Mi"
            workload_policy(documents, baseline, "k8s-net" if section == "k8s-net" else "rook")
            if key == "metallb_version":
                modern_metallb(documents, setting(source, "metallb_probe_image", ""))
            dump(output / relative, documents)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--section", choices=("k8s-net", "rook"), required=True)
    parser.add_argument("--constants", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        prepare(args.section, args.constants, args.output, args.output / ".upstream")
    except Exception as exc:
        detail = str(exc) if isinstance(exc, ValueError) else "Check upstream access and workspace permissions."
        print(f"Error: cannot prepare pinned infrastructure manifests ({type(exc).__name__}): {detail}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
