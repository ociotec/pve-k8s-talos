import copy
import datetime as dt
import importlib.util
import pathlib
import unittest
from unittest import mock


MODULE_PATH = pathlib.Path(__file__).with_name("node-remediation-controller.py")
SPEC = importlib.util.spec_from_file_location("node_remediation_controller", MODULE_PATH)
remediation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(remediation)


def ago(seconds):
    return remediation.timestamp(remediation.utcnow() - dt.timedelta(seconds=seconds))


def node(name, *, state="", state_age=0, ready=True):
    annotations = {}
    if state:
        annotations[remediation.STATE] = state
        annotations[remediation.STATE_SINCE] = ago(state_age)
    return {
        "metadata": {
            "name": name,
            "creationTimestamp": ago(3600),
            "annotations": annotations,
            "labels": {},
        },
        "spec": {"taints": []},
        "status": {"conditions": [{"type": "Ready", "status": "True" if ready else "Unknown"}]},
    }


class FakeKubernetes:
    def __init__(self, worker):
        self.worker = worker
        self.controlplanes = []
        for index in range(3):
            item = node(f"cp-{index}")
            item["metadata"]["labels"]["node-role.kubernetes.io/control-plane"] = ""
            self.controlplanes.append(item)
        self.lease_age_seconds = 60
        self.attachments = []
        self.fence_succeeded = False
        self.fence_requests = []

    def get_node(self, _name):
        return self.worker

    def get_lease(self, _name):
        return {"spec": {"renewTime": ago(self.lease_age_seconds)}}

    def request(self, path, *_args):
        if path == "/api/v1/nodes":
            return {"items": [self.worker, *self.controlplanes]}
        raise AssertionError(path)

    def patch_node(self, item, annotations=None, add_taints=False, remove_taints=False, remove_quarantine=False):
        stored = item["metadata"].setdefault("annotations", {})
        for key, value in (annotations or {}).items():
            if value is None:
                stored.pop(key, None)
            else:
                stored[key] = str(value)
        taints = item["spec"].setdefault("taints", [])
        if remove_taints:
            taints[:] = [taint for taint in taints if taint.get("key") != remediation.OUT_OF_SERVICE]
        if remove_quarantine:
            taints[:] = [taint for taint in taints if taint.get("key") != remediation.QUARANTINE]
        if add_taints:
            taints.extend(copy.deepcopy(remediation.TAINTS))
        return item

    def rbd_volume_attachments(self, _name):
        return self.attachments

    def ensure_network_fenced(self, name, cidrs, config):
        self.fence_requests.append(("fence", name, cidrs, config))
        return self.fence_succeeded

    def request_network_unfence(self, name):
        self.fence_requests.append(("unfence", name))
        return self.fence_succeeded

    def delete_network_fence(self, name):
        self.fence_requests.append(("delete", name))


class FakeProxmox:
    def __init__(self, status="running"):
        self.current_status = status
        self.actions = []

    def status(self, _host, _vmid):
        return self.current_status

    def power(self, _host, _vmid, action):
        self.actions.append(action)
        self.current_status = "stopped" if action == "stop" else "running"


