import copy
import importlib.util
import json
from pathlib import Path
import unittest

PATH=Path(__file__).resolve().parents[1]/'bootstrap-grafana-operator-crds.py'
spec=importlib.util.spec_from_file_location('operator_crds',PATH);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

def definition():
    return {'apiVersion':'apiextensions.k8s.io/v1','kind':'CustomResourceDefinition','metadata':{'name':'grafanas.grafana.integreatly.org'},'spec':{'names':{'kind':'Grafana'},'versions':[{'name':'v1beta1','served':True}]}}

class CrdBootstrapTest(unittest.TestCase):
    def test_old_and_new_kubectl_json_encodings_are_supported(self):
        a=definition();b={'kind':'ServiceAccount','metadata':{'name':'operator'}}
        for text in (json.dumps({'kind':'List','items':[a,b]}),json.dumps(a)+'\n'+json.dumps(b)):
            self.assertEqual(module.objects_from_stream(text),[a,b])

    def test_empty_api_creates_crd_with_helm_owner_before_waiting(self):
        calls=[]
        def run(args,payload=None):
            calls.append((args,payload))
            return ''
        self.assertEqual(module.bootstrap([definition()],[],execute=run),1)
        self.assertEqual([args[0] for args,_ in calls],['get','create','wait'])
        obj=json.loads(calls[1][1]);self.assertEqual(obj['metadata']['annotations']['meta.helm.sh/release-name'],'grafana-operator')
        self.assertEqual(obj['metadata']['labels']['app.kubernetes.io/managed-by'],'Helm')

    def test_existing_owned_crd_is_not_changed(self):
        obj=definition();obj['metadata']['annotations']={'meta.helm.sh/release-name':'grafana-operator','meta.helm.sh/release-namespace':'monitoring'}
        calls=[]
        def run(args,payload=None):
            calls.append(args)
            return json.dumps(obj) if args[0]=='get' else ''
        original=copy.deepcopy(obj)
        self.assertEqual(module.bootstrap([definition()],[],execute=run),0)
        self.assertEqual(obj,original);self.assertEqual([x[0] for x in calls],['get','wait'])

    def test_unowned_or_foreign_crd_aborts_before_any_create(self):
        for owner in ({},{'meta.helm.sh/release-name':'other','meta.helm.sh/release-namespace':'monitoring'}):
            obj=definition();obj['metadata']['annotations']=owner;calls=[]
            def run(args,payload=None):calls.append(args);return json.dumps(obj)
            with self.assertRaisesRegex(ValueError,'ownership'):module.bootstrap([definition()],[],execute=run)
            self.assertEqual([x[0] for x in calls],['get'])

    def test_dry_inspection_never_creates(self):
        calls=[]
        def run(args,payload=None):calls.append(args);return ''
        self.assertEqual(module.bootstrap([definition()],[],execute=run,apply=False),1)
        self.assertEqual([x[0] for x in calls],['get'])

    def test_existing_unserved_api_version_aborts(self):
        obj=definition();obj['spec']['versions'][0]['served']=False
        obj['metadata']['annotations']={'meta.helm.sh/release-name':'grafana-operator','meta.helm.sh/release-namespace':'monitoring'}
        with self.assertRaisesRegex(ValueError,'v1beta1'):module.bootstrap([definition()],[],execute=lambda *_:json.dumps(obj))

if __name__=='__main__':unittest.main()
