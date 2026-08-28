#!/usr/bin/env python3
"""Automatically fence and recover unreachable Proxmox-backed worker nodes."""

import copy
import datetime as dt
import http.server
import json
import logging
import os
import socket
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


API = "https://kubernetes.default.svc"
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
STATE = "remediation.pve-k8s-talos/state"
STATE_SINCE = "remediation.pve-k8s-talos/state-since"
STABLE_SINCE = "remediation.pve-k8s-talos/stable-since"
COOLDOWN_UNTIL = "remediation.pve-k8s-talos/cooldown-until"
LAST_ERROR = "remediation.pve-k8s-talos/last-error"
HAD_RBD_ATTACHMENT = "remediation.pve-k8s-talos/had-rbd-attachment"
DISABLED_LABEL = "remediation.pve-k8s-talos/disabled"
OUT_OF_SERVICE = "node.kubernetes.io/out-of-service"
QUARANTINE = "remediation.pve-k8s-talos/quarantine"
TAINTS = (
    {"key": OUT_OF_SERVICE, "value": "nodeshutdown", "effect": "NoExecute"},
    {"key": OUT_OF_SERVICE, "value": "nodeshutdown", "effect": "NoSchedule"},
    {"key": QUARANTINE, "value": "storage-unfencing", "effect": "NoSchedule"},
)
PHASES = (
    "healthy",
    "suspect",
    "fencing",
    "storage-fencing",
    "recovering",
    "unfencing",
    "cooldown",
    "disabled",
)


def utcnow():
    return dt.datetime.now(dt.timezone.utc)


def timestamp(value=None):
    return (value or utcnow()).isoformat(timespec="microseconds").replace("+00:00", "Z")


def parse_time(value):
    if not value:
        return None
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


class Kubernetes:
    def __init__(self):
        with open(f"{SA_DIR}/token", encoding="utf-8") as handle:
            self.token = handle.read().strip()
        self.context = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")

    def request(self, path, method="GET", payload=None, content_type="application/json"):
        data = json.dumps(payload).encode() if payload is not None else None
        request = urllib.request.Request(
            f"{API}{path}",
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/json",
                "Content-Type": content_type,
            },
        )
        try:
            with urllib.request.urlopen(request, context=self.context, timeout=10) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            detail = error.read().decode(errors="replace")
            raise RuntimeError(f"Kubernetes {method} {path}: HTTP {error.code}: {detail}") from error

    def get_node(self, name):
        return self.request(f"/api/v1/nodes/{urllib.parse.quote(name)}")

    def get_lease(self, name):
        return self.request(f"/apis/coordination.k8s.io/v1/namespaces/kube-node-lease/leases/{urllib.parse.quote(name)}")

    def acquire_leader(self, name, holder, duration):
        now = timestamp()
        lease = self.get_lease(name)
        if lease is None:
            body = {
                "apiVersion": "coordination.k8s.io/v1",
                "kind": "Lease",
                "metadata": {"name": name, "namespace": "kube-node-lease"},
                "spec": {"holderIdentity": holder, "leaseDurationSeconds": duration, "acquireTime": now, "renewTime": now},
            }
            try:
                self.request("/apis/coordination.k8s.io/v1/namespaces/kube-node-lease/leases", "POST", body)
                return True
            except RuntimeError:
                # A competing replica may have created the Lease after our GET.
                # Surface every other error so readiness and logs expose it.
                if self.get_lease(name) is None:
                    raise
                return False

        spec = lease.get("spec", {})
        renew = parse_time(spec.get("renewTime"))
        expired = renew is None or (utcnow() - renew).total_seconds() > spec.get("leaseDurationSeconds", duration)
        if spec.get("holderIdentity") != holder and not expired:
            return False
        spec.update({"holderIdentity": holder, "leaseDurationSeconds": duration, "renewTime": now})
        if expired:
            spec["acquireTime"] = now
            spec["leaseTransitions"] = spec.get("leaseTransitions", 0) + 1
        self.request(
            f"/apis/coordination.k8s.io/v1/namespaces/kube-node-lease/leases/{urllib.parse.quote(name)}",
            "PUT",
            lease,
        )
        return True

    def patch_node(self, node, annotations=None, add_taints=False, remove_taints=False, remove_quarantine=False):
        metadata = node.setdefault("metadata", {})
        current_annotations = dict(metadata.get("annotations") or {})
        for key, value in (annotations or {}).items():
            if value is None:
                current_annotations.pop(key, None)
            else:
                current_annotations[key] = str(value)
        taints = list(node.get("spec", {}).get("taints") or [])
        if remove_taints:
            taints = [taint for taint in taints if taint.get("key") != OUT_OF_SERVICE]
        if remove_quarantine:
            taints = [taint for taint in taints if taint.get("key") != QUARANTINE]
        if add_taints:
            existing = {(taint.get("key"), taint.get("effect")) for taint in taints}
            taints.extend(taint for taint in TAINTS if (taint["key"], taint["effect"]) not in existing)
        payload = {"metadata": {"annotations": current_annotations}, "spec": {"taints": taints}}
        return self.request(
            f"/api/v1/nodes/{urllib.parse.quote(metadata['name'])}",
            "PATCH",
            payload,
            "application/merge-patch+json",
        )

    def rbd_volume_attachments(self, node_name):
        response = self.request("/apis/storage.k8s.io/v1/volumeattachments") or {}
        return [
            item
            for item in response.get("items", [])
            if item.get("spec", {}).get("nodeName") == node_name
            and ".rbd.csi.ceph.com" in item.get("spec", {}).get("attacher", "")
        ]

    def network_fence_succeeded(self, node_name):
        response = self.request("/apis/csiaddons.openshift.io/v1alpha1/networkfences") or {}
        for item in response.get("items", []):
            metadata = item.get("metadata", {})
            spec = item.get("spec", {})
            status = item.get("status", {})
            if metadata.get("name") == node_name and spec.get("fenceState", "Fenced") == "Fenced":
                return status.get("result") == "Succeeded"
        return False

    def network_fence_released(self, node_name):
        response = self.request("/apis/csiaddons.openshift.io/v1alpha1/networkfences") or {}
        matching = [item for item in response.get("items", []) if item.get("metadata", {}).get("name") == node_name]
        if not matching:
            return True
        return all(
            item.get("spec", {}).get("fenceState") == "Unfenced"
            and item.get("status", {}).get("result") == "Succeeded"
            for item in matching
        )