class ControllerTest(unittest.TestCase):
    def test_timestamp_uses_kubernetes_microtime_format(self):
        value = dt.datetime(2026, 8, 28, 10, 0, tzinfo=dt.timezone.utc)

        self.assertEqual(remediation.timestamp(value), "2026-08-28T10:00:00.000000Z")

    def test_kubernetes_patch_sends_null_for_annotations_to_remove(self):
        kube = remediation.Kubernetes.__new__(remediation.Kubernetes)
        kube.request = mock.Mock(return_value={})
        worker = node("worker-1", state="recovering")

        kube.patch_node(worker, annotations={remediation.STATE: None, remediation.LAST_ERROR: None})

        payload = kube.request.call_args.args[2]
        self.assertEqual(
            payload["metadata"]["annotations"],
            {remediation.STATE: None, remediation.LAST_ERROR: None},
        )
        self.assertEqual(kube.request.call_args.args[3], "application/merge-patch+json")

    def test_prometheus_metrics_include_leader_and_node_progress(self):
        remediation.HealthHandler.publish_controller("controller-1", True)
        remediation.HealthHandler.publish_node("worker-1", "storage-fencing", 100.0, 28.5, True)

        metrics = remediation.HealthHandler.render_metrics()

        self.assertIn('node_remediation_controller_leader{identity="controller-1"} 1', metrics)
        self.assertIn('node_remediation_node_phase{worker="worker-1",phase="storage-fencing"} 1', metrics)
        self.assertIn('node_remediation_node_lease_age_seconds{worker="worker-1"} 28.500', metrics)
        self.assertIn('node_remediation_node_error{worker="worker-1"} 1', metrics)

        remediation.HealthHandler.publish_phase("worker-1", "fencing")
        metrics = remediation.HealthHandler.render_metrics()
        self.assertIn('node_remediation_node_phase{worker="worker-1",phase="fencing"} 1', metrics)
        self.assertIn('node_remediation_node_error{worker="worker-1"} 0', metrics)

    def controller(self, worker, pve=None):
        controller = remediation.Controller.__new__(remediation.Controller)
        controller.config = {
            "lease_timeout_seconds": 20,
            "confirmation_seconds": 5,
            "execution_fence_timeout_seconds": 45,
            "storage_fence_timeout_seconds": 60,
            "recovery_stability_seconds": 30,
            "node_cooldown_seconds": 600,
            "max_concurrent_remediations": 1,
            "minimum_ready_controlplanes": 2,
            "minimum_node_age_seconds": 300,
            "network_fence": {
                "driver": "rook-ceph.rbd.csi.ceph.com",
                "secret_name": "rook-csi-rbd-provisioner",
                "secret_namespace": "rook-ceph",
                "parameters": {"clusterID": "rook-ceph"},
            },
        }
        controller.kube = FakeKubernetes(worker)
        controller.pve = pve or FakeProxmox()
        return controller

    def test_stale_lease_enters_suspect_state(self):
        worker = node("worker-1", ready=False)
        controller = self.controller(worker)

        controller.reconcile(
            "worker-1", {"host": "pve-1", "vmid": 101, "fence_cidrs": ["192.0.2.10/32"]}
        )

        self.assertEqual(worker["metadata"]["annotations"][remediation.STATE], "suspect")
        self.assertEqual(controller.pve.actions, [])

    @mock.patch.object(remediation.time, "sleep", return_value=None)
    def test_execution_fence_precedes_out_of_service_taints(self, _sleep):
        worker = node("worker-1", state="suspect", state_age=20, ready=False)
        controller = self.controller(worker)
        controller.kube.attachments = [{"metadata": {"name": "rbd"}}]

        controller.reconcile(
            "worker-1", {"host": "pve-1", "vmid": 101, "fence_cidrs": ["192.0.2.10/32"]}
        )

        self.assertEqual(controller.pve.actions, ["stop"])
        self.assertEqual(worker["metadata"]["annotations"][remediation.STATE], "storage-fencing")
        self.assertEqual({taint["effect"] for taint in worker["spec"]["taints"]}, {"NoExecute", "NoSchedule"})

    def test_vm_stays_stopped_until_rbd_fence_succeeds(self):
        worker = node("worker-1", state="storage-fencing", state_age=70, ready=False)
        worker["metadata"]["annotations"][remediation.HAD_RBD_ATTACHMENT] = "true"
        pve = FakeProxmox(status="stopped")
        controller = self.controller(worker, pve)

        target = {"host": "pve-1", "vmid": 101, "fence_cidrs": ["192.0.2.10/32"]}
        controller.reconcile("worker-1", target)
        self.assertEqual(pve.actions, [])
        self.assertEqual(controller.kube.fence_requests[0][:3], ("fence", "worker-1", ["192.0.2.10/32"]))

        controller.kube.fence_succeeded = True
        controller.reconcile("worker-1", target)
        self.assertEqual(pve.actions, ["start"])
        self.assertEqual(worker["metadata"]["annotations"][remediation.STATE], "recovering")

    def test_stable_rbd_node_is_unfenced_before_quarantine_is_removed(self):
        worker = node("worker-1", state="recovering", state_age=120, ready=True)
        worker["metadata"]["annotations"].update(
            {remediation.STABLE_SINCE: ago(70), remediation.HAD_RBD_ATTACHMENT: "true"}
        )
        worker["spec"]["taints"] = list(copy.deepcopy(remediation.TAINTS))
        controller = self.controller(worker, FakeProxmox(status="running"))
        controller.kube.lease_age_seconds = 1

        controller.reconcile("worker-1", {"host": "pve-1", "vmid": 101})
        self.assertEqual(worker["metadata"]["annotations"][remediation.STATE], "unfencing")
        self.assertEqual([taint["key"] for taint in worker["spec"]["taints"]], [remediation.QUARANTINE])

        controller.kube.fence_succeeded = True
        controller.reconcile("worker-1", {"host": "pve-1", "vmid": 101})
        self.assertEqual(controller.kube.fence_requests, [("unfence", "worker-1"), ("delete", "worker-1")])
        self.assertNotIn(remediation.STATE, worker["metadata"]["annotations"])
        self.assertEqual(worker["spec"]["taints"], [])

    def test_stable_recovered_node_is_reintegrated(self):
        worker = node("worker-1", state="recovering", state_age=120, ready=True)
        worker["metadata"]["annotations"][remediation.STABLE_SINCE] = ago(70)
        worker["spec"]["taints"] = list(copy.deepcopy(remediation.TAINTS))
        pve = FakeProxmox(status="running")
        controller = self.controller(worker, pve)
        controller.kube.lease_age_seconds = 1

        controller.reconcile("worker-1", {"host": "pve-1", "vmid": 101})

        self.assertNotIn(remediation.STATE, worker["metadata"]["annotations"])
        self.assertIn(remediation.COOLDOWN_UNTIL, worker["metadata"]["annotations"])
        self.assertEqual(worker["spec"]["taints"], [])


if __name__ == "__main__":
    unittest.main()
