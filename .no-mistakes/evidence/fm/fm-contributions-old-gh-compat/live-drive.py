import http.server, threading, json, os, pathlib, subprocess, shutil, time, urllib.parse, signal
ROOT=pathlib.Path.cwd(); E=pathlib.Path('/home/art/.no-mistakes/evidence/01M3XQ033JEYWZVQ6AHD4N27BN'); S=ROOT/'.test-scratch/live'
S.mkdir(parents=True,exist_ok=True)
HEAD='a'*40; OTHER='b'*40; mode='ok'; requests=[]
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a): pass
 def do_POST(self): self.do_GET()
 def do_GET(self):
  global mode
  path=urllib.parse.urlsplit(self.path); q=urllib.parse.parse_qs(path.query); page=int(q.get('page',['1'])[0]); p=path.path
  requests.append({'method':self.command,'path':self.path})
  if self.command=='POST': self.rfile.read(int(self.headers.get('Content-Length','0')))
  paginated=False
  event={'id':12,'user':{'login':'maintainer'},'author_association':'OWNER','body':'please clarify','html_url':'https://github.com/o/r/pull/8#issuecomment-12','updated_at':'2026-10-02T08:02:00Z'}
  outsider={**event,'id':11,'user':{'login':'outsider'},'author_association':'NONE'}
  selfevent={**event,'id':13,'user':{'login':'author'}}
  if p=='/graphql': data={'data':{'repository':{'pullRequest':{'headRefOid':OTHER if mode=='changed' else HEAD,'reviewDecision':'CHANGES_REQUESTED'}}}}
  elif p=='/repos/o/r/pulls/8': data={'state':'open','user':{'login':'author'},'head':{'sha':HEAD},'draft':False,'mergeable':True,'merged_at':None}
  elif p=='/repos/o/r/issues/9': data={'state':'open','user':{'login':'author'},'labels':[{'name':'ready-for-pr'}],'html_url':'https://github.com/o/r/issues/9'}
  elif '/issues/' in p and p.endswith('/comments'): paginated=True; data=[outsider] if page==1 else [event,selfevent]
  elif p.endswith('/reviews'): paginated=True; data=[{'id':20,'user':{'login':'outsider'},'author_association':'NONE','commit_id':HEAD,'state':'COMMENTED'}] if page==1 else [{'id':21,'user':{'login':'maintainer'},'author_association':'MEMBER','body':'regression please','html_url':'https://github.com/o/r/pull/8#pullrequestreview-21','submitted_at':'2026-10-02T08:03:00Z','commit_id':HEAD,'state':'CHANGES_REQUESTED'}]
  elif '/pulls/' in p and p.endswith('/comments'): paginated=True; data=[outsider] if page==1 else [{**event,'id':31,'html_url':'https://github.com/o/r/pull/8#discussion_r31'}]
  elif p.endswith('/check-runs'): paginated=True; data={'total_count':2,'check_runs':[{'name':f'page-{page}-lane','id':page,'status':'completed','conclusion':'success','started_at':'2026-10-02T08:01:00Z'}]}
  elif p.endswith('/statuses'): paginated=True; data=[{'context':'status-first','id':3,'state':'success','created_at':'2026-10-02T08:01:00Z'}] if page==1 else [{'context':'status-lane','id':4,'state':'success','created_at':'2026-10-02T08:01:00Z'}]
  elif p.endswith('/events'): paginated=True; data=[{'event':'labeled','id':87,'label':{'name':'triage'}}] if page==1 else [{'event':'labeled','id':88,'label':{'name':'ready-for-pr'}}]
  elif p=='/repos/o/r': data={'permissions':{'push':False}}
  else: self.send_error(404); return
  if mode=='http-error' and paginated and page==2: self.send_error(503); return
  raw=b'invalid json' if mode=='corrupt' and paginated and page==2 else json.dumps(data).encode()
  self.send_response(200); self.send_header('Content-Type','application/json')
  if paginated and page==1:
   nextq={**q,'page':['2']}; url=f'http://127.0.0.1:{self.server.server_port}{p}?'+urllib.parse.urlencode(nextq,doseq=True)
   self.send_header('Link',f'<{url}>; rel="next"')
  self.send_header('Content-Length',str(len(raw))); self.end_headers(); self.wfile.write(raw)
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
URL=f'http://127.0.0.1:{server.server_port}'
results=[]
def newhome(name,cli):
 home=S/name
 for d in ['data','state','config','projects','bin','tmp','ghconfig']: (home/d).mkdir(parents=True,exist_ok=True)
 (home/'data/backlog.md').write_text('# Backlog\n\n## Queued\n\n- [ ] delivery - Old gh contribution https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n')
 wrapper='''#!/usr/bin/env python3
import os,sys,json,subprocess
with open(os.environ['LIVE_GH_LOG'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
a=sys.argv[1:]; real=os.environ['LIVE_GH_BINARY']; base=os.environ['LIVE_API']
if a[0]=='api':
 a[1]=base+'/'+a[1]
 p=subprocess.run([real]+a,capture_output=True)
 with open(os.environ['LIVE_GH_LOG']+'.responses','a') as f: f.write(json.dumps({'argv':a,'rc':p.returncode,'out':p.stdout.decode(),'err':p.stderr.decode()})+'\\n')
 sys.stdout.buffer.write(p.stdout);sys.stderr.buffer.write(p.stderr);sys.exit(p.returncode)
if a[:2]==['pr','view']:
 os.execv(real,[real,'api',base+'/graphql','--method','POST','-f','query=query { repository(owner:"o",name:"r") { pullRequest(number:8) { headRefOid reviewDecision } } }','--jq','.data.repository.pullRequest'])
raise SystemExit('unsupported routing invocation: '+repr(a))
'''
 (home/'bin/gh').write_text(wrapper);(home/'bin/gh').chmod(0o755)
 env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','GH_','GITHUB_','TASKS_AXI_'))}
 env.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(ROOT),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'),FM_PROJECTS_OVERRIDE=str(home/'projects'),FM_CONTRIBUTIONS_NOW='2026-10-02T08:05:00Z',FM_CONTRIBUTIONS_BUDGET='25',GH_CONFIG_DIR=str(home/'ghconfig'),GH_TOKEN='disposable-fixture-token',GH_PROMPT_DISABLED='1',GH_NO_UPDATE_NOTIFIER='1',LIVE_GH_BINARY=str(cli),LIVE_API=URL,LIVE_GH_LOG=str(home/'gh-argv.jsonl'),TMPDIR=str(home/'tmp'),PATH=str(home/'bin')+':'+os.environ['PATH'])
 return home,env
