import os, json, ssl, threading, subprocess, pathlib, time, urllib.parse, shutil
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path.cwd()
EVID = pathlib.Path('/home/art/.no-mistakes/evidence/01M3XZEBZYK15EMYAQS3FAYYSQ')
TOOLS = ROOT / '.test-scratch/live-tools'
SHA = 'a' * 40
mode = 'ok'
calls = []
results = []
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(TOOLS / 'server.crt', TOOLS / 'server.key')

def signal(i, association='OWNER', typ='comment'):
    return dict(id=i, user={'login':'maintainer' if association != 'NONE' else 'stranger'},
                author_association=association, body='Please prove the contract',
                html_url=f'https://github.com/lab/contributions/pull/8#{typ}-{i}',
                updated_at='2026-10-02T08:00:00Z', submitted_at='2026-10-02T08:00:00Z',
                commit_id=SHA, state='CHANGES_REQUESTED')

class API(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_POST(self):
        query = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        calls.append({'method':'POST', 'path':self.path})
        self.emit({'data':{'repository':{'pullRequest':{'headRefOid':SHA,'reviewDecision':'CHANGES_REQUESTED'}}}})
    def emit(self, body, code=200, next_page=False):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(raw)))
        if next_page:
            self.send_header('Link',f'<https://api.github.com{self.path}&page=2>; rel="next"')
        self.end_headers()
        self.wfile.write(raw)
    def do_GET(self):
        calls.append({'method':'GET', 'path':self.path, 'mode':mode})
        parsed=urllib.parse.urlsplit(self.path)
        path=parsed.path
        page=urllib.parse.parse_qs(parsed.query).get('page',['1'])[0]
        later=page=='2'
        if '/comments' in path and mode=='timeout':
            time.sleep(7)
        if '/comments' in path and mode=='failure':
            self.emit({'message':'Disposable API outage'},503); return
        if '/comments' in path and mode=='malformed':
            self.send_response(200); self.send_header('Content-Length','8'); self.end_headers(); self.wfile.write(b'not-json'); return
        if path.endswith('/pulls/8'):
            self.emit({'state':'open','user':{'login':'author'},'head':{'sha':SHA},'draft':False,'mergeable':True,'merged_at':None}); return
        if path.endswith('/issues/9'):
            self.emit({'state':'open','user':{'login':'author'},'labels':[{'name':'READY-FOR-PR'}], 'html_url':'https://github.com/lab/contributions/issues/9'}); return
        if path.endswith('/reviews'):
            self.emit([signal(21,typ='review')] if later else [signal(20,'NONE',typ='review')], next_page=not later); return
        if path.endswith('/comments'):
            self.emit([signal(31 if '/pulls/' in path else 12)] if later else [signal(11,'NONE')], next_page=not later); return
        if path.endswith('/events'):
            self.emit([{'id':41,'event':'labeled','label':{'name':'READY-FOR-PR'}}] if later else [{'id':40,'event':'renamed'}],next_page=not later); return
        if path.endswith('/check-runs'):
            self.emit({'check_runs':[{'name':'test-later' if later else 'test-first','id':2 if later else 1,'status':'completed','conclusion':'success','started_at':'2026-10-02T08:00:00Z'}]},next_page=not later); return
        if path.endswith('/statuses'):
            self.emit([{'context':'legacy-status' if later else 'legacy-first','id':3 if later else 4,'created_at':'2026-10-02T08:00:00Z','state':'success'}],next_page=not later); return
        if path.endswith('/contributions'):
            self.emit({'permissions':{'push':False}}); return
        self.emit({'message':'Not Found'},404)