class Proxmox:
    def __init__(self):
        endpoint = os.environ["PROXMOX_ENDPOINT"].rstrip("/")
        self.base = endpoint if endpoint.endswith("/api2/json") else f"{endpoint}/api2/json"
        self.token = os.environ["PROXMOX_API_TOKEN"]
        self.context = ssl.create_default_context()
        if os.getenv("PROXMOX_INSECURE", "false").lower() == "true":
            self.context = ssl._create_unverified_context()  # noqa: SLF001 - explicit operator setting

    def request(self, path, method="GET", form=None):
        data = urllib.parse.urlencode(form or {}).encode() if form is not None else None
        request = urllib.request.Request(
            f"{self.base}{path}",
            data=data,
            method=method,
            headers={"Authorization": f"PVEAPIToken={self.token}"},
        )
        try:
            with urllib.request.urlopen(request, context=self.context, timeout=10) as response:
                return json.load(response).get("data")
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            raise RuntimeError(f"PVE {method} {path}: HTTP {error.code}: {detail}") from error

    def status(self, host, vmid):
        return self.request(f"/nodes/{urllib.parse.quote(host)}/qemu/{vmid}/status/current").get("status")

    def power(self, host, vmid, action):
        return self.request(f"/nodes/{urllib.parse.quote(host)}/qemu/{vmid}/status/{action}", "POST", {})


