#!/usr/bin/env python3
"""Disposable SSH transport fixture; no network calls."""
import json,os,shlex,sys
from pathlib import Path
path=Path(os.environ['CEPH_TEST_STATE']);state=json.loads(path.read_text())
host=sys.argv[-2].rsplit('@',1)[-1];a=shlex.split(sys.argv[-1]);result=None
if a[:4]==['ceph','config','get','mon']:result='true' if state['mon'] else 'false'
elif a[:3]==['ceph','config','dump']:result=[{'name':'mon_allow_pool_delete','section':'mon'}] if state['explicit'] else []
elif a[:4]==['ceph','config','set','mon']:state.update(mon=a[-1]=='true',explicit=True)
elif a[:4]==['ceph','config','rm','mon']:state.update(mon=False,explicit=False)
elif a[:4]==['ceph','osd','pool','ls']:result=state['pools'] if 'detail' in a else [p['pool_name'] for p in state['pools']]
elif a[:4]==['ceph','osd','pool','rm']:
    if os.environ.get('CEPH_TEST_FAIL_DELETE')==a[4]:print('fixture pool deletion failure',file=sys.stderr);sys.exit(1)
    state['pools']=[p for p in state['pools'] if p['pool_name']!=a[4]]
elif a[:5]==['ceph','osd','crush','rule','dump']:result=state['rules']
elif a[:5]==['ceph','osd','crush','rule','rm']:state['rules']=[r for r in state['rules'] if r['rule_name']!=a[5]]
elif a[:4]==['ceph','osd','erasure-code-profile','ls']:result=state['profiles']
elif a[:4]==['ceph','osd','erasure-code-profile','rm']:state['profiles'].remove(a[4])
elif a[:4]==['ceph','fs','volume','ls']:result=[{'name':f['mdsmap']['fs_name']} for f in state['filesystems']]
elif a[:4]==['ceph','fs','volume','rm']:state['filesystems']=[f for f in state['filesystems'] if f['mdsmap']['fs_name']!=a[4]]
elif a[:3]==['ceph','fs','dump']:result={'filesystems':state['filesystems'],'standbys':[]}
elif a[:3]==['ceph','auth','ls']:result={'auth_dump':[{'entity':n,'key':'FIXTURE-SECRET-DO-NOT-PRINT'} for n in state['auth']]}
elif a[:3]==['ceph','auth','del']:state['auth'].remove(a[3])
elif a[:3]==['pvesh','get','/cluster/status']:result=[{'type':'node','name':'pve1','ip':'192.0.2.10','online':1},{'type':'node','name':'pve2','ip':'192.0.2.11','online':1}]
elif a[:3]==['sh','-ec',a[-1]]:result=''.join(n+'\n' for n in state['directories'].get(host,[]))
elif a[:3]==['pveceph','mds','destroy']:
    state['directories'][host].remove('ceph-'+a[3]);state['destroyed_mds_hosts'].append(host)
elif a[:2]==['rbd','ls']:result=state.get('images',{}).get(a[2],[])
elif a[:3]==['rbd','snap','ls']:result=state.get('snapshots',{}).get(a[3],[])
elif a[:3]==['rbd','trash','ls']:result=[]
elif a[:3]==['rbd','trash','purge']:pass
else:print('unexpected fixture command: '+str(a),file=sys.stderr);sys.exit(2)
path.write_text(json.dumps(state))
if isinstance(result,(list,dict)):print(json.dumps(result))
elif result is not None:print(result)