class Proxy(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_CONNECT(self):
        assert self.path in ('api.github.com:443','github.com:443'), self.path
        self.send_response(200); self.end_headers()
        wrapped=tls.wrap_socket(self.connection,server_side=True)
        try: API(wrapped,self.client_address,self.server)
        except (BrokenPipeError,ConnectionResetError): pass
        finally: wrapped.close()

server=ThreadingHTTPServer(('127.0.0.1',0),Proxy)
threading.Thread(target=server.serve_forever,daemon=True).start()
baseenv=os.environ.copy()
for key in list(baseenv):
    if key.startswith(('FM_', 'GH_', 'GITHUB_')) or key in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','NO_PROXY','no_proxy'):
        baseenv.pop(key,None)
baseenv.update(HTTPS_PROXY=f'http://127.0.0.1:{server.server_port}',https_proxy=f'http://127.0.0.1:{server.server_port}',
               SSL_CERT_FILE=str(TOOLS/'server.crt'),GH_TOKEN='disposable-lab-token',GH_CONFIG_DIR=str(TOOLS/'gh-config'),
               TMPDIR=str(ROOT/'.test-scratch/tmp'))

def home(name, kind='pull', number=8, binary='old'):
    h=ROOT/'.test-scratch'/name
    if h.exists(): shutil.rmtree(h)
    for d in ('data','state','config','projects','root'): (h/d).mkdir(parents=True,exist_ok=True)
    url=f'https://github.com/lab/contributions/{kind}/{number}'
    (h/'data/backlog.md').write_text(f'# Backlog\n\n## Queued\n- [ ] delivery - Disposable contribution {url} (repo: sample) (kind: ship)\n')
    env=baseenv.copy()
    env.update(FM_HOME=str(h),FM_ROOT_OVERRIDE=str(h/'root'),FM_STATE_OVERRIDE=str(h/'state'),FM_DATA_OVERRIDE=str(h/'data'),FM_CONFIG_OVERRIDE=str(h/'config'),FM_PROJECTS_OVERRIDE=str(h/'projects'))
    if binary=='old': env['PATH']=str(TOOLS/'gh_2.45.0_linux_amd64/bin')+':'+env['PATH']
    return h,env,url

def run(env,*args):
    start=time.monotonic()
    p=subprocess.run([str(ROOT/'bin/fm-contributions.sh'),*args],env=env,capture_output=True,text=True,timeout=40)
    results.append({'command':['bin/fm-contributions.sh',*args],'stdout':p.stdout,'stderr':p.stderr,'exit':p.returncode,'elapsed':round(time.monotonic()-start,2)})
    assert p.returncode==0, results[-1]
    return p.stdout

def record(h): return json.loads((h/'data/delivery/contributions.json').read_text())['records'][0]
def save(label,h): (EVID/(label+'.json')).write_text(json.dumps(record(h),indent=2)+'\n')
def check(name, condition):
    assert condition,name
    results.append({'scenario':name,'result':'pass'})

try:
    for binary in ('old','current'):
        h,env,url=home('api-pr-'+binary,binary=binary)
        if binary=='old':
            for args in (['pr','view',url,'--json','headRefOid,reviewDecision'], ['api',f'repos/lab/contributions/commits/{SHA}/check-runs?filter=all&per_page=100','--paginate'], ['api','repos/lab/contributions/issues/8/comments?per_page=100','--paginate']):
                p=subprocess.run(['gh',*args],env=env,capture_output=True,text=True,timeout=15)
                results.append({'probe':args,'stdout':p.stdout,'stderr':p.stderr,'exit':p.returncode})
                if args[0]=='api':
                    parsed=subprocess.run(['jq','-s','.'],input=p.stdout,env=env,capture_output=True,text=True)
                    results.append({'jq_probe':True,'stdout':parsed.stdout,'stderr':parsed.stderr,'exit':parsed.returncode})
        first=run(env,'poll'); r=record(h)
        if r['error'] is not None:
            debug=subprocess.run(['bash','-x',str(ROOT/'bin/fm-contributions.sh'),'poll'],env=env,capture_output=True,text=True,timeout=40)
            (EVID/'debug-poll.txt').write_text(debug.stderr)
        check(binary+' gh collects all PR pages',r['error'] is None and len(r['observation']['checks'])==4 and len(r['pending'])==3 and all(e['author']=='maintainer' for e in r['pending']))
        save('api-pr-'+binary,h)
        original=(h/'state/.wake-queue').read_text()
        check(binary+' gh replay does not duplicate wakes',run(env,'poll')=='' and (h/'state/.wake-queue').read_text()==original)
        for event in r['pending']: run(env,'ack','delivery',url,event['token'])
        run(env,'poll')
        check(binary+' gh acknowledged events do not replay',json.loads(run(env,'pending'))==[])
    h,env,url=home('api-issue','issues',9)
    run(env,'poll'); r=record(h)
    check('old gh collects later-page issue comment and ready label',r['error'] is None and {e['type'] for e in r['pending']}=={'comment','ready-for-pr'})
    save('api-issue',h)
    check('issue replay does not wake again',run(env,'poll')=='')
    h,env,url=home('api-faults')
    run(env,'poll')
    prior=(h/'data/delivery/contributions.json').read_bytes()
    prior_wake=(h/'state/.wake-queue').read_bytes()
    mode='timeout'; run(env,'poll')
    check('slow API read preserves prior record and wake queue',(h/'data/delivery/contributions.json').read_bytes()==prior and (h/'state/.wake-queue').read_bytes()==prior_wake)
    mode='failure'; first=run(env,'poll'); second=run(env,'poll')
    check('genuine outage records error once per episode','observation unavailable' in first and second=='' and record(h)['error'] is not None)
    save('api-unavailable',h)
    mode='ok'; run(env,'poll')
    check('successful read clears failure episode',record(h)['error'] is None)
    mode='malformed'; first=run(env,'poll')
    check('malformed JSON is an assembly failure not success','observation unavailable' in first and record(h)['error'] is not None)
    save('api-malformed',h)
finally:
    (EVID/'live-api-transcript.json').write_text(json.dumps({'steps':results,'requests':calls},indent=2)+'\n')
    server.shutdown();server.server_close()
