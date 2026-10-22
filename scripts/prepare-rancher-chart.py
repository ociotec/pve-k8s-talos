#!/usr/bin/env python3
"""Guard deployment-mode changes and prepare the pinned Rancher Helm chart."""

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import sys
import tarfile
import urllib.request


CHART_DIGESTS = {
    "2.15.2": "855cb9be954f65a31b9a8c77f7aebce125c2d7797425257d21d35e3380816ac8",
}


def setting(source, name, default):
    match = re.search(r'^\s*' + name + r'\s*=\s*"([^"\n]+)"\s*(?:#.*)?$', source, re.M)
    if match:
        return match[1]
    if re.search(r'^\s*' + name + r'\s*=', source, re.M):
        raise ValueError(f"{name} must be a quoted string")
    return default


def state_address(resource, instance):
    base = f"{resource['type']}.{resource['name']}"
    return base + (f"[{json.dumps(instance['index_key'])}]" if "index_key" in instance else "")


def state_conflicts(state, mode):
    conflicts = []
    for resource in state.get("resources", []):
        if resource.get("mode") != "managed":
            continue
        kind = resource["type"]
        for instance in resource.get("instances", []):
            attributes = instance.get("attributes", {})
            if kind == "helm_release":
                if mode == "legacy" and attributes.get("name") == "rancher":
                    conflicts.append(state_address(resource, instance))
                continue
            if kind not in {"kubernetes_manifest", "kubernetes_deployment_v1"}:
                continue
            manifest = attributes.get("manifest") or {}
            if "value" in manifest:
                manifest = manifest["value"]
            metadata = manifest.get("metadata", {}) if isinstance(manifest, dict) else {}
            if not metadata:
                entries = attributes.get("metadata") or []
                metadata = entries[0] if entries else {}
            name = metadata.get("name", "")
            namespace = metadata.get("namespace", "")
            legacy = (
                kind == "kubernetes_deployment_v1" and resource["name"] == "rancher"
            ) or (
                kind == "kubernetes_manifest" and (
                    (namespace == "cattle-system" and name in {"rancher", "rancher-internal", "rancher-config"})
                    or (not namespace and name in {"rancher", "rancher-critical"})
                )
            )
            if mode == "helm" and legacy:
                conflicts.append(state_address(resource, instance))
    return conflicts


def patch_members(archive):
    """Patch only templates which Helm excludes from normal post-rendering."""
    patched = []
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as chart:
        for member in chart.getmembers():
            if not member.isfile():
                continue
            data = chart.extractfile(member).read()
            if member.name == "rancher/templates/secret.yaml":
                data = b'{{/* bootstrap-secret is managed by OpenTofu, not a Helm hook. */}}\n'
            elif member.name == "rancher/templates/pre-upgrade-hook-job.yaml":
                text = data.decode()
                anchor = "          securityContext:\n"
                if text.count(anchor) != 1 or text.count("      restartPolicy: Never\n") != 1:
                    raise ValueError("Upstream hook changed; review the chart patch")
                text = text.replace(anchor, "          resources:\n"
                    "            requests: {cpu: 100m, memory: 128Mi}\n"
                    "            limits: {cpu: 500m, memory: 128Mi}\n" + anchor)
                text = text.replace("      restartPolicy: Never\n",
                    "      restartPolicy: Never\n      priorityClassName: infra-observability\n")
                data = text.encode()
            patched.append((member.name, data))
    required = {"rancher/templates/secret.yaml", "rancher/templates/pre-upgrade-hook-job.yaml"}
    if not required.issubset({name for name, _ in patched}):
        raise ValueError("Required upstream templates are missing")
    return patched


def prepare_chart(version, output):
    if version not in CHART_DIGESTS:
        raise ValueError("Unsupported Rancher chart version; review and pin its digest before use")
    url = f"https://releases.rancher.com/server-charts/stable/rancher-{version}.tgz"
    archive = urllib.request.urlopen(url, timeout=60).read()
    if hashlib.sha256(archive).hexdigest() != CHART_DIGESTS[version]:
        raise ValueError("Rancher chart checksum does not match the pinned official digest")
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as chart:
            for name, data in patch_members(archive):
                member = tarfile.TarInfo(name)
                member.size = len(data)
                member.mode = 0o644
                chart.addfile(member, io.BytesIO(data))
    contents = buffer.getvalue()
    output = Path(output)
    if not output.exists() or output.read_bytes() != contents:
        temporary = output.with_suffix(".tmp")
        temporary.write_bytes(contents)
        temporary.replace(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--constants", required=True)
    parser.add_argument("--state", help="Validate existing raw OpenTofu state before preparing")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        source = Path(args.constants).read_text()
        mode = setting(source, "rancher_deployment_mode", "legacy")
        if mode not in {"legacy", "helm"}:
            raise ValueError("rancher_deployment_mode must be legacy or helm")
        if args.state and Path(args.state).exists():
            conflicts = state_conflicts(json.loads(Path(args.state).read_text()), mode)
            if conflicts:
                raise ValueError("Rancher deployment mode conflicts with OpenTofu state: "
                    + ", ".join(conflicts)
                    + ". Complete the reviewed migration first; no state or live objects were changed.")
        if mode == "helm":
            prepare_chart(setting(source, "rancher_chart_version", "2.15.2"), args.output)
    except Exception as error:
        print(f"Rancher preparation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
