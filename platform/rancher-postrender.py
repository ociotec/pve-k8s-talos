#!/usr/bin/env python3
"""Apply repository policy to the pinned official Rancher chart."""

import sys

import yaml


LABELS = {
    "app.kubernetes.io/name": "rancher",
    "app.kubernetes.io/instance": "rancher",
    "app.kubernetes.io/part-of": "rancher",
    "app.kubernetes.io/managed-by": "Helm",
    "pve-k8s-talos/section": "platform",
}


def render(documents):
    for document in documents:
        if not document:
            continue
        kind = document.get("kind")
        metadata = document.setdefault("metadata", {})
        name = metadata.get("name")
        # Secrets stay under OpenTofu ownership, including the bootstrap hook.
        if kind == "Secret" and name == "bootstrap-secret":
            continue
        # Use the shared operational UI priority class instead.
        if kind == "PriorityClass" and name == "rancher-critical":
            continue
        metadata["labels"] = {**(metadata.get("labels") or {}), **LABELS}
        if kind in {"Deployment", "Job"}:
            template = document["spec"]["template"]
            pod_metadata = template.setdefault("metadata", {})
            labels = pod_metadata["labels"] = pod_metadata.get("labels") or {}
            labels.update(LABELS)
            labels["app.kubernetes.io/component"] = "server" if kind == "Deployment" else "upgrade"
            pod = template["spec"]
            pod["priorityClassName"] = "infra-observability"
            if kind == "Job":
                # The official pre-upgrade hook has no resource values.
                for container in pod.get("containers", []) + pod.get("initContainers", []):
                    container["resources"] = {
                        "requests": {"cpu": "100m", "memory": "128Mi"},
                        "limits": {"cpu": "500m", "memory": "128Mi"},
                    }
        yield document


def main():
    # Buffer the complete render so a failure never emits a partial manifest.
    try:
        documents = list(render(yaml.safe_load_all(sys.stdin)))
        output = yaml.safe_dump_all(documents, sort_keys=False)
    except Exception:
        print("Rancher post-render failed; check chart compatibility and Python PyYAML installation.", file=sys.stderr)
        return 1
    sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
