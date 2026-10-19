"""Verify registry parsing and Talos rendering without contacting a cluster."""

from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'gen-talos-assets.sh').read_text()


def function(name):
    return re.search(r'^' + name + r'\(\) \{\n.*?^\}', SOURCE, re.M | re.S).group()


class RegistryEndpointsTest(unittest.TestCase):
    def render(self, mirrors):
        with tempfile.TemporaryDirectory() as directory:
            constants = Path(directory, 'constants.auto.tfvars')
            constants.write_text('"talos" = {\n "registry" = {\n "mirrors" = {\n'
                                 + mirrors + '\n }\n "override_path" = "true"\n }\n}\n')
            setup = SOURCE[SOURCE.index('registry_skip_fallback="true"'):
                           SOURCE.index('for registry_boolean_name in')]
            render = SOURCE[SOURCE.index('machine_registries_section=""'):
                            SOURCE.index('if [[ -n "${cert_files_raw}" ]]')]
            script = 'set -euo pipefail\nconstants_path="$1"\n'
            script += '\n'.join(function(n) for n in ['trim', 'yaml_escape',
                                                     'registry_host_from_url', 'parse_talos_registry_settings'])
            script += '\n' + setup + '\n' + render + '\nprintf "%s" "$machine_registries_section"\n'
            return subprocess.run(['bash', '-c', script, 'bash', str(constants)],
                                  capture_output=True, text=True)

    def test_legacy_single_url(self):
        result = self.render('"docker.io" = "https://registry.example.com/v2/proxy"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('- "https://registry.example.com/v2/proxy"', result.stdout)
        self.assertIn('skipFallback: true', result.stdout)

    def test_ordered_paths_same_host_and_mixed_legacy_entry(self):
        for separator in [', ', ',\n']:
            with self.subTest(separator=separator):
                urls = ['https://registry.example.com/v2/' + p for p in ['project-a', 'project-b', 'upstream-cache']]
                entries = separator.join('"' + u + '"' for u in urls)
                result = self.render('"docker.io" = [\n' + entries + ',\n]\n'
                                     '"registry.k8s.io" = "https://registry.example.com/v2/proxy"')
                self.assertEqual(result.returncode, 0, result.stderr)
                positions = [result.stdout.index('- "' + u + '"') for u in urls]
                self.assertEqual(positions, sorted(positions))
                self.assertEqual(result.stdout.count('"registry.example.com":'), 1)
                self.assertEqual(result.stdout.count('overridePath: true'), 2)

    def test_inline_list_and_comments(self):
        result = self.render('"docker.io" = ["https://a.example.com", "https://b.example.com"] # ordered')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(result.stdout.index('a.example.com'), result.stdout.index('b.example.com'))

    def test_invalid_empty_or_duplicate_endpoints_fail(self):
        for value in ['[]', '["https://a.example.com", ""]', '"ftp://a.example.com"',
                      '["https://a.example.com", "https://a.example.com"]']:
            with self.subTest(value=value):
                result = self.render('"docker.io" = ' + value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Error:', result.stderr)


if __name__ == '__main__':
    unittest.main()
