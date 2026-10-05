#!/usr/bin/env python3
"""Remove retained Succeeded pods owned by the ingress Deployment."""

import argparse
import datetime as dt
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request


SELECTOR = (
    "app.kubernetes.io/name=ingress-nginx,"
    "app.kubernetes.io/instance=ingress-nginx,"
    "app.kubernetes.io/component=controller"
)


def controller_owner(obj, kind):
    owners = [
        ref for ref in obj.get("metadata", {}).get("ownerReferences", [])
        if ref.get("controller") is True
    ]
    if len(owners) != 1:
        return None
    owner = owners[0]
    if owner.get("kind") != kind or owner.get("apiVersion") != "apps/v1":
        return None
    return owner if owner.get("name") and owner.get("uid") else None


def completion_time(pod):
    if pod.get("status", {}).get("phase") != "Succeeded":
        return None
    if pod.get("metadata", {}).get("deletionTimestamp"):
        return None
    expected = {c["name"] for c in pod.get("spec", {}).get("containers", [])}
    statuses = pod.get("status", {}).get("containerStatuses", [])
    if not expected or {c.get("name") for c in statuses} != expected:
        return None
    times = []
    for status in statuses + pod.get("status", {}).get("initContainerStatuses", []):
        terminated = status.get("state", {}).get("terminated", {})
        if not terminated.get("finishedAt"):
            return None
        try:
            finished = dt.datetime.fromisoformat(terminated["finishedAt"].replace("Z", "+00:00"))
        except (ValueError, TypeError):
            return None
        if finished.tzinfo is None:
            return None
        times.append(finished)
    # Use the last container's actual finish time, never the pod creation time.
    return max(times)


class Kubernetes:
    def __init__(self):
        directory = "/var/run/secrets/kubernetes.io/serviceaccount"
        with open(f"{directory}/token", encoding="utf-8") as handle:
            self.token = handle.read().strip()
        self.context = ssl.create_default_context(cafile=f"{directory}/ca.crt")

    def request(self, path, method="GET", payload=None):
        request = urllib.request.Request(
            "https://kubernetes.default.svc" + path,
            data=json.dumps(payload).encode() if payload is not None else None,
            method=method,
            headers={"Authorization": "Bearer " + self.token, "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, context=self.context, timeout=10) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code in (404, 409):
                return None
            # Report status without echoing token material or API response bodies.
            raise RuntimeError(f"Kubernetes {method} failed: HTTP {error.code}") from error


def cleanup(client, namespace, deployment_name, retention_seconds, now=None, dry_run=False):
    now = now or dt.datetime.now(dt.timezone.utc)
    namespace = urllib.parse.quote(namespace, safe="")
    deployment_path = f"/apis/apps/v1/namespaces/{namespace}/deployments/{urllib.parse.quote(deployment_name, safe='')}"
    deployment = client.request(deployment_path)
    result = {"candidates": 0, "deleted": 0, "skipped": 0, "dry_run": dry_run}
    if not deployment:
        return result
    deployment_uid = deployment["metadata"]["uid"]
    cutoff = now - dt.timedelta(seconds=retention_seconds)
    replicasets = {}
    continuation = ""
    while True:
        query = urllib.parse.urlencode({
            "labelSelector": SELECTOR, "fieldSelector": "status.phase=Succeeded",
            "limit": 200, "continue": continuation,
        })
        page = client.request(f"/api/v1/namespaces/{namespace}/pods?{query}")
        if page is None:
            raise RuntimeError("Unable to list cleanup candidates")
        for pod in page.get("items", []):
            result["candidates"] += 1
            finished = completion_time(pod)
            owner = controller_owner(pod, "ReplicaSet")
            if finished is None or finished > cutoff or owner is None:
                result["skipped"] += 1
                continue
            rs_name = owner["name"]
            if rs_name not in replicasets:
                replicasets[rs_name] = client.request(
                    f"/apis/apps/v1/namespaces/{namespace}/replicasets/{urllib.parse.quote(rs_name, safe='')}"
                )
            rs = replicasets[rs_name]
            rs_owner = controller_owner(rs, "Deployment") if rs else None
            if (not rs or rs["metadata"]["uid"] != owner["uid"] or not rs_owner
                    or rs_owner["uid"] != deployment_uid or rs_owner["name"] != deployment_name):
                result["skipped"] += 1
                continue
            pod_path = f"/api/v1/namespaces/{namespace}/pods/{urllib.parse.quote(pod['metadata']['name'], safe='')}"
            current = client.request(pod_path)
            current_finished = completion_time(current) if current else None
            if (not current or current["metadata"]["uid"] != pod["metadata"]["uid"]
                    or current_finished is None or current_finished > cutoff
                    or controller_owner(current, "ReplicaSet") != owner):
                result["skipped"] += 1
                continue
            current_deployment = client.request(deployment_path)
            if not current_deployment or current_deployment["metadata"]["uid"] != deployment_uid:
                raise RuntimeError("Deployment identity changed during cleanup; stopping")
            if dry_run:
                print(json.dumps({"eligible_pod": pod["metadata"]["name"]}), flush=True)
                continue
            deleted = client.request(pod_path, "DELETE", {
                "apiVersion": "v1", "kind": "DeleteOptions",
                "preconditions": {
                    "uid": current["metadata"]["uid"],
                    "resourceVersion": current["metadata"]["resourceVersion"],
                },
            })
            if deleted is not None:
                result["deleted"] += 1
                print(json.dumps({"deleted_pod": pod["metadata"]["name"]}), flush=True)
            else:
                result["skipped"] += 1
        continuation = page.get("metadata", {}).get("continue", "")
        if not continuation:
            return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        retention = int(os.environ.get("RETENTION_SECONDS", "300"))
        if retention < 0:
            raise ValueError("RETENTION_SECONDS must be non-negative")
        result = cleanup(
            Kubernetes(), os.environ.get("NAMESPACE", "ingress-nginx"),
            "ingress-nginx-controller", retention, dry_run=args.dry_run,
        )
        print(json.dumps(result), flush=True)
        return 0
    except Exception as error:
        print(f"Ingress pod cleanup failed: {error}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
