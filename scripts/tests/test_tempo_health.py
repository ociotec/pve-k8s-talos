import importlib.util
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
import threading
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

def load(name,file):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).resolve().parents[1]/file)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
HEALTH=load('tempo_health','check-tempo-health.py');DATA=load('tempo_data','validate-tempo-data.py')

class TempoHealthTest(unittest.TestCase):
    def run_pod_check(self, pods, logs):
        def kubectl(args, **kwargs):
            command=args[args.index('--request-timeout=20s')+1:]
            output=json.dumps({'items':pods}) if command[0]=='get' else logs[command[1]]
            return HEALTH.subprocess.CompletedProcess(args,0,stdout=output)
        with patch.object(HEALTH.sys,'argv',['check-tempo-health.py','--kubeconfig','unused','--timeout','0']), \
             patch.object(HEALTH.subprocess,'run',side_effect=kubectl), \
             patch.object(HEALTH.time,'monotonic',return_value=0):
            return HEALTH.main()

    def test_terminal_pods_do_not_block_a_healthy_replacement(self):
        for phase in ('Failed','Succeeded'):
            with self.subTest(phase=phase):
                pods=[{'metadata':{'name':'old'},'status':{'phase':phase}},
                      {'metadata':{'name':'current'},'status':{'phase':'Running'}}]
                self.assertEqual(self.run_pod_check(pods,{'old':'','current':'blocklist poll complete'}),0)

    def test_terminal_pods_alone_do_not_pass_the_check(self):
        pods=[{'metadata':{'name':phase.lower()},'status':{'phase':phase}}
              for phase in ('Failed','Succeeded')]
        with self.assertRaisesRegex(ValueError,'No successful Tempo blocklist poll'):
            self.run_pod_check(pods,{p['metadata']['name']:'blocklist poll complete' for p in pods})

    def test_running_pod_block_errors_still_fail_the_check(self):
        pods=[{'metadata':{'name':'current'},'status':{'phase':'Running'}}]
        with self.assertRaisesRegex(ValueError,'Preserve its volume'):
            self.run_pod_check(pods,{'current':'failed reading unknown blocks\nblocklist poll complete'})

    def test_running_pod_without_a_successful_poll_still_times_out(self):
        pods=[{'metadata':{'name':'current'},'status':{'phase':'Running'}}]
        with self.assertRaisesRegex(ValueError,'No successful Tempo blocklist poll'):
            self.run_pod_check(pods,{'current':'server ready'})

    def test_synthetic_probe_queries_the_trace_id_it_sent(self):
        requests=[]
        def execute(args,payload=None):
            requests.append((args,payload))
            if args[0]=='post-json':return '{}'
            return '{"trace":{"resourceSpans":[{"scopeSpans":[{"spans":[{"name":"platform-deployment-probe"}]}]}]}}'
        HEALTH.verify_trace('monitoring',execute,timeout=0)
        trace_id=json.loads(requests[0][1])['resourceSpans'][0]['scopeSpans'][0]['spans'][0]['traceId']
        self.assertTrue(urlsplit(requests[1][0][-1]).path.endswith('/api/traces/'+trace_id))

    def test_probe_finds_its_span_when_unbounded_history_lookups_time_out(self):
        emitted={}
        def execute(args,payload=None):
            if args[0]=='post-json':
                emitted.update(json.loads(payload)['resourceSpans'][0]['scopeSpans'][0]['spans'][0])
                return '{}'
            lookup=urlsplit(args[-1]);bounds=parse_qs(lookup.query)
            if not {'start','end'}.issubset(bounds):
                raise RuntimeError('Historical lookup exceeded the Kubernetes API timeout')
            start,end=int(bounds['start'][0]),int(bounds['end'][0])
            if not start<=int(emitted['startTimeUnixNano'])/1e9<=end or end-start>300:
                raise RuntimeError('Lookup did not select the emitted span time range')
            if not lookup.path.endswith('/api/traces/'+emitted['traceId']):
                raise RuntimeError('Lookup selected a different trace')
            return json.dumps({'trace':{'resourceSpans':[{'scopeSpans':[{'spans':[emitted]}]}]}})
        HEALTH.verify_trace('monitoring',execute,timeout=0)

    def test_otlp_transport_sends_json_content_type_and_body(self):
        received=[]
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                received.append((self.headers.get('Content-Type'),json.loads(self.rfile.read(int(self.headers['Content-Length'])))))
                self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(b'{}')
            def log_message(self,*args):pass
        with HTTPServer(('127.0.0.1',0),Handler) as server:
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            try:
                result=HEALTH.post_json('http://127.0.0.1:'+str(server.server_port)+'/v1/traces','{"resourceSpans":[]}')
                self.assertEqual(result,'{}');self.assertEqual(received,[('application/json',{'resourceSpans':[]})])
            finally:server.shutdown();thread.join()

    def test_rejected_synthetic_span_is_a_failure(self):
        with self.assertRaisesRegex(ValueError,'rejected'):
            HEALTH.verify_trace('monitoring',lambda *_:'{"partialSuccess":{"rejectedSpans":"1"}}')

    def test_poll_complete_does_not_hide_tenant_failure(self):
        logs='level=error msg="failed to poll or create index for tenant" err="failed reading unknown blocks: unexpected end of JSON input"\nlevel=info msg="blocklist poll complete"'
        with self.assertRaisesRegex(ValueError,'Preserve'):HEALTH.healthy_poll(logs)

    def test_old_and_new_poll_log_formats_are_accepted(self):
        for logs in ('level=info msg="blocklist poll complete"','{"level":"info","msg":"blocklist polling complete"}'):
            self.assertTrue(HEALTH.healthy_poll(logs))

    def test_normal_tempo3_scheduler_noise_is_not_failure(self):
        self.assertTrue(HEALTH.healthy_poll('no jobs found\nblocklist poll complete'))

    def test_readiness_alone_is_not_a_successful_poll(self):self.assertFalse(HEALTH.healthy_poll('server ready'))

    def test_validation_reports_empty_metadata_without_modifying_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'good.json').write_text('{"version":"vParquet4"}');bad=root/'meta.json';bad.touch()
            result=DATA.validate(root)
            self.assertEqual(result['checked_json_files'],2);self.assertEqual(result['invalid'],[{'path':'meta.json','error':'JSONDecodeError','bytes':0}])
            self.assertTrue(bad.exists());self.assertEqual(bad.read_bytes(),b'')

if __name__=='__main__':unittest.main()