transcript=[]
def run(home,env,*args,exe=None):
 cmd=[str(exe or ROOT/'bin/fm-contributions.sh'),*args]
 start=time.monotonic();p=subprocess.run(cmd,env=env,text=True,capture_output=True,timeout=45)
 transcript.append({'home':home.name,'command':cmd,'rc':p.returncode,'elapsed':round(time.monotonic()-start,3),'stdout':p.stdout,'stderr':p.stderr})
 assert p.returncode==0,transcript[-1]
 return p.stdout

def saved(home,task='delivery'): return json.loads((home/f'data/{task}/contributions.json').read_text())['records'][0]
def record_result(name,home,start):
 out=E/home.name;out.mkdir(exist_ok=True)
 for p in [home/'gh-argv.jsonl',home/'state/.wake-queue',*home.glob('data/*/contributions.json')]:
  if p.exists(): shutil.copyfile(p,out/(p.parent.name+'-'+p.name if p.name=='contributions.json' else p.name))
 (out/'requests.json').write_text(json.dumps(requests[start:],indent=2))
 results.append({'name':name,'result':'pass','live':True,'evidence':str(out),'reason':''})
 print('PASS '+name,flush=True)
try:
 old=ROOT/'.test-scratch/gh_2.45.0_linux_amd64/bin/gh';modern=pathlib.Path(shutil.which('gh'))
 for name,cli in [('old-gh-pr',old),('modern-gh-pr',modern)]:
  mode='ok';home,env=newhome(name,cli);start=len(requests)
  out=run(home,env,'poll');row=saved(home)
  assert row['error'] is None and row['observation']['head']==HEAD
  assert sorted(c['name'] for c in row['observation']['checks'])==['page-1-lane','page-2-lane','status-first','status-lane']
  assert len(row['pending'])==3 and all(e['author']=='maintainer' for e in row['pending'])
  assert out.count('contribution-wake:')==3
  assert run(home,env,'poll')==''
  for ev in json.loads(run(home,env,'pending')): run(home,env,'ack',ev['task'],ev['url'],ev['token'])
  assert run(home,env,'poll')=='' and json.loads(run(home,env,'pending'))==[]
  assert len((home/'state/.wake-queue').read_text().splitlines())==3
  record_result(f'{cli.name} {name}: all pages, maintainer filtering, exactly-once wakes and ack',home,start)
 mode='ok';home,env=newhome('old-gh-issue',old);start=len(requests)
 (home/'data/backlog.md').write_text('# Backlog\n\n## Queued\n\n- [ ] filed - Issue https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n')
 out=run(home,env,'poll');row=saved(home,'filed')
 assert row['error'] is None and sorted(e['type'] for e in row['pending'])==['comment','ready-for-pr']
 assert out.count('contribution-wake:')==2 and run(home,env,'poll')==''
 for ev in json.loads(run(home,env,'pending')): run(home,env,'ack',ev['task'],ev['url'],ev['token'])
 assert run(home,env,'poll')=='' and json.loads(run(home,env,'pending'))==[]
 record_result('Old gh issue: later-page comment and label survive filtering, deduplication and ack',home,start)
 for fault in ['corrupt','http-error','changed','slow-assembly']:
  mode='ok';home,env=newhome(fault,old);start=len(requests);run(home,env,'poll')
  for ev in json.loads(run(home,env,'pending')): run(home,env,'ack',ev['task'],ev['url'],ev['token'])
  prior=(home/'data/delivery/contributions.json').read_bytes();queue=(home/'state/.wake-queue').read_bytes();before=saved(home)['observation'];mode=fault
  if fault=='slow-assembly':
   jq=shutil.which('jq');env.update(LIVE_REAL_JQ=jq,LIVE_SLEEP_PIDS=str(home/'assembly-pids'))
   (home/'bin/jq').write_text('''#!/usr/bin/env bash
if [ "${1:-}" = -s ] && [ "${2:-}" = . ] && [[ "${3:-}" == */pages.* ]]; then
 sleep 12 &
 printf '%s\\n' "$!" >> "$LIVE_SLEEP_PIDS"
 wait
fi
exec "$LIVE_REAL_JQ" "$@"
''');(home/'bin/jq').chmod(0o755)
  t=time.monotonic();out=run(home,env,'poll');elapsed=time.monotonic()-t
  assert (home/'state/.wake-queue').read_bytes()==queue
  if fault=='slow-assembly':
   assert out=='' and (home/'data/delivery/contributions.json').read_bytes()==prior and elapsed<10
   pids=(home/'assembly-pids').read_text().splitlines();assert pids
   for pid in pids:
    try: os.kill(int(pid),0)
    except ProcessLookupError: continue
    raise AssertionError('assembly child remains: '+pid)
  else:
   assert 'observation unavailable' in out and saved(home)['error'] and saved(home)['observation']==before
   assert run(home,env,'poll')==''
   mode='ok';run(home,env,'poll');assert saved(home)['error'] is None
  record_result('Adversarial '+fault+': preserve coherent prior state, bound work, prevent false/repeated wakes',home,start)
 mode='ok';home,env=newhome('registered-check',old);start=len(requests)
 assert 'registered:' in run(home,env,'arm')
 assert (home/'state/contributions.check-trust').exists()
 out=run(home,env,exe=home/'state/contributions.check.sh');assert out.count('contribution-wake:')==3
 assert run(home,env,exe=home/'state/contributions.check.sh')==''
 record_result('Authenticated generated contribution check surfaces later-page signals once',home,start)
 # Reproduce the old executable's actual failure with the genuine old CLI.
 mode='ok';home,env=newhome('before-fix',old);start=len(requests)
 baseline=ROOT/'.test-scratch/baseline-bin';baseline.mkdir(exist_ok=True)
 for p in (ROOT/'bin').iterdir():
  if p.is_file(): (baseline/p.name).symlink_to(p)
 (baseline/'fm-contributions.sh').unlink()
 previous=subprocess.check_output(['git','show','241d4617:bin/fm-contributions.sh'])
 (baseline/'fm-contributions.sh').write_bytes(previous);(baseline/'fm-contributions.sh').chmod(0o755)
 out=run(home,env,'poll',exe=baseline/'fm-contributions.sh')
 assert 'observation unavailable' in out and saved(home)['error'] and not saved(home)['observation']
 assert '--slurp' in (home/'gh-argv.jsonl').read_text()
 record_result('Regression: base executable fails on genuine gh 2.45.0 while changed executable succeeds',home,start)
 # Every simulated GitHub request was read-only; POST is GraphQL with a query.
 assert all(r['method']=='GET' or r['path']=='/graphql' for r in requests)
 results.append({'name':'Contribution observation performs no forge mutations','result':'pass','live':True,'evidence':'live-http-requests.json','reason':''})
finally:
 server.shutdown();server.server_close();thread.join(timeout=5)
 (E/'live-transcript.json').write_text(json.dumps(transcript,indent=2));(E/'live-http-requests.json').write_text(json.dumps(requests,indent=2));(E/'live-results.json').write_text(json.dumps(results,indent=2))
 # preserve failed fixture until diagnosis
 if len(results)>=10: shutil.rmtree(S)