class HealthHandler(http.server.BaseHTTPRequestHandler):
    ready = False
    leader = False
    identity = "unknown"
    node_metrics = {}
    metrics_lock = threading.Lock()

    @classmethod
    def publish_controller(cls, identity, leader):
        with cls.metrics_lock:
            cls.identity = identity
            cls.leader = leader
            if not leader:
                cls.node_metrics = {}

    @classmethod
    def publish_node(cls, node_name, phase, phase_started, lease_age, error):
        with cls.metrics_lock:
            cls.node_metrics[node_name] = {
                "phase": phase,
                "phase_started": phase_started,
                "lease_age": lease_age,
                "error": error,
            }

    @classmethod
    def publish_phase(cls, node_name, phase, error=False):
        with cls.metrics_lock:
            if node_name in cls.node_metrics:
                cls.node_metrics[node_name].update(
                    {"phase": phase, "phase_started": utcnow().timestamp(), "error": error}
                )

    @classmethod
    def render_metrics(cls):
        with cls.metrics_lock:
            identity = cls.identity.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
            leader = cls.leader
            nodes = copy.deepcopy(cls.node_metrics)
        lines = [
            "# HELP node_remediation_controller_leader Whether this controller replica currently holds the leader Lease.",
            "# TYPE node_remediation_controller_leader gauge",
            f'node_remediation_controller_leader{{identity="{identity}"}} {1 if leader else 0}',
            "# HELP node_remediation_node_phase Current remediation phase as a one-hot gauge.",
            "# TYPE node_remediation_node_phase gauge",
        ]
        now = utcnow().timestamp()
        for node_name, values in sorted(nodes.items()):
            escaped_worker = node_name.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
            for phase in PHASES:
                lines.append(
                    f'node_remediation_node_phase{{worker="{escaped_worker}",phase="{phase}"}} '
                    f'{1 if values["phase"] == phase else 0}'
                )
        lines.extend(
            [
                "# HELP node_remediation_node_phase_age_seconds Seconds spent in the current remediation phase.",
                "# TYPE node_remediation_node_phase_age_seconds gauge",
            ]
        )
        for node_name, values in sorted(nodes.items()):
            phase_started = values["phase_started"]
            age = max(0.0, now - phase_started) if phase_started else 0.0
            lines.append(f'node_remediation_node_phase_age_seconds{{worker="{node_name}"}} {age:.3f}')
        lines.extend(
            [
                "# HELP node_remediation_node_lease_age_seconds Seconds since the Kubernetes node Lease was renewed.",
                "# TYPE node_remediation_node_lease_age_seconds gauge",
            ]
        )
        for node_name, values in sorted(nodes.items()):
            lease_age = values["lease_age"]
            rendered_age = "+Inf" if lease_age == float("inf") else f"{max(0.0, lease_age):.3f}"
            lines.append(f'node_remediation_node_lease_age_seconds{{worker="{node_name}"}} {rendered_age}')
        lines.extend(
            [
                "# HELP node_remediation_node_error Whether the current remediation phase has a recorded error.",
                "# TYPE node_remediation_node_error gauge",
            ]
        )
        for node_name, values in sorted(nodes.items()):
            lines.append(f'node_remediation_node_error{{worker="{node_name}"}} {1 if values["error"] else 0}')
        return "\n".join(lines) + "\n"

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path == "/metrics":
            payload = self.render_metrics().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        status = 200 if self.path == "/healthz" or (self.path == "/readyz" and self.ready) else 503
        self.send_response(status)
        self.end_headers()
        self.wfile.write(b"ok\n" if status == 200 else b"not ready\n")

    def log_message(self, _format, *_args):
        return


