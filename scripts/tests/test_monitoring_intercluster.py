"""Check offline configuration, credential safety, and the actual query proxy."""

import importlib.util
from http.server import BaseHTTPRequestHandler, HTTPServer
import threading
import textwrap
import json
import os
import platform
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
TOFU = os.environ.get("TOFU_BIN", "tofu")


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DEFAULTS = load("monitoring_defaults", "prepare-monitoring-defaults.py")
CREDENTIALS = load("monitoring_credentials", "prepare-monitoring-peer-credentials.py")


class CredentialsTest(unittest.TestCase):
    def test_directed_credentials_preserve_other_secrets_and_are_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            publisher, consumer = [Path(directory) / name for name in ["site2-dev", "site1-dev"]]
            for cluster in [publisher, consumer]:
                (cluster / "secrets").mkdir(parents=True)
                (cluster / "secrets/credentials.json").write_text(json.dumps({"identity": {"untouched": "value"}}))
            CREDENTIALS.prepare(publisher, consumer)
            paths = [p / "secrets/credentials.json" for p in [publisher, consumer]]
            original = [p.read_bytes() for p in paths]
            exported, imported = [json.loads(p.read_text()) for p in paths]
            reader = exported["monitoring"]["intercluster_readers"][consumer.name]
            self.assertEqual(imported["monitoring"]["remote_clusters"][publisher.name],
                             {key: reader[key] for key in ["username", "password"]})
            self.assertTrue(reader["htpasswd"].startswith("$apr1$"))
            self.assertEqual(exported["identity"], {"untouched": "value"})
            self.assertEqual(imported["identity"], {"untouched": "value"})
            self.assertTrue(all(path.stat().st_mode & 0o777 == 0o600 for path in paths))
            CREDENTIALS.prepare(publisher, consumer)
            self.assertEqual(original, [p.read_bytes() for p in paths])
            imported["monitoring"]["remote_clusters"][publisher.name]["password"] = "different"
            paths[1].write_text(json.dumps(imported))
            with self.assertRaisesRegex(ValueError, "differ"):
                CREDENTIALS.prepare(publisher, consumer)
            self.assertEqual(paths[0].read_bytes(), original[0])


