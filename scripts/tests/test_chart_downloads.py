"""Exercise download-only retries, immutable cache reuse, and failed-download safety."""

import contextlib
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import chart_downloads as charts


def archive(name='example', version='1.2.3'):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz') as chart:
        content = f'apiVersion: v2\nname: {name}\nversion: "{version}"\n'.encode()
        entry = tarfile.TarInfo(name + '/Chart.yaml')
        entry.size = len(content)
        chart.addfile(entry, io.BytesIO(content))
    return buffer.getvalue()


class ChartDownloadTest(unittest.TestCase):
    def test_transient_failures_back_off_and_stop_after_four_attempts(self):
        delays, calls = [], []
        def download():
            calls.append(True)
            raise ConnectionRefusedError('connection refused')
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(ConnectionRefusedError):
            charts.retry_download(download, 'example', sleep=delays.append)
        self.assertEqual(len(calls), 4)
        self.assertEqual(delays, [2, 4, 8])

    def test_temporary_failure_then_success_returns_the_original_result(self):
        calls, delays = [], []
        def download():
            calls.append(True)
            if len(calls) < 3:
                raise subprocess.CalledProcessError(1, ['helm', 'pull'], stderr='Get: read: operation timed out')
            return b'verified chart bytes'
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(charts.retry_download(download, 'example', sleep=delays.append), b'verified chart bytes')
        self.assertEqual(delays, [2, 4])

    def test_permanent_failures_are_never_retried(self):
        errors = [
            urllib.error.HTTPError('https://example.com', code, 'error', {}, None)
            for code in [401, 403, 404]
        ] + [ValueError('chart checksum mismatch'), RuntimeError('x509: unknown authority'),
             subprocess.CalledProcessError(1, ['helm', 'pull'], stderr='failed: 403 Forbidden'),
             RuntimeError('chart version 1.2.3 not found')]
        for error in errors:
            with self.subTest(error=error), patch.object(charts.time, 'sleep') as sleep:
                calls = []
                def fail():
                    calls.append(True)
                    raise error
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(type(error)):
                    charts.retry_download(fail, 'example', sleep=sleep)
                self.assertEqual(len(calls), 1)
                sleep.assert_not_called()

    def test_retryable_http_statuses_are_limited_to_transient_errors(self):
        for code in [408, 429, 500, 502, 503, 504]:
            with urllib.error.HTTPError('https://example.com', code, '', {}, None) as error:
                self.assertTrue(charts.transient(error))
        with urllib.error.HTTPError('https://example.com', 422, '', {}, None) as error:
            self.assertFalse(charts.transient(error))

    def prepare(self, directory, data=None, repository='https://example.com/charts'):
        data = data if data is not None else archive()
        output = Path(directory) / 'example-1.2.3.tgz'
        source = {'chart': 'example', 'version': '1.2.3', 'repository': repository}
        calls = []
        def pull(command, **kwargs):
            calls.append(command)
            self.assertEqual(command[:2], ['helm', 'pull'])
            self.assertIn('--version', command)
            (Path(command[command.index('--destination') + 1]) / output.name).write_bytes(data)
            return subprocess.CompletedProcess(command, 0, '', '')
        with patch.object(charts.subprocess, 'run', side_effect=pull):
            charts.prepare_chart(source, output)
        return source, output, calls

    def test_pulled_bytes_are_unchanged_and_verified_cache_works_offline(self):
        for repository in ['https://example.com/charts', 'oci://example.com/charts']:
            with self.subTest(repository=repository), tempfile.TemporaryDirectory() as directory:
                data = archive()
                source, output, calls = self.prepare(directory, data, repository)
                self.assertEqual(output.read_bytes(), data)
                self.assertEqual(json.loads(output.with_suffix('.json').read_text())['sha256'], hashlib.sha256(data).hexdigest())
                before = output.stat().st_mtime_ns
                with patch.object(charts.subprocess, 'run', side_effect=AssertionError('Cache must work offline')):
                    charts.prepare_chart(source, output)
                self.assertEqual(output.stat().st_mtime_ns, before)
                if repository.startswith('oci:'):
                    self.assertEqual(calls[0][2], repository + '/example')
                else:
                    self.assertEqual(calls[0][calls[0].index('--repo') + 1], repository)

    def test_corrupt_cache_is_redownloaded_and_incorrect_chart_cannot_replace_it(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output, _ = self.prepare(directory)
            output.write_bytes(b'corrupt cache')
            self.prepare(directory)
            previous = output.read_bytes()
            output.with_suffix('.json').unlink()
            with self.assertRaisesRegex(ValueError, 'version'):
                self.prepare(directory, archive(version='9.9.9'))
            self.assertEqual(output.read_bytes(), previous)

    def test_failed_download_preserves_existing_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output, _ = self.prepare(directory)
            output.with_suffix('.json').unlink()
            previous = output.read_bytes()
            with patch.object(charts.subprocess, 'run', side_effect=RuntimeError('chart not found')), \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(RuntimeError):
                charts.prepare_chart(source, output)
            self.assertEqual(output.read_bytes(), previous)
            self.assertFalse(list(Path(directory).glob('.chart-download-*')))

    def test_unpinned_versions_are_rejected_before_network_access(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(charts.subprocess, 'run') as run:
            for version in ['latest', '*', '>=1.0.0', '1.2']:
                with self.subTest(version=version), self.assertRaises(ValueError):
                    charts.prepare_chart({'chart': 'example', 'version': version, 'repository': 'https://example.com'}, Path(directory) / 'chart.tgz')
            run.assert_not_called()

    def test_disabled_charts_do_not_require_any_download(self):
        with tempfile.TemporaryDirectory() as directory:
            catalog = {'unused': {'enabled': False}}
            result = subprocess.CompletedProcess(['tofu', 'console'], 0, json.dumps(json.dumps(catalog)), '')
            with patch.object(sys, 'argv', ['charts', '--workspace', directory]), \
                    patch.object(charts.subprocess, 'run', return_value=result), \
                    patch.object(charts, 'prepare_chart') as prepare:
                self.assertEqual(charts.main(), 0)
                prepare.assert_not_called()


if __name__ == '__main__':
    unittest.main()