class Controller:
    def __init__(self):
        self.config = json.loads(os.environ["REMEDIATION_CONFIG"])
        self.kube = Kubernetes()
        self.pve = Proxmox()
        self.identity = os.getenv("POD_NAME", socket.gethostname())

    def set_state(self, node, state, extra=None):
        annotations = {STATE: state, STATE_SINCE: timestamp(), LAST_ERROR: None}
        annotations.update(extra or {})
        patched = self.kube.patch_node(node, annotations=annotations)
        HealthHandler.publish_phase(node["metadata"]["name"], state)
        return patched

    def publish_node_metrics(self, node_name, node, lease_age, now):
        metadata = node.get("metadata", {})
        annotations = metadata.get("annotations") or {}
        labels = metadata.get("labels") or {}
        phase = annotations.get(STATE, "")
        phase_started = parse_time(annotations.get(STATE_SINCE))
        cooldown = parse_time(annotations.get(COOLDOWN_UNTIL))
        if not phase:
            if labels.get(DISABLED_LABEL, "false").lower() == "true":
                phase = "disabled"
            elif cooldown and cooldown > now:
                phase = "cooldown"
                phase_started = cooldown - dt.timedelta(seconds=self.config["node_cooldown_seconds"])
            else:
                phase = "healthy"
        HealthHandler.publish_node(
            node_name,
            phase,
            phase_started.timestamp() if phase_started else 0.0,
            lease_age,
            bool(annotations.get(LAST_ERROR)),
        )

    def complete_recovery(self, node, node_name):
        cooldown = utcnow() + dt.timedelta(seconds=self.config["node_cooldown_seconds"])
        logging.warning("node %s completed recovery; removing its quarantine", node_name)
        self.kube.patch_node(
            node,
            annotations={
                STATE: None,
                STATE_SINCE: None,
                STABLE_SINCE: None,
                HAD_RBD_ATTACHMENT: None,
                LAST_ERROR: None,
                COOLDOWN_UNTIL: timestamp(cooldown),
            },
            remove_taints=True,
            remove_quarantine=True,
        )
        HealthHandler.publish_phase(node_name, "cooldown")

    @staticmethod
    def ready(node):
        return any(
            condition.get("type") == "Ready" and condition.get("status") == "True"
            for condition in node.get("status", {}).get("conditions", [])
        )

    def lease_age(self, node_name):
        lease = self.kube.get_lease(node_name)
        renew = parse_time((lease or {}).get("spec", {}).get("renewTime"))
        return float("inf") if renew is None else (utcnow() - renew).total_seconds()

    def active_count(self):
        response = self.kube.request("/api/v1/nodes") or {}
        active = 0
        for item in response.get("items", []):
            state = (item.get("metadata", {}).get("annotations") or {}).get(STATE, "")
            if state and state != "suspect":
                active += 1
        return active

    def ready_control_plane_count(self):
        response = self.kube.request("/api/v1/nodes") or {}
        return sum(
            1
            for item in response.get("items", [])
            if (
                "node-role.kubernetes.io/control-plane" in (item.get("metadata", {}).get("labels") or {})
                and self.ready(item)
            )
        )

    def reconcile(self, node_name, target):
        node = self.kube.get_node(node_name)
        if node is None:
            return
        metadata = node.get("metadata", {})
        annotations = metadata.get("annotations") or {}
        labels = metadata.get("labels") or {}
        state = annotations.get(STATE, "")
        now = utcnow()
        lease_age = self.lease_age(node_name)
        self.publish_node_metrics(node_name, node, lease_age, now)

        if labels.get(DISABLED_LABEL, "false").lower() == "true" and not state:
            return

        if not state:
            created = parse_time(metadata.get("creationTimestamp"))
            if created and (now - created).total_seconds() < self.config["minimum_node_age_seconds"]:
                return
            cooldown = parse_time(annotations.get(COOLDOWN_UNTIL))
            if cooldown and cooldown > now:
                return
            if lease_age < self.config["lease_timeout_seconds"]:
                return
            if self.ready_control_plane_count() < self.config["minimum_ready_controlplanes"]:
                return
            if self.active_count() >= self.config["max_concurrent_remediations"]:
                return
            logging.warning("node %s entered suspect state", node_name)
            self.set_state(node, "suspect")
            return

        state_since = parse_time(annotations.get(STATE_SINCE)) or now
        if state == "suspect":
            if lease_age < self.config["lease_timeout_seconds"]:
                logging.info("node %s recovered during confirmation window", node_name)
                self.kube.patch_node(node, annotations={STATE: None, STATE_SINCE: None, LAST_ERROR: None})
                HealthHandler.publish_phase(node_name, "healthy")
                return
            if (now - state_since).total_seconds() < self.config["confirmation_seconds"]:
                return
            if self.ready_control_plane_count() < self.config["minimum_ready_controlplanes"]:
                return
            if self.active_count() >= self.config["max_concurrent_remediations"]:
                return
            logging.warning("fencing node %s through PVE", node_name)
            node = self.set_state(node, "fencing")
            state = "fencing"

        if state == "fencing":
            try:
                status = self.pve.status(target["host"], target["vmid"])
                if status != "stopped":
                    self.pve.power(target["host"], target["vmid"], "stop")
                    deadline = time.monotonic() + self.config["execution_fence_timeout_seconds"]
                    while time.monotonic() < deadline:
                        time.sleep(2)
                        if self.pve.status(target["host"], target["vmid"]) == "stopped":
                            break
                    else:
                        raise RuntimeError("VM did not reach stopped state before the execution-fence timeout")
                node = self.kube.get_node(node_name)
                attached = bool(self.kube.rbd_volume_attachments(node_name))
                logging.warning("node %s is execution-fenced; applying out-of-service taints", node_name)
                node = self.kube.patch_node(
                    node,
                    annotations={
                        STATE: "storage-fencing",
                        STATE_SINCE: timestamp(),
                        HAD_RBD_ATTACHMENT: str(attached).lower(),
                        LAST_ERROR: None,
                    },
                    add_taints=True,
                )
                HealthHandler.publish_phase(node_name, "storage-fencing")
                state = "storage-fencing"
                state_since = now
                annotations = node.get("metadata", {}).get("annotations") or {}
            except Exception as error:  # keep the node isolated and retry safely
                logging.exception("execution fencing failed for %s", node_name)
                self.kube.patch_node(node, annotations={LAST_ERROR: str(error)[:512]})
                return

        if state == "storage-fencing":
            attachments = self.kube.rbd_volume_attachments(node_name)
            had_attachment = annotations.get(HAD_RBD_ATTACHMENT, "false") == "true"
            fence_ready = not had_attachment or self.kube.network_fence_succeeded(node_name)
            if attachments or not fence_ready:
                if (now - state_since).total_seconds() >= self.config["storage_fence_timeout_seconds"]:
                    detail = "waiting for VolumeAttachment deletion or successful CSI NetworkFence"
                    self.kube.patch_node(node, annotations={LAST_ERROR: detail})
                    logging.error("node %s remains stopped: %s", node_name, detail)
                return
            try:
                logging.warning("storage released for %s; starting its VM for a full power cycle", node_name)
                if self.pve.status(target["host"], target["vmid"]) == "stopped":
                    self.pve.power(target["host"], target["vmid"], "start")
                self.set_state(node, "recovering", {STABLE_SINCE: None})
            except Exception as error:
                logging.exception("failed to start %s", node_name)
                self.kube.patch_node(node, annotations={LAST_ERROR: str(error)[:512]})
            return

        if state == "recovering":
            try:
                if self.pve.status(target["host"], target["vmid"]) == "stopped":
                    self.pve.power(target["host"], target["vmid"], "start")
                    return
            except Exception as error:
                logging.exception("failed to verify or restart %s during recovery", node_name)
                self.kube.patch_node(node, annotations={LAST_ERROR: str(error)[:512]})
                return
            if not self.ready(node) or lease_age >= self.config["lease_timeout_seconds"]:
                if annotations.get(STABLE_SINCE):
                    self.kube.patch_node(node, annotations={STABLE_SINCE: None})
                return
            stable_since = parse_time(annotations.get(STABLE_SINCE))
            if stable_since is None:
                self.kube.patch_node(node, annotations={STABLE_SINCE: timestamp(), LAST_ERROR: None})
                return
            if (now - stable_since).total_seconds() < self.config["recovery_stability_seconds"]:
                return
            if annotations.get(HAD_RBD_ATTACHMENT, "false") == "true":
                logging.warning("node %s is stable; requesting storage unfencing while keeping quarantine", node_name)
                self.kube.patch_node(
                    node,
                    annotations={STATE: "unfencing", STATE_SINCE: timestamp(), STABLE_SINCE: None},
                    remove_taints=True,
                )
                HealthHandler.publish_phase(node_name, "unfencing")
            else:
                self.complete_recovery(node, node_name)

        if state == "unfencing" and self.kube.network_fence_released(node_name):
            self.complete_recovery(node, node_name)

    def run(self):
        interval = self.config["evaluation_interval_seconds"]
        while True:
            try:
                if self.kube.acquire_leader("pve-node-remediation", self.identity, max(15, interval * 3)):
                    HealthHandler.ready = True
                    HealthHandler.publish_controller(self.identity, True)
                    for node_name, target in self.config["nodes"].items():
                        try:
                            self.reconcile(node_name, target)
                        except Exception:
                            logging.exception("reconciliation failed for %s", node_name)
                else:
                    HealthHandler.ready = True
                    HealthHandler.publish_controller(self.identity, False)
            except Exception:
                HealthHandler.ready = False
                HealthHandler.publish_controller(self.identity, False)
                logging.exception("controller loop failed")
            time.sleep(interval)


def main():
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
    server = http.server.ThreadingHTTPServer(("0.0.0.0", 8080), HealthHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    Controller().run()


if __name__ == "__main__":
    main()
