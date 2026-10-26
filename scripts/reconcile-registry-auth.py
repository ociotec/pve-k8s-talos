#!/usr/bin/env python3
"""Activate static CRI registry credentials and verify a kubelet pull on one node."""

import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid


FILE_ID = "cri/conf.d/01-registries.part"
MERGED_FILE_ID = "cri/conf.d/cri.toml"
ANNOTATION = "pve-k8s-talos/registry-auth-validated"
MAINTENANCE = "pve-k8s-talos/registry-auth-maintenance"
PROBE_IMAGE = "registry.k8s.io/pause:3.10"


class ReconcileError(RuntimeError):
    pass


class ResourceNotFoundError(ReconcileError):
    pass


def timestamp(value):
    if not isinstance(value, str):
        raise ReconcileError("Missing Talos resource timestamp.")
    try:
        result = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ReconcileError("Invalid Talos resource timestamp.") from exc
    if result.tzinfo is None:
        raise ReconcileError("Talos resource timestamp has no timezone.")
    return result


class Reconciler:
    def __init__(self, args):
        self.args = args
        self.talos = ["talosctl", "--talosconfig", args.talosconfig, "-n", args.node_address]
        self.kube = ["kubectl", "--kubeconfig", args.kubeconfig, "--request-timeout=20s"]

    def command(self, args, payload=None, raw=False, timeout=45):
        try:
            result = subprocess.run(
                args, input=json.dumps(payload) if payload is not None else None,
                capture_output=True, text=True, timeout=timeout,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ReconcileError(f"{args[0]} command failed ({type(exc).__name__}).") from exc
        if result.returncode:
            # Never print Talos configuration contents or registry credentials.
            code = re.search(r"\bcode\s*=\s*(\w+)", result.stderr)
            if args[0] == "talosctl" and "get" in args and code and code[1] == "NotFound":
                raise ResourceNotFoundError("Talos resource not found.")
            if "drain" in args:
                raise ReconcileError("Drain failed (eviction/PDBs remain enforced): " + result.stderr.strip())
            raise ReconcileError(f"{args[0]} command failed (exit {result.returncode}).")
        if raw:
            return result.stdout
        try:
            return json.loads(result.stdout)
        except ValueError as exc:
            raise ReconcileError(f"Invalid JSON returned by {args[0]}.") from exc

    def talos_resource(self, kind, resource_id):
        return self.command(self.talos + ["get", kind, resource_id, "-o", "json"])

    def node(self):
        return self.command(self.kube + ["get", "node", self.args.node_name, "-o", "json"])

    def pods(self):
        return self.command(self.kube + [
            "get", "pods", "-A", "--field-selector", f"spec.nodeName={self.args.node_name}",
            "-o", "json",
        ])["items"]

    def runtime(self):
        # Talos 1.14 merges registry settings in memory instead of publishing
        # the separate registry fragment. Keep the legacy check where available.
        for file_id in (FILE_ID, MERGED_FILE_ID):
            try:
                spec = self.talos_resource("etcfilespecs.files.talos.dev", file_id)
                break
            except ResourceNotFoundError:
                continue
        else:
            raise ReconcileError("No supported CRI registry configuration resource is available.")
        status = self.talos_resource("etcfilestatuses.files.talos.dev", file_id)
        process = self.talos_resource("servicepids", "cri")
        service = self.talos_resource("services", "cri")["spec"]
        if str(status["spec"].get("specVersion")) != str(spec["metadata"]["version"]):
            raise ReconcileError("The CRI registry configuration has not reached disk yet.")
        if self.command(self.talos + ["read", "/etc/" + file_id], raw=True) != spec["spec"]["contents"]:
            raise ReconcileError("The CRI registry file differs from the generated configuration.")
        if not service.get("running") or not service.get("healthy") or service.get("unknown"):
            raise ReconcileError("CRI is not running and healthy.")
        pid = process["spec"].get("pid")
        if not isinstance(pid, int) or pid <= 0:
            raise ReconcileError("Talos did not report a valid CRI process ID.")
        file_time = spec["metadata"]["updated"]
        process_time = process["metadata"]["updated"]
        pending = timestamp(file_time) > timestamp(process_time)
        signature = json.dumps({
            "configFile": file_id,
            "fileUpdated": file_time, "fileVersion": str(spec["metadata"]["version"]),
            "processUpdated": process_time, "pid": pid, "probeImage": self.args.probe_image,
        }, sort_keys=True, separators=(",", ":"))
        return {
            "file_id": file_id, "automatic_reload": file_id == MERGED_FILE_ID,
            "pending": pending, "signature": signature, "file_time": file_time,
            "process": (process_time, pid),
            "content_hash": hashlib.sha256(spec["spec"]["contents"].encode()).hexdigest(),
            "has_auth": bool(re.search(r"(?m)^\s*\[.*registry\.configs\..*\.auth\]",
                                       spec["spec"]["contents"])),
        }

    def loaded_runtime(self):
        current = self.runtime()
        deadline = time.monotonic() + self.args.timeout
        # Talos 1.14 reloads the merged configuration by restarting CRI itself.
        # Never drain or reboot a node to race that automatic reload.
        while current["automatic_reload"] and current["pending"]:
            if time.monotonic() >= deadline:
                raise ReconcileError("Timed out waiting for automatic CRI reload; no node reboot was requested.")
            time.sleep(2)
            current = self.runtime()
        return current

    def protect(self):
        node = self.node()
        owned = node["metadata"].get("annotations", {}).get(MAINTENANCE) == "true"
        if node.get("spec", {}).get("unschedulable") and not owned:
            raise ReconcileError("Node is already cordoned by another operator.")
        self.command(self.kube + ["annotate", "node", self.args.node_name,
                                  MAINTENANCE + "=true", "--overwrite"], raw=True)
        self.command(self.kube + ["taint", "node", self.args.node_name,
                                  MAINTENANCE + "=true:NoSchedule", "--overwrite"], raw=True)
        self.command(self.kube + ["cordon", self.args.node_name], raw=True)

    def release(self):
        # The taint also protects the interval in which Talos can uncordon at boot.
        self.command(self.kube + ["uncordon", self.args.node_name], raw=True)
        self.command(self.kube + ["taint", "node", self.args.node_name,
                                  MAINTENANCE + ":NoSchedule-"], raw=True)
        self.command(self.kube + ["annotate", "node", self.args.node_name,
                                  MAINTENANCE + "-"], raw=True)

    @staticmethod
    def ready(node):
        return any(c["type"] == "Ready" and c["status"] == "True"
                   for c in node["status"]["conditions"])

    def wait_reboot(self, previous, boot_id):
        deadline = time.monotonic() + self.args.timeout
        while time.monotonic() < deadline:
            try:
                node = self.node()
                if node["status"]["nodeInfo"]["bootID"] != boot_id and self.ready(node):
                    current = self.runtime()
                    if current["content_hash"] != previous["content_hash"]:
                        raise ReconcileError("Registry configuration changed during the reboot.")
                    if not current["pending"]:
                        return current
            except ReconcileError as exc:
                if "changed during" in str(exc):
                    raise
            time.sleep(5)
        raise ReconcileError("Node did not reboot Ready with the current registry authentication.")

    @staticmethod
    def infrastructure(obj):
        meta = obj["metadata"]
        namespace = meta.get("namespace", "")
        return (meta.get("labels", {}).get("app.kubernetes.io/managed-by") == "infrastructure"
                or namespace in {"kube-system", "monitoring", "cert-manager", "metallb-system",
                                 "kyverno", "ingress-nginx", "longhorn-system"}
                or namespace.startswith(("cattle-", "fleet-", "rook-")))

    @staticmethod
    def workload_health(obj):
        status = obj.get("status", {})
        desired = (status.get("desiredNumberScheduled", 0) if obj["kind"] == "DaemonSet"
                   else obj["spec"].get("replicas", 1))
        ready = status.get("numberReady", 0) if obj["kind"] == "DaemonSet" else status.get("readyReplicas", 0)
        return {"uid": obj["metadata"].get("uid"),
                "generation": obj["metadata"].get("generation", 0),
                "deficit": max(0, desired - ready),
                "unobserved": status.get("observedGeneration", 0) < obj["metadata"].get("generation", 0)}

    def capture_workload_baseline(self, report=True):
        path = getattr(self.args, "workload_baseline", None)
        if not path:
            return
        baseline = {}
        objects = self.command(self.kube + ["get", "deployments,statefulsets,daemonsets", "-A", "-o", "json"])["items"]
        for obj in objects:
            health = self.workload_health(obj)
            if not self.infrastructure(obj) and (health["deficit"] or health["unobserved"]):
                key = obj["kind"] + "/" + obj["metadata"].get("namespace", "") + "/" + obj["metadata"]["name"]
                baseline[key] = health
        Path(path).write_text(json.dumps(baseline))
        if baseline and report:
            print("Pre-existing application degradation recorded: " + ", ".join(sorted(baseline)), flush=True)

    def wait_workloads(self, wait=True):
        deadline = time.monotonic() + self.args.timeout
        while True:
            objects = self.command(self.kube + ["get", "deployments,statefulsets,daemonsets", "-A", "-o", "json"])["items"]
            path = getattr(self.args, "workload_baseline", None)
            baseline = json.loads(Path(path).read_text()) if path else {}
            unready = []
            for obj in objects:
                health = self.workload_health(obj)
                if not health["deficit"] and not health["unobserved"]:
                    continue
                name = obj["metadata"].get("namespace", "") + "/" + obj["metadata"]["name"]
                previous = baseline.get(obj["kind"] + "/" + name)
                if (not self.infrastructure(obj) and previous
                        and health["uid"] == previous["uid"]
                        and health["generation"] == previous["generation"]
                        and health["deficit"] <= previous["deficit"]
                        and health["unobserved"] <= previous["unobserved"]):
                    continue
                unready.append(name)
            if not unready:
                self.capture_workload_baseline(report=False)
                return
            if not wait:
                raise ReconcileError("Pre-existing unhealthy workloads; stopping before any drain: " + ", ".join(unready))
            pods = self.command(self.kube + ["get", "pods", "-A", "-o", "json"])["items"]
            for pod in pods:
                if (pod["metadata"].get("deletionTimestamp")
                        or pod.get("status", {}).get("phase") in {"Failed", "Succeeded"}):
                    continue
                pod_name = pod["metadata"].get("namespace", "") + "/" + pod["metadata"]["name"]
                if not any(pod_name.startswith(name + "-") for name in unready):
                    continue
                for container in pod.get("status", {}).get("containerStatuses", []):
                    if container.get("ready"):
                        continue
                    state = container.get("state", {})
                    last = container.get("lastState", {})
                    if (state.get("terminated", {}).get("reason") == "OOMKilled"
                            or (state.get("waiting") and last.get("terminated", {}).get("reason") == "OOMKilled")):
                        name = pod["metadata"].get("namespace", "") + "/" + pod["metadata"]["name"]
                        raise ReconcileError("Workload recovery failed with OOMKilled: " + name + "/" + container["name"])
            if time.monotonic() >= deadline:
                raise ReconcileError("Workloads did not recover: " + ", ".join(unready))
            time.sleep(10)

    def transient_pull_failure(self, pod):
        messages = [s.get("state", {}).get("waiting", {}).get("message", "")
                    for s in pod.get("status", {}).get("containerStatuses", [])]
        # BackOff can replace ErrImagePull before the next poll. Events retain
        # the underlying error; restrict the query to this probe's exact UID.
        uid = pod.get("metadata", {}).get("uid")
        if uid:
            events = self.command(self.kube + ["get", "events", "-n", "kube-system",
                                  "--field-selector", "involvedObject.uid=" + uid, "-o", "json"])
            messages.extend(event.get("message", "") for event in events.get("items", []))
        detail = "\n".join(messages)
        fatal = re.search(r"unauthorized|authentication required|no basic auth credentials|forbidden|x509:|manifest unknown|not found", detail, re.I)
        return not fatal and bool(re.search(r"DeadlineExceeded|timeout|timed out|context deadline exceeded", detail, re.I))

    def pull_probe(self):
        labels = {
            "app.kubernetes.io/name": "registry-auth-check",
            "app.kubernetes.io/instance": "talos-registry-auth",
            "app.kubernetes.io/component": "diagnostic",
            "app.kubernetes.io/part-of": "talos",
            "app.kubernetes.io/managed-by": "infrastructure",
        }
        account_name = pod_name = None
        cleanup_errors = []
        try:
            account_name = "registry-auth-check-" + uuid.uuid4().hex[:12]
            account = self.command(self.kube + ["create", "-f", "-", "-o", "json"], {
                "apiVersion": "v1", "kind": "ServiceAccount",
                "metadata": {"name": account_name, "namespace": "kube-system", "labels": labels},
                "automountServiceAccountToken": False,
            })
            if account["metadata"]["name"] != account_name:
                raise ReconcileError("Admission changed the diagnostic ServiceAccount name.")
            pod_name = account_name
            pod = self.command(self.kube + ["create", "-f", "-", "-o", "json"], {
                "apiVersion": "v1", "kind": "Pod",
                "metadata": {"name": account_name, "namespace": "kube-system", "labels": labels},
                "spec": {
                    "nodeName": self.args.node_name, "serviceAccountName": account_name,
                    "automountServiceAccountToken": False, "imagePullSecrets": [],
                    "restartPolicy": "Never", "terminationGracePeriodSeconds": 0,
                    "activeDeadlineSeconds": self.args.timeout + 30,
                    "priorityClassName": "infra-observability", "tolerations": [{"operator": "Exists"}],
                    "securityContext": {"runAsNonRoot": True, "runAsUser": 65534,
                                        "seccompProfile": {"type": "RuntimeDefault"}},
                    "containers": [{
                        "name": "pull", "image": self.args.probe_image, "imagePullPolicy": "Always",
                        "resources": {"requests": {"cpu": "10m", "memory": "16Mi"},
                                      "limits": {"cpu": "50m", "memory": "16Mi"}},
                        "securityContext": {"allowPrivilegeEscalation": False,
                                            "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
                    }],
                },
            })
            pod_name = pod["metadata"]["name"]
            deadline = time.monotonic() + self.args.timeout
            while True:
                spec = pod["spec"]
                container = spec["containers"][0]
                if (spec.get("imagePullSecrets") or len(spec["containers"]) != 1
                        or spec.get("nodeName") != self.args.node_name
                        or spec.get("serviceAccountName") != account_name
                        or container["image"] != self.args.probe_image or container["imagePullPolicy"] != "Always"):
                    raise ReconcileError("Admission changed the pull probe; node-only authentication cannot be verified.")
                statuses = pod.get("status", {}).get("containerStatuses", [])
                if any(s.get("ready") and "running" in s.get("state", {}) for s in statuses):
                    return
                reasons = [s.get("state", {}).get("waiting", {}).get("reason") for s in statuses]
                pull_failed = any(r in {"ImagePullBackOff", "ErrImagePull"} for r in reasons)
                if (pod.get("status", {}).get("phase") == "Failed"
                        or any(r in {"InvalidImageName", "CreateContainerConfigError"} for r in reasons)
                        or (pull_failed and not self.transient_pull_failure(pod))):
                    raise ReconcileError("Kubelet registry pull probe failed: " + ", ".join(r for r in reasons if r))
                if time.monotonic() >= deadline:
                    raise ReconcileError("Timed out waiting for the kubelet registry pull probe.")
                time.sleep(3)
                pod = self.command(self.kube + ["get", "pod", pod_name, "-n", "kube-system", "-o", "json"])
        finally:
            # Attempt both deletions even when one fails; never mark a failed cleanup as success.
            for kind, name in [("pod", pod_name), ("serviceaccount", account_name)]:
                if name:
                    try:
                        self.command(self.kube + ["delete", kind, name, "-n", "kube-system",
                                                 "--ignore-not-found", "--wait=true", "--timeout=30s"], raw=True)
                    except ReconcileError as exc:
                        cleanup_errors.append(str(exc))
            if cleanup_errors:
                primary_error = sys.exc_info()[1]
                prefix = str(primary_error) + "; " if isinstance(primary_error, ReconcileError) else ""
                raise ReconcileError(prefix + "Failed to clean up registry pull probe resources: " + "; ".join(cleanup_errors))

    def reconcile(self):
        current = self.loaded_runtime()
        node = self.node()
        annotations = node["metadata"].get("annotations", {})
        owned = annotations.get(MAINTENANCE) == "true"
        marker = annotations.get(ANNOTATION)
        if not current["pending"] and not owned and (marker == current["signature"] or (not current["has_auth"] and marker is None)):
            return
        if current["pending"]:
            if not self.args.allow_node_reboot:
                raise ReconcileError("Static registry authentication requires a node reboot; explicitly enable --reboot-for-registry-auth.")
            if not owned:
                raise ReconcileError("Node must be protected by the cluster-wide registry preflight before draining.")
            print(f"Draining and rebooting {self.args.node_name} for registry authentication...", flush=True)
            self.command(self.kube + ["drain", self.args.node_name, "--ignore-daemonsets",
                                     "--delete-emptydir-data", f"--timeout={self.args.timeout}s"],
                         raw=True, timeout=self.args.timeout + 30)
            self.command(self.talos + ["reboot", "--wait=false"], raw=True)
            current = self.wait_reboot(current, node["status"]["nodeInfo"]["bootID"])
        self.pull_probe()
        if not self.ready(self.node()) or self.runtime()["signature"] != current["signature"]:
            raise ReconcileError("CRI, node health or registry configuration changed during the pull probe.")
        if owned:
            self.release()
            self.wait_workloads()
        self.command(self.kube + ["annotate", "node", self.args.node_name,
                                  f"{ANNOTATION}={current['signature']}", "--overwrite"], raw=True)
        print(f"Kubelet registry pull verified on {self.args.node_name}.", flush=True)


def prepare_cluster(args):
    entries = []
    for target in args.prepare_node:
        name, address, role = target.split("|")
        node_args = argparse.Namespace(**vars(args))
        node_args.node_name, node_args.node_address = name, address
        reconciler = Reconciler(node_args)
        runtime, node = reconciler.loaded_runtime(), reconciler.node()
        if not reconciler.ready(node):
            raise ReconcileError("All nodes must be Ready before registry maintenance.")
        entries.append((reconciler, runtime, node, role))
    if entries:
        entries[0][0].capture_workload_baseline()
        entries[0][0].wait_workloads(wait=False)
    pending = [entry for entry in entries if entry[1]["pending"]]
    if pending and not args.allow_node_reboot:
        raise ReconcileError("Pending static registry credentials require explicit --reboot-for-registry-auth; no nodes were cordoned.")
    if pending:
        seeds = [r for r, runtime, node, role in entries
                 if role == "worker" and not runtime["pending"]
                 and not node.get("spec", {}).get("unschedulable")
                 and not any(t.get("effect") in {"NoSchedule", "NoExecute"} for t in node.get("spec", {}).get("taints", []))]
        if not seeds:
            raise ReconcileError("No Ready schedulable worker already has current registry credentials; stopping before any drain.")
        for r in seeds:
            r.pull_probe()
        # Check every target before mutating any scheduling state.
        for r, runtime, node, role in pending:
            if (node.get("spec", {}).get("unschedulable")
                    and node["metadata"].get("annotations", {}).get(MAINTENANCE) != "true"):
                raise ReconcileError("A target node is already cordoned by another operator.")
        for r, runtime, node, role in pending:
            r.protect()
        print(f"Protected {len(pending)} nodes with pending registry authentication; validated scheduling capacity remains available.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["node-name", "node-address", "talosconfig", "kubeconfig"]:
        parser.add_argument("--" + name, required=name in {"talosconfig", "kubeconfig"})
    parser.add_argument("--probe-image", default=PROBE_IMAGE)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--allow-node-reboot", action="store_true")
    parser.add_argument("--prepare-node", action="append", default=[])
    parser.add_argument("--workload-baseline", help="Application health snapshot shared by this deployment's node checks")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    try:
        if args.prepare_node:
            prepare_cluster(args)
        elif args.node_name and args.node_address:
            Reconciler(args).reconcile()
        else:
            parser.error("--node-name and --node-address are required outside preflight")
    except (ReconcileError, KeyError, IndexError, TypeError, ValueError) as exc:
        message = str(exc) if isinstance(exc, ReconcileError) else "Unexpected Talos/Kubernetes resource structure."
        target = args.node_name or "cluster preflight"
        print(f"Error: Registry authentication reconciliation failed on {target}: {message}", file=sys.stderr)
        print("Any maintenance protection already applied to unfinished nodes is retained. Resume after resolving the failure.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
