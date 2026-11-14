#!/usr/bin/env python3
"""Prepare a checksum-pinned Kyverno chart with priorities on automatic hooks."""

import argparse
import gzip
import hashlib
import io
from pathlib import Path
import re
import sys
import tarfile
import urllib.request


CHART_DIGESTS = {
    "3.7.0": "7a94960c75c8faa9a2bbf7a2c39f6deeb7ff0b8814a8c17cee9a0816f8f69874",
    "3.9.2": "f6fe7184544d5e2ee33a77808c09e67aa603ce6560cc197038fde31d727c861e",
}
HOOKS = {
    "3.7.0": {
        "post-upgrade-migrate-resources.yaml",
        "pre-delete-remove-mutatingwebhookconfiguration.yaml",
        "pre-delete-remove-validatingwebhookconfiguration.yaml",
        "pre-delete-scale-to-zero.yaml",
    },
    "3.9.2": {
        "post-upgrade-migrate-resources.yaml",
        "pre-delete-remove-webhooks.yaml",
        "pre-delete-scale-to-zero.yaml",
    },
}


def patch_members(archive, version):
    required = {"kyverno/templates/hooks/" + name for name in HOOKS[version]}
    found, patched = set(), []
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as chart:
        for member in chart.getmembers():
            if not member.isfile():
                continue
            data = chart.extractfile(member).read()
            if member.name in required:
                text = data.decode()
                anchor = "    spec:\n"
                if text.count(anchor) != 1 or "priorityClassName:" in text:
                    raise ValueError("Upstream Kyverno hook changed; review its pod template")
                text = text.replace(anchor, anchor + "      priorityClassName: infra-k8s\n")
                data = text.encode()
                found.add(member.name)
            patched.append((member.name, data))
    if found != required:
        raise ValueError("Required upstream Kyverno hooks are missing")
    return patched


def prepare_chart(version, output):
    if version not in CHART_DIGESTS:
        raise ValueError("Unsupported Kyverno chart version; review and pin its digest before use")
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    cache = output.parent / ".upstream" / f"kyverno-{version}.tgz"
    archive = cache.read_bytes() if cache.is_file() else b""
    digest = CHART_DIGESTS[version]
    if hashlib.sha256(archive).hexdigest() != digest:
        with urllib.request.urlopen(f"https://kyverno.github.io/kyverno/kyverno-{version}.tgz", timeout=60) as response:
            archive = response.read()
        if hashlib.sha256(archive).hexdigest() != digest:
            raise ValueError("Kyverno chart checksum does not match the pinned official digest")
        cache.parent.mkdir(parents=True, exist_ok=True)
        temporary = cache.with_suffix(".tmp")
        temporary.write_bytes(archive)
        temporary.replace(cache)
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as chart:
            for name, data in patch_members(archive, version):
                member = tarfile.TarInfo(name)
                member.size = len(data)
                member.mode = 0o644
                chart.addfile(member, io.BytesIO(data))
    contents = buffer.getvalue()
    if not output.exists() or output.read_bytes() != contents:
        temporary = output.with_suffix(".tmp")
        temporary.write_bytes(contents)
        temporary.replace(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--constants", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        source = args.constants.read_text()
        enabled = any(re.search(r"(?m)^\s*" + name + r"\s*=\s*true\s*$", source)
                      for name in ("enable_kyverno_audit", "enable_kyverno_enforce"))
        if not enabled:
            return 0
        version = re.search(r'^\s*kyverno_chart_version\s*=\s*"([^"\n]+)"\s*(?:#.*)?$', source, re.M)
        if not version and re.search(r"(?m)^\s*kyverno_chart_version\s*=", source):
            raise ValueError("kyverno_chart_version must be a quoted string")
        prepare_chart(version[1] if version else "3.7.0", args.output)
        return 0
    except Exception as exc:
        detail = str(exc) if isinstance(exc, ValueError) else "Check chart access and workspace permissions."
        print(f"Error: cannot prepare Kyverno chart ({type(exc).__name__}): {detail}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