class OfflineConfigurationTest(unittest.TestCase):
    def test_defaults_only_fill_omitted_configuration(self):
        rendered = DEFAULTS.render('locals {\n grafana_datasource_suffix = "SITE"\n grafana_remote_clusters = {}\n}\n')
        self.assertNotIn("grafana_datasource_suffix =", rendered)
        self.assertNotIn("grafana_remote_clusters =", rendered)
        self.assertIn("monitoring_api_consumers = []", rendered)
        self.assertIn("monitoring_query_api = {}", rendered)

    @unittest.skipUnless(shutil.which(TOFU), "OpenTofu is required")
    def test_independent_cluster_and_five_offline_peers(self):
        # Evaluate production locals, preconditions and random IDs locally.
        # Peer URLs intentionally cannot resolve; no cluster API is contacted.
        source = (ROOT / "monitoring/intercluster.tf").read_text().split('resource "kubernetes_secret_v1"', 1)[0]
        fixture = '''
terraform {
  required_providers {
    random = {
      source = "hashicorp/random"
      version = ">= 3.8.1"
    }
  }
}
variable "peer_count" { default = 0 }
variable "suffix" { default = "" }
variable "endpoint_generation" { default = 1 }
variable "password" { default = "test-password" }
variable "bad_url" { default = false }
variable "bad_ca" { default = false }
variable "bad_password" { default = false }
variable "duplicate_suffix" { default = false }
locals {
  domain = "example.com"
  grafana_datasource_suffix = var.suffix
  monitoring_api_consumers = var.peer_count > 0 ? ["consumer"] : []
  monitoring_query_api = {}
  grafana_operator_enabled_value = true
  grafana_operator_register_existing_instance_value = true
  monitoring_credentials = {
    intercluster_readers = { consumer = { username = "reader", htpasswd = "$apr1$salt$hash" } }
    remote_clusters = { for i in range(var.peer_count) : "peer-${i}" => {
      username = "reader"
      password = var.bad_password ? "" : var.password
    } }
  }
  grafana_remote_clusters = { for i in range(var.peer_count) : "peer-${i}" => {
    datasource_suffix = var.duplicate_suffix ? "LOCAL" : "SITE-${i}"
    prometheus_url = var.bad_url ? "http://peer.invalid" : "https://prometheus-${i}-${var.endpoint_generation}.invalid"
    loki_url = "https://loki-${i}.invalid"
    tempo_url = "https://tempo-${i}.invalid"
    credentials_secret_ref = "reader-${i}"
    ca_file = var.bad_ca ? "missing.pem" : "ca.pem"
  } }
}
output "local_sources" { value = { for source in local.grafana_local_datasources : source.type => source } }
output "remote_sources" { value = local.grafana_remote_sources }
output "remote_uids" { value = { for key, id in random_id.grafana_remote_datasource_uid : key => id.hex } }
output "enabled" { value = local.monitoring_query_enabled }
'''
        tests = '''
run "independent" {
  command = plan
  assert {
    condition = !output.enabled && length(output.remote_sources) == 0 && output.local_sources.prometheus.name == "Prometheus" && !contains(keys(output.local_sources.prometheus), "uid")
    error_message = "Independent clusters must retain legacy sources and publish no query gateway."
  }
}
run "five_offline_peers" {
  command = apply
  variables {
    peer_count = 5
    suffix = "LOCAL"
  }
  assert {
    condition = output.enabled && length(output.remote_sources) == 15 && output.local_sources.prometheus.name == "Prometheus LOCAL" && output.local_sources.prometheus.uid == "PBFA97CFB590B2093"
    error_message = "Five offline peers must plan without affecting existing datasource UIDs."
  }
  assert {
    condition = output.local_sources.tempo.jsonData.tracesToLogsV2.datasourceUid == output.local_sources.loki.uid && output.local_sources.tempo.jsonData.serviceMap.datasourceUid == output.local_sources.prometheus.uid && output.local_sources.tempo.jsonData.tracesToLogsV2.filterByTraceID == true
    error_message = "Local Tempo correlations must stay local."
  }
  assert {
    condition = length(output.remote_uids) == 15 && length(distinct(values(output.remote_uids))) == 15 && alltrue([for uid in values(output.remote_uids) : can(regex("^[a-f0-9]{24}$", uid))])
    error_message = "Remote UIDs must be generated uniquely and persisted in state."
  }
}
'''
        for flag in ["bad_url", "bad_ca", "bad_password", "duplicate_suffix"]:
            tests += f'''
run "reject_{flag}" {{
  command = plan
  variables {{
    peer_count = 1
    suffix = "LOCAL"
    {flag} = true
  }}
  expect_failures = [terraform_data.monitoring_intercluster_configuration]
}}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "main.tf").write_text(source + fixture)
            (path / "offline.tftest.hcl").write_text(tests)
            shutil.copy(ROOT / "monitoring/query-api.conf", path)
            (path / "grafana").mkdir()
            shutil.copy(ROOT / "monitoring/grafana/rename-local-datasources.sql.tftpl", path / "grafana")
            shutil.copy(ROOT / "monitoring/.terraform.lock.hcl", path)
            (path / "ca.pem").write_text("test-public-ca")
            init = [TOFU, "init", "-backend=false", "-input=false", "-no-color"]
            providers = ROOT / "monitoring/.terraform/providers"
            locked = re.search(r'provider "[^"]*/hashicorp/random" \{\s*version\s*=\s*"([^"]+)"',
                               (ROOT / "monitoring/.terraform.lock.hcl").read_text())[1]
            architecture = {"x86_64": "amd64", "aarch64": "arm64"}.get(platform.machine(), platform.machine())
            package = providers / "registry.opentofu.org/hashicorp/random" / locked / (platform.system().lower() + "_" + architecture)
            if any(p.is_file() for p in package.glob("terraform-provider-random*")):
                init += [f"-plugin-dir={providers}"]
            for command in [init, [TOFU, "test", "-no-color"]]:
                result = subprocess.run(command, cwd=path, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            # Apply only the random/built-in fixture, then inspect a second
            # plan against its real state. No Kubernetes resource is present.
            for arguments in [
                ["apply", "-auto-approve", "-input=false", "-no-color", "-var=peer_count=2", "-var=suffix=LOCAL"],
                ["plan", "-input=false", "-no-color", "-out=renamed.plan", "-var=peer_count=2", "-var=suffix=RENAMED", "-var=endpoint_generation=2", "-var=password=changed-test-password"],
            ]:
                result = subprocess.run([TOFU] + arguments, cwd=path, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            before = json.loads(subprocess.check_output([TOFU, "output", "-json", "remote_uids"], cwd=path))
            plan = json.loads(subprocess.check_output([TOFU, "show", "-json", "renamed.plan"], cwd=path))
            self.assertEqual(before, plan["planned_values"]["outputs"]["remote_uids"]["value"])
            random_changes = [change for change in plan["resource_changes"] if change["type"] == "random_id"]
            self.assertEqual(len(random_changes), 6)
            self.assertTrue(all(change["change"]["actions"] == ["no-op"] for change in random_changes))


@unittest.skipUnless(os.environ.get("MONITORING_PROXY_DOCKER_TEST") == "1", "Enable local Docker integration explicitly")
class GrafanaRenameTest(unittest.TestCase):
    def test_rename_preserves_identity_permissions_and_rolls_back_conflicts(self):
        name = "monitoring-rename-test-" + os.urandom(5).hex()
        sources = [
            {"uid": "PBFA97CFB590B2093", "type": "prometheus", "name": "Prometheus SITE'ONE", "url": "http://prometheus.monitoring.svc.cluster.local:9090"},
            {"uid": "P8E80F9AEF21F6940", "type": "loki", "name": "Loki SITE'ONE", "url": "http://loki.monitoring.svc.cluster.local:3100"},
        ]
        with tempfile.TemporaryDirectory() as directory:
            expression = "jsonencode(templatefile(" + json.dumps(str(ROOT / "monitoring/grafana/rename-local-datasources.sql.tftpl")) + ", {datasources = jsondecode(" + json.dumps(json.dumps(sources)) + ")}))"
            rendered = subprocess.run([TOFU, "console"], cwd=directory, input=expression + "\n", capture_output=True, text=True, check=True)
            sql = json.loads(json.loads(rendered.stdout))

        def psql(statement, check=True):
            result = subprocess.run(["docker", "exec", "-i", name, "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-At"], input=statement, capture_output=True, text=True)
            if check:
                self.assertEqual(result.returncode, 0, result.stderr)
            return result

        def rows():
            return json.loads(psql("SELECT json_agg(t ORDER BY id) FROM data_source t;").stdout)

        try:
            result = subprocess.run(["docker", "run", "--detach", "--name", name, "--network", "none", "--env", "POSTGRES_HOST_AUTH_METHOD=trust", "--tmpfs", "/var/lib/postgresql", "postgres:18.6"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            deadline = time.monotonic() + 30
            while subprocess.run(["docker", "exec", name, "pg_isready", "-U", "postgres"], capture_output=True).returncode:
                self.assertLess(time.monotonic(), deadline, "Test PostgreSQL did not start")
                time.sleep(0.2)
            # New installations have no Grafana schema yet.
            psql(sql)
            psql("""CREATE TABLE data_source (id int PRIMARY KEY, org_id int, uid text UNIQUE, name text UNIQUE, type text, url text, read_only boolean, secure_json_data text);
INSERT INTO data_source VALUES
(1,1,'PBFA97CFB590B2093','Prometheus','prometheus','http://prometheus.monitoring.svc.cluster.local:9090',true,'encrypted-fixture'),
(2,1,'P8E80F9AEF21F6940','Loki','loki','http://loki.monitoring.svc.cluster.local:3100',true,'encrypted-fixture'),
(3,1,'remote-uid','Remote','prometheus','https://remote.example.com',false,'other-fixture');""")
            original = rows()
            psql(sql)
            renamed = rows()
            self.assertEqual([row["name"] for row in renamed], [sources[0]["name"], sources[1]["name"], "Remote"])
            for before, after in zip(original, renamed):
                self.assertEqual({k: v for k, v in before.items() if k != "name"}, {k: v for k, v in after.items() if k != "name"})
            psql(sql)
            self.assertEqual(rows(), renamed)
            # A bad local identity fails and rolls back the whole migration.
            psql("UPDATE data_source SET url='https://unexpected.example.com' WHERE id=2;")
            guarded = rows()
            self.assertNotEqual(psql(sql, check=False).returncode, 0)
            self.assertEqual(rows(), guarded)
            # Name conflicts must not delete the other datasource or partially
            # commit an earlier rename in the same transaction.
            psql("UPDATE data_source SET url='http://loki.monitoring.svc.cluster.local:3100',name='Loki' WHERE id=2; UPDATE data_source SET name='Loki SITE''ONE' WHERE id=3; UPDATE data_source SET name='Prometheus' WHERE id=1;")
            conflicting = rows()
            self.assertNotEqual(psql(sql, check=False).returncode, 0)
            self.assertEqual(rows(), conflicting)
        finally:
            subprocess.run(["docker", "rm", "--force", name], capture_output=True)



class DashboardSyncTest(unittest.TestCase):
    def test_actual_sync_command_accepts_compact_and_pretty_dashboards(self):
        # Exercise the deployed shell function against an HTTP API, including
        # the compact JSON generated when datasource defaults are rewritten.
        source = (ROOT / "monitoring/grafana.yaml").read_text()
        function = source[source.index("              sync_dashboard() {"):source.index("              sync_dir() {")]
        function = textwrap.dedent(function).replace("$${", "${").replace("%%{", "%{")
        received = []
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                received.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                self.send_response(201)
                self.end_headers()
                self.wfile.write(b'{}')
            def log_message(self, *args):
                pass
        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                for indent in [None, 2]:
                    path = Path(directory) / "dashboard.json"
                    dashboard = {"uid": "stable-dashboard", "title": "Example", "panels": []}
                    path.write_text(json.dumps(dashboard, indent=indent))
                    result = subprocess.run(["sh", "-ec", function + '\nsync_dashboard "$1" infrastructure', "sync", str(path)],
                                            env={**os.environ, "api_url": f"http://127.0.0.1:{server.server_port}",
                                                 "GRAFANA_ADMIN_USER": "test", "GRAFANA_ADMIN_PASSWORD": "fixture"},
                                            cwd=directory, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(received[-1]["dashboard"], dashboard)
                    self.assertEqual(received[-1]["folderUid"], "infrastructure")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
            Path("/tmp/dashboard-dashboard.json").unlink(missing_ok=True)
            Path("/tmp/dashboard-response.json").unlink(missing_ok=True)


@unittest.skipUnless(os.environ.get("MONITORING_PROXY_DOCKER_TEST") == "1", "Enable local Docker integration explicitly")
class QueryProxyTest(unittest.TestCase):
    def test_queries_forward_and_ingestion_admin_methods_are_denied(self):
        source = (ROOT / "monitoring/query-api.conf").read_text()
        image = re.search(r'"(docker.io/nginx:stable-alpine@sha256:[a-f0-9]+)"',
                          (ROOT / "monitoring/intercluster.tf").read_text()).group(1)
        # Replace only the DNS/upstream transport. Run the actual route policy
        # with a local echo backend, without any cluster or network access.
        config = source.replace("kube-dns.kube-system.svc.cluster.local", "127.0.0.1")
        config = re.sub(r"http://(?:prometheus|loki|tempo|grafana)\.monitoring\.svc\.cluster\.local:\d+", "http://127.0.0.1:18080", config)
        config = config.replace("http {", 'http {\n server { listen 18081; add_header WWW-Authenticate ' + "'Basic realm=remote'" + ' always; location / { return 401 "$http_authorization $http_cookie $http_host $http_x_forwarded_proto"; } }', 1)
        config = config.replace("set $grafana http://127.0.0.1:18080;", "set $grafana http://127.0.0.1:18081;")
        config = config.replace("http {", 'http {\n server { listen 18080; location / { return 200 "$request_method $request_uri"; } }', 1)
        name = "monitoring-query-test-" + os.urandom(5).hex()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            path.chmod(0o755)
            (path / "nginx.conf").write_text(config)
            try:
                result = subprocess.run(["docker", "run", "--detach", "--name", name, "--network", "none",
                                         "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges",
                                         "--user", "101:101", "--tmpfs", "/tmp:rw,mode=1777",
                                         "--mount", f"type=bind,source={path / 'nginx.conf'},target=/etc/nginx/nginx.conf,readonly",
                                         "--entrypoint", "nginx", image, "-g", "daemon off;"], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                check = subprocess.run(["docker", "exec", name, "nginx", "-t"], capture_output=True, text=True)
                if check.returncode:
                    logs = subprocess.run(["docker", "logs", name], capture_output=True, text=True)
                    self.fail(check.stderr + logs.stdout + logs.stderr)
                cases = [
                    (9090, "/api/v1/query?query=up", "GET", 200),
                    (9090, "/api/v1/query", "POST", 200),
                    (9090, "/api/v1/write", "POST", 403),
                    (9090, "/api/v1/admin/tsdb/delete_series", "POST", 403),
                    (9090, "/-/reload", "POST", 403),
                    (9090, "/api/v1/query", "DELETE", 403),
                    (3100, "/loki/api/v1/query_range?query=test", "GET", 200),
                    (3100, "/loki/api/v1/label/app/values", "GET", 200),
                    (3100, "/loki/api/v1/status/buildinfo", "GET", 200),
                    (3100, "/loki/api/v1/tail?query=test", "GET", 200),
                    (3100, "/loki/api/v1/push", "POST", 403),
                    (3100, "/loki/api/v1/delete", "POST", 403),
                    (3200, "/api/search?limit=1", "GET", 200),
                    (3200, "/api/v2/traces/0123456789abcdef", "GET", 200),
                    (3200, "/api/metrics/query_range", "GET", 200),
                    (3200, "/api/status/buildinfo", "GET", 200),
                    (3200, "/api/status/config", "GET", 403),
                    (3200, "/v1/traces", "POST", 403),
                ]
                for route in ["/api/datasources/proxy/uid/remote/api/v1/query",
                              "/api/datasources/uid/remote/resources/api/v1/label/job/values",
                              "/api/ds/query"]:
                    request = (f"POST {route} HTTP/1.0\r\nHost: dashboard.example.com\r\n"
                               "Authorization: Bearer test-session\r\nCookie: grafana_session=test-cookie\r\n"
                               "X-Forwarded-Proto: https\r\nContent-Length: 0\r\n\r\n")
                    response = subprocess.run(["docker", "exec", "-i", name, "nc", "-w", "2", "127.0.0.1", "3000"],
                                              input=request, capture_output=True, text=True).stdout
                    self.assertIn("HTTP/1.1 401", response)
                    self.assertNotIn("www-authenticate:", response.lower())
                    self.assertIn("Bearer test-session grafana_session=test-cookie dashboard.example.com https", response)
                for port, route, method, expected in cases:
                    with self.subTest(port=port, route=route, method=method):
                        command = ["docker", "exec", name, "wget", "-Y", "off", "-S", "-O", "-", "-T", "5"]
                        if method == "POST":
                            command += ["--post-data=query=up"]
                        if method == "DELETE":
                            # BusyBox wget cannot issue DELETE; its full HTTP
                            # request can be sent with the bundled netcat.
                            result = subprocess.run(["docker", "exec", "-i", name, "nc", "-w", "2", "127.0.0.1", str(port)],
                                                    input=f"DELETE {route} HTTP/1.0\r\nHost: localhost\r\n\r\n", capture_output=True, text=True)
                        else:
                            result = subprocess.run(command + [f"http://127.0.0.1:{port}{route}"], capture_output=True, text=True)
                        response = result.stdout + result.stderr
                        self.assertRegex(response, rf"HTTP/1\.[01] {expected}")
                        if expected == 200:
                            self.assertIn(f"{method} {route}", result.stdout)
            finally:
                subprocess.run(["docker", "rm", "--force", name], capture_output=True)


if __name__ == "__main__":
    unittest.main()
