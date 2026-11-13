"""Exercise realm retention payloads without connecting to Keycloak."""
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (ROOT / 'identity-config/configure-keycloak-realms.sh').read_text()
FUNCTIONS = '\n'.join(
    re.search(r'(?ms)^' + name + r'\(\) \{.*?^\}', SCRIPT).group()
    for name in ['json_contains_desired', 'api_put_realm_settings',
                 'configure_master_realm_settings', 'upsert_realm']
)


class EventRetentionTest(unittest.TestCase):
    def payload(self, master=False, seconds=None, exists=True, already_configured=False):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            settings = {'save_user_events': True, 'save_admin_events': True,
                        'save_admin_event_details': True}
            if seconds is not None:
                settings['events_retention_seconds'] = seconds
            (folder / 'realm.json').write_text(json.dumps({'name': 'example', 'settings': settings}))
            current = {'realm': 'master' if master else 'example', 'enabled': True,
                       'eventsEnabled': True, 'adminEventsEnabled': True,
                       'adminEventsDetailsEnabled': True, 'attributes': {'unrelated': 'keep'}}
            if already_configured:
                current['eventsExpiration'] = seconds or 7776000
                current['attributes']['adminEventsExpiration'] = str(seconds or 7776000)
            (folder / 'current.json').write_text(json.dumps(current))
            harness = r'''
set -euo pipefail
TMPDIR="$1"
KEYCLOAK_MASTER_REALM_SETTINGS_JSON="$2"
api() {
  if [[ "$1" == GET ]]; then
    cat "${TMPDIR}/current.json"
  else
    cp "$3" "${TMPDIR}/sent.json"
  fi
}
urlencode() { printf '%s' "$1"; }
realm_exists() { [[ "$3" == true ]]; }
'''
            # Keep the realm existence stub independent of the function's arguments.
            harness = harness.replace('realm_exists() { [[ "$3" == true ]]; }',
                                      'realm_exists() { ' + ('true' if exists else 'false') + '; }')
            command = 'configure_master_realm_settings' if master else 'upsert_realm "${TMPDIR}/realm.json"'
            subprocess.run(['bash', '-c', harness + FUNCTIONS + '\n' + command,
                            'test', tmp, json.dumps(settings)], check=True, capture_output=True, text=True)
            sent = folder / 'sent.json'
            return json.loads(sent.read_text()) if sent.exists() else None

    def test_default_applies_to_user_and_admin_in_master_and_managed_realms(self):
        for master in [True, False]:
            with self.subTest(master=master):
                payload = self.payload(master=master)
                self.assertEqual(payload['eventsExpiration'], 90 * 86400)
                self.assertEqual(payload['attributes']['adminEventsExpiration'], str(90 * 86400))
                self.assertEqual(payload['attributes']['unrelated'], 'keep')

    def test_cluster_override_applies_to_both_stores(self):
        for master in [True, False]:
            payload = self.payload(master=master, seconds=14 * 86400)
            self.assertEqual(payload['eventsExpiration'], 14 * 86400)
            self.assertEqual(payload['attributes']['adminEventsExpiration'], str(14 * 86400))

    def test_creation_includes_both_expirations(self):
        payload = self.payload(exists=False)
        self.assertEqual(payload['eventsExpiration'], 7776000)
        self.assertEqual(payload['attributes'], {'adminEventsExpiration': '7776000'})

    def test_aligned_realms_are_not_updated(self):
        for master in [True, False]:
            self.assertIsNone(self.payload(master=master, already_configured=True))


if __name__ == '__main__':
    unittest.main()
