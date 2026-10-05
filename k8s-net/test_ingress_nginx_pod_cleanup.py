"""Verify retention, ownership and deletion races without a Kubernetes API."""

import copy
import datetime as dt
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "cleanup", Path(__file__).with_name("ingress-nginx-pod-cleanup.py")
)
cleanup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cleanup)
NOW = dt.datetime(2026, 1, 1, 12, tzinfo=dt.timezone.utc)


def owner(kind, name, uid):
    return {"apiVersion": "apps/v1", "kind": kind, "name": name, "uid": uid, "controller": True}


def pod(age=300):
    finished = (NOW - dt.timedelta(seconds=age)).isoformat()
    return {
        "metadata": {
            "name": "completed", "uid": "pod-uid", "resourceVersion": "42",
            "ownerReferences": [owner("ReplicaSet", "ingress-rs", "rs-uid")],
        },
        "spec": {"containers": [{"name": "controller"}]},
        "status": {"phase": "Succeeded", "containerStatuses": [{
            "name": "controller", "state": {"terminated": {"finishedAt": finished}},
        }]},
    }


class FakeAPI:
    def __init__(self, candidate):
        self.candidate = candidate
        self.current = copy.deepcopy(candidate)
        self.deployment = {"metadata": {"uid": "deploy-uid"}}
        self.rs = {"metadata": {
            "uid": "rs-uid",
            "ownerReferences": [owner("Deployment", "ingress-nginx-controller", "deploy-uid")],
        }}
        self.deleted = []
        self.deployment_reads = 0
        self.replace_deployment = False
        self.delete_conflict = False
        self.paginate = False
        self.queries = []

    def request(self, path, method="GET", payload=None):
        if method == "DELETE":
            self.deleted.append(payload)
            return None if self.delete_conflict else {"status": "Success"}
        if "/deployments/" in path:
            self.deployment_reads += 1
            if self.replace_deployment and self.deployment_reads > 1:
                return {"metadata": {"uid": "replacement"}}
            return self.deployment
        if "/replicasets/" in path:
            return self.rs
        if "pods?" in path:
            self.queries.append(path)
            if self.paginate and len(self.queries) == 1:
                return {"items": [], "metadata": {"continue": "next"}}
            return {"items": [self.candidate]}
        return self.current


class CleanupTest(unittest.TestCase):
    def run_cleanup(self, api, **kwargs):
        return cleanup.cleanup(api, "ingress-nginx", "ingress-nginx-controller", 300, now=NOW, **kwargs)

    def test_retention_boundary_and_delete_preconditions(self):
        api = FakeAPI(pod())
        result = self.run_cleanup(api)
        self.assertEqual(result["deleted"], 1)
        self.assertEqual(api.deleted[0]["preconditions"], {"uid": "pod-uid", "resourceVersion": "42"})

    def test_recent_or_future_completion_is_retained(self):
        for age in (299, 0, -60):
            with self.subTest(age=age):
                api = FakeAPI(pod(age))
                self.run_cleanup(api)
                self.assertFalse(api.deleted)

    def test_last_container_finish_controls_retention(self):
        candidate = pod(600)
        candidate["spec"]["containers"].append({"name": "sidecar"})
        candidate["status"]["containerStatuses"].append({
            "name": "sidecar", "state": {"terminated": {"finishedAt": NOW.isoformat()}},
        })
        api = FakeAPI(candidate)
        self.run_cleanup(api)
        self.assertFalse(api.deleted)

    def test_non_succeeded_deleting_or_unknown_finish_is_skipped(self):
        candidates = []
        for phase in ("Running", "Pending", "Failed"):
            candidate = pod(); candidate["status"]["phase"] = phase; candidates.append(candidate)
        candidate = pod(); candidate["metadata"]["deletionTimestamp"] = NOW.isoformat(); candidates.append(candidate)
        for stamp in (None, "invalid", "2026-01-01T10:00:00"):
            candidate = pod()
            candidate["status"]["containerStatuses"][0]["state"]["terminated"]["finishedAt"] = stamp
            candidates.append(candidate)
        candidate = pod(); candidate["status"]["containerStatuses"] = []; candidates.append(candidate)
        for candidate in candidates:
            with self.subTest(candidate=candidate):
                api = FakeAPI(candidate); self.run_cleanup(api); self.assertFalse(api.deleted)

    def test_unrelated_or_recreated_owners_are_skipped(self):
        for change in ("missing", "job", "rs-uid", "deployment-uid", "deployment-name"):
            with self.subTest(change=change):
                api = FakeAPI(pod())
                if change == "missing": api.candidate["metadata"]["ownerReferences"] = []
                if change == "job": api.candidate["metadata"]["ownerReferences"][0]["kind"] = "Job"
                if change == "rs-uid": api.rs["metadata"]["uid"] = "replacement"
                if change == "deployment-uid": api.rs["metadata"]["ownerReferences"][0]["uid"] = "other"
                if change == "deployment-name": api.rs["metadata"]["ownerReferences"][0]["name"] = "other"
                self.run_cleanup(api); self.assertFalse(api.deleted)

    def test_state_and_identity_races_are_skipped(self):
        for change in ("uid", "phase", "finished", "owner"):
            with self.subTest(change=change):
                api = FakeAPI(pod())
                if change == "uid": api.current["metadata"]["uid"] = "replacement"
                if change == "phase": api.current["status"]["phase"] = "Running"
                if change == "finished": api.current = pod(1)
                if change == "owner": api.current["metadata"]["ownerReferences"] = []
                self.run_cleanup(api); self.assertFalse(api.deleted)

    def test_deployment_replacement_stops_cleanup(self):
        api = FakeAPI(pod()); api.replace_deployment = True
        with self.assertRaisesRegex(RuntimeError, "identity changed"):
            self.run_cleanup(api)
        self.assertFalse(api.deleted)

    def test_delete_conflict_is_not_counted_as_deleted(self):
        api = FakeAPI(pod()); api.delete_conflict = True
        self.assertEqual(self.run_cleanup(api)["deleted"], 0)

    def test_pagination_and_server_side_filters(self):
        api = FakeAPI(pod()); api.paginate = True
        self.assertEqual(self.run_cleanup(api)["deleted"], 1)
        self.assertEqual(len(api.queries), 2)
        self.assertIn("fieldSelector=status.phase%3DSucceeded", api.queries[0])
        self.assertIn("continue=next", api.queries[1])

    def test_dry_run_never_deletes(self):
        api = FakeAPI(pod())
        self.run_cleanup(api, dry_run=True)
        self.assertFalse(api.deleted)

    def test_api_errors_are_not_silenced(self):
        class Broken(FakeAPI):
            def request(self, *args, **kwargs):
                raise RuntimeError("API unavailable")
        with self.assertRaisesRegex(RuntimeError, "API unavailable"):
            self.run_cleanup(Broken(pod()))


if __name__ == "__main__":
    unittest.main()
