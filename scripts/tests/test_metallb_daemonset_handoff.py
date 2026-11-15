"""Verify the MetalLB handoff cannot remove unrelated state or recreate a workload."""

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('metallb_handoff', Path(__file__).resolve().parents[1] / 'migrate-metallb-daemonset-state.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def fixture():
    manifest = {'apiVersion': 'apps/v1', 'kind': 'DaemonSet',
                'metadata': {'namespace': 'metallb-system', 'name': 'speaker'},
                'spec': {'selector': {'matchLabels': {'app': 'speaker'}}}}
    live = copy.deepcopy(manifest)
    live['metadata']['uid'] = 'existing-uid'
    instance = {'index_key': 'release-specific-index', 'attributes': {
        'manifest': {'value': manifest}, 'object': {'value': copy.deepcopy(live)},
    }}
    resource = {'mode': 'managed', 'type': 'kubernetes_manifest', 'name': 'metallb_native', 'instances': [instance]}
    return {'resources': [resource]}, manifest, live


class MetalLBHandoffTest(unittest.TestCase):
    def test_only_the_exact_root_daemonset_state_is_selected(self):
        state, desired, _ = fixture()
        unrelated = copy.deepcopy(state['resources'][0])
        unrelated['name'] = 'monitoring_other'
        state['resources'].append(unrelated)
        nested = copy.deepcopy(state['resources'][0])
        nested['module'] = 'module.example'
        state['resources'].append(nested)
        controller = copy.deepcopy(state['resources'][0]['instances'][0])
        controller['index_key'] = 'controller'
        controller['attributes']['manifest']['value']['kind'] = 'Deployment'
        state['resources'][0]['instances'].append(controller)
        selected = MODULE.candidates(state, [desired])
        self.assertEqual([entry[0] for entry in selected], ['kubernetes_manifest.metallb_native["release-specific-index"]'])

    def test_missing_desired_object_or_changed_identity_aborts(self):
        state, desired, live = fixture()
        with self.assertRaisesRegex(ValueError, 'desired inventory'):
            MODULE.candidates(state, [])
        for field in ['uid', 'name', 'namespace']:
            changed = copy.deepcopy(live)
            changed['metadata'][field] = 'different'
            with self.subTest(field=field), self.assertRaises(ValueError):
                MODULE.verify_live(state['resources'][0]['instances'][0], desired, changed)
        changed = copy.deepcopy(live)
        changed['spec']['selector']['matchLabels']['app'] = 'other'
        with self.assertRaisesRegex(ValueError, 'selector'):
            MODULE.verify_live(state['resources'][0]['instances'][0], desired, changed)

    def commands(self, root, state, desired, live):
        calls = []
        def run(command, payload=None):
            calls.append(command)
            if command[0] == 'git':
                return str(root / '.git')
            if command[0] == 'kubectl':
                self.assertIn('get', command)
                self.assertNotIn('delete', command)
                self.assertNotIn('apply', command)
                return json.dumps(live)
            if command[-2:] == ['state', 'pull']:
                return json.dumps(state)
            if 'console' in command:
                return json.dumps(json.dumps([desired]))
            self.assertIn('rm', command)
            return ''
        return calls, run

    def test_fresh_workspace_needs_no_state_or_cluster_access(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def fail(*args):
                raise AssertionError('Fresh workspace must not read or remove existing state')
            self.assertEqual(MODULE.handoff(root, root / 'kubeconfig', root, True, run=fail), 0)

    def test_inspection_is_read_only_and_execution_backs_up_before_state_rm(self):
        for apply in [False, True]:
            with self.subTest(execute=apply), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'terraform.tfstate').write_text('{}')
                (root / '.git').mkdir()
                state, desired, live = fixture()
                calls, run = self.commands(root, state, desired, live)
                self.assertEqual(MODULE.handoff(root, root / 'kubeconfig', root, apply, run=run), 1)
                removals = [c for c in calls if c[0] == 'tofu' and 'rm' in c]
                backups = list((root / '.git').rglob('*.json'))
                self.assertEqual(len(removals), int(apply))
                self.assertEqual(len(backups), int(apply))
                if apply:
                    self.assertEqual(json.loads(backups[0].read_text()), state)
                    self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)
                    self.assertIn('-lock-timeout=60s', removals[0])
                    self.assertEqual(removals[0][-1], 'kubernetes_manifest.metallb_native["release-specific-index"]')

    def test_foreign_live_uid_cannot_change_state_even_with_execute(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'terraform.tfstate').write_text('{}')
            state, desired, live = fixture()
            live['metadata']['uid'] = 'replacement'
            calls, run = self.commands(root, state, desired, live)
            with self.assertRaisesRegex(ValueError, 'UID'):
                MODULE.handoff(root, root / 'kubeconfig', root, True, run=run)
            self.assertFalse(any('rm' in call for call in calls))
            self.assertFalse((root / '.git').exists())

    def test_completed_handoff_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'terraform.tfstate').write_text('{}')
            _, desired, live = fixture()
            calls, run = self.commands(root, {'resources': []}, desired, live)
            self.assertEqual(MODULE.handoff(root, root / 'kubeconfig', root, True, run=run), 0)
            self.assertFalse(any(c[0] in ['git', 'kubectl'] or 'rm' in c for c in calls))


if __name__ == '__main__':
    unittest.main()
