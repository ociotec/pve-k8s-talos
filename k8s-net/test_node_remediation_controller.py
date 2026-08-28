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

    def network_fence_succeeded(self, _name):
        return self.fence_succeeded

    def network_fence_released(self, _name):
        return self.fence_succeeded


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
        }
        controller.kube = FakeKubernetes(worker)
        controller.pve = pve or FakeProxmox()
        return controller

    def test_stale_lease_enters_suspect_state(self):
        worker = node("worker-1", ready=False)
        controller = self.controller(worker)

        controller.reconcile("worker-1", {"host": "pve-1", "vmid": 101})

        self.assertEqual(worker["metadata"]["annotations"][remediation.STATE], "suspect")
        self.assertEqual(controller.pve.actions, [])

    @mock.patch.object(remediation.time, "sleep", return_value=None)
    def test_execution_fence_precedes_out_of_service_taints(self, _sleep):
        worker = node("worker-1", state="suspect", state_age=20, ready=False)
        controller = self.controller(worker)
        controller.kube.attachments = [{"metadata": {"name": "rbd"}}]

        controller.reconcile("worker-1", {"host": "pve-1", "vmid": 101})

        self.assertEqual(controller.pve.actions, ["stop"])
        self.assertEqual(worker["metadata"]["annotations"][remediation.STATE], "storage-fencing")
        self.assertEqual({taint["effect"] for taint in worker["spec"]["taints"]}, {"NoExecute", "NoSchedule"})

    def test_vm_stays_stopped_until_rbd_fence_succeeds(self):
        worker = node("worker-1", state="storage-fencing", state_age=70, ready=False)
        worker["metadata"]["annotations"][remediation.HAD_RBD_ATTACHMENT] = "true"
        pve = FakeProxmox(status="stopped")
        controller = self.controller(worker, pve)

        controller.reconcile("worker-1", {"host": "pve-1", "vmid": 101})
        self.assertEqual(pve.actions, [])

        controller.kube.fence_succeeded = True
        controller.reconcile("worker-1", {"host": "pve-1", "vmid": 101})
        self.assertEqual(pve.actions, ["start"])
        self.assertEqual(worker["metadata"]["annotations"][remediation.STATE], "recovering")

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
