import signal
import os, ssl, socketserver, http.server, threading, json, pathlib, subprocess, time, urllib.parse, shutil
ROOT=pathlib.Path.cwd(); SCRATCH=ROOT/'.no-mistakes/test-phase'; EVIDENCE=pathlib.Path('/Users/kesslerio/.no-mistakes/evidence/01M3RK3ZC6HPM3EB47S4VX8T41')
HEAD='a'*40; NOW='2026-09-30T08:00:00Z'; mode='normal'; requests=[]
cert=SCRATCH/'cert.pem'; key=SCRATCH/'key.pem'
subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(cert),'-days','1','-subj','/CN=api.github.com','-addext','subjectAltName=DNS:api.github.com,DNS:github.com'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert,key)
def comment(id, association, user, url): return dict(id=id,user=dict(login=user),author_association=association,body=f'Comment {id}: please clarify',html_url=url,updated_at=NOW)
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args): pass
    def do_CONNECT(self):
        self.send_response(200); self.end_headers()
        self.connection=context.wrap_socket(self.connection,server_side=True)
        self.rfile=self.connection.makefile('rb'); self.wfile=self.connection.makefile('wb')
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))))
        requests.append(dict(method='POST',path=self.path,query=body.get('query')))
        data={'data':{'repository':{'pullRequest':{'id':'PR_local','headRefOid':HEAD,'reviewDecision':'APPROVED'},'id':'R_local'}}}
        self.output(data)
    def output(self,data,link=None,status=200):
        body=json.dumps(data).encode(); self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(body)))
        if link: self.send_header('Link',f'<https://api.github.com{link}>; rel="next"')
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        parsed=urllib.parse.urlparse(self.path); path=parsed.path; params=urllib.parse.parse_qs(parsed.query); page=int(params.get('page',['1'])[0]); requests.append(dict(method='GET',path=self.path,mode=mode))
        if mode=='unavailable' and path.endswith('/issues/9'): return self.output({'message':'isolated service unavailable'},status=503)
        if mode=='slow' and path.endswith('/comments'): time.sleep(8)
        if path.endswith('/pulls/8'): data=dict(state='open',user=dict(login='author'),head=dict(sha=HEAD),draft=False,mergeable=True,merged_at=None)
        elif path.endswith('/issues/9'): data=dict(state='open',user=dict(login='author'),labels=[dict(name='ready-for-pr')],html_url='https://github.com/o/r/issues/9')
        elif path.endswith('/comments'):
            if page==1: data=[comment(11,'NONE','outsider','https://github.com/o/r/pull/8#issuecomment-11'),comment(12,'OWNER','author','https://github.com/o/r/pull/8#issuecomment-12')]
            else: data=[comment(13,'OWNER','maintainer',f'https://github.com/o/r/issues/{9 if "/issues/9/" in path else 8}#issuecomment-13')]
        elif path.endswith('/reviews'): data=[dict(id=20,user=dict(login='outsider'),author_association='NONE',body='Not a maintainer review',html_url='https://github.com/o/r/pull/8#pullrequestreview-20',submitted_at=NOW,commit_id=HEAD,state='COMMENTED')] if page==1 else [dict(id=21,user=dict(login='maintainer'),author_association='MEMBER',body='Needs regression proof',html_url='https://github.com/o/r/pull/8#pullrequestreview-21',submitted_at=NOW,commit_id=HEAD,state='CHANGES_REQUESTED')]
        elif path.endswith('/events'): data=[dict(id=30,event='unlabeled',label=dict(name='triage'))] if page==1 else [dict(id=31,event='labeled',label=dict(name='ready-for-pr'))]
        elif path.endswith('/check-runs'): data={'total_count':2,'check_runs':[dict(name='test',id=page,status='completed',conclusion='success' if page==1 else 'failure',started_at=NOW)]}
        elif path.endswith('/statuses'): data=[dict(context='status-on-page-one',id=50,created_at=NOW,state='success')] if page==1 else [dict(context='status-on-page-two',id=51,created_at=NOW,state='success')]
        elif path.endswith('/repos/o/r'): data={'permissions':{'push':False}}
        else: return self.output({'message':'unexpected local path '+path},status=404)
        if mode=='assembly' and path.endswith('/issues/9/comments') and page==1: data[0]['body']='x'*(48*1024*1024)
        paginate=path.endswith(('/comments','/reviews','/events','/check-runs','/statuses'))
        link=path+'?per_page=100&page=2' if paginate and page==1 else None
        try: self.output(data,link)
        except (BrokenPipeError,ssl.SSLError): pass
class Server(socketserver.ThreadingMixIn,http.server.HTTPServer): daemon_threads=True
class UnixServer(socketserver.ThreadingMixIn,socketserver.UnixStreamServer): daemon_threads=True
sock=ROOT/'.gh-api.sock'
sock.unlink(missing_ok=True)
server=UnixServer(str(sock),Handler); thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
gh=SCRATCH/'tools/gh-old/gh_2.45.0_macOS_arm64/bin/gh'; home=SCRATCH/'live-home'; shutil.rmtree(home,ignore_errors=True); home.mkdir(exist_ok=True)
for d in ['data','state','config','projects','gh-config']: (home/d).mkdir(exist_ok=True)
(home/'data/backlog.md').write_text('# Backlog\n\n## Queued\n- [ ] delivery - Published work https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n- [ ] filed - Filed defect https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','GH_','GITHUB_','TASKS_AXI'))}
env.update(PATH=str(gh.parent)+':'+os.environ['PATH'],FM_HOME=str(home),FM_ROOT_OVERRIDE=str(ROOT),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'),FM_PROJECTS_OVERRIDE=str(home/'projects'),GH_CONFIG_DIR=str(home/'gh-config'),GH_TOKEN='disposable-local-api-token',HTTPS_PROXY='',HTTP_PROXY='',NO_PROXY='',ALL_PROXY='',SSL_CERT_FILE=str(cert),TMPDIR=str(SCRATCH/'tmp'),FM_CONTRIBUTIONS_NOW=NOW,GH_PROMPT_DISABLED='1',GH_NO_UPDATE_NOTIFIER='1')
(home/'gh-config/config.yml').write_text('http_unix_socket: '+str(sock)+'\n')
log=[]
def run(*args,extra=None):
    e=env.copy(); e.update(extra or {}); start=time.monotonic(); result=subprocess.run(args,env=e,capture_output=True,text=True,timeout=45); elapsed=time.monotonic()-start
    log.append('$ '+ ' '.join(str(x) for x in args)+'\n'+result.stdout+result.stderr+f'\nexit={result.returncode} elapsed={elapsed:.3f}s\n')
    assert result.returncode==0, log[-1]; return result,elapsed
def records(task): return json.loads((home/f'data/{task}/contributions.json').read_text())['records'][0]
try:
    run(str(gh),'--version')
    denied=subprocess.run([str(gh),'api','repos/o/r/issues/9/comments','--paginate','--slurp'],env=env,capture_output=True,text=True)
    log.append('$ gh api ... --paginate --slurp\n'+denied.stderr+f'exit={denied.returncode}\n'); assert denied.returncode!=0 and 'unknown flag: --slurp' in denied.stderr
    run(str(gh),'api','repos/o/r/issues/9/comments?per_page=100','--paginate')
    cli=str(ROOT/'bin/fm-contributions.sh')
    result,_=run(cli,'poll'); assert 'observation unavailable' not in result.stdout
    pending,_=run(cli,'pending'); assert len(json.loads(pending.stdout))==5
    pr=records('delivery'); issue=records('filed')
    assert pr['error'] is None and issue['error'] is None
    assert set(p['type'] for p in pr['pending'])=={'comment','review','review-comment'}
    assert set(p['type'] for p in issue['pending'])=={'comment','ready-for-pr'}
    assert all(p.get('author') not in ('author','outsider') for r in (pr,issue) for p in r['pending'])
    assert len(pr['observation']['checks'])==4 and any(c['conclusion']=='failure' for c in pr['observation']['checks'])
    (EVIDENCE/'live-contributions-initial.json').write_text(json.dumps({'pr':pr,'issue':issue},indent=2))
    wakes=(home/'state/.wake-queue').read_bytes(); result,_=run(cli,'poll'); assert not result.stdout.strip(); assert (home/'state/.wake-queue').read_bytes()==wakes
    token=issue['pending'][0]['token']; run(cli,'ack','filed','https://github.com/o/r/issues/9',token)
    assert len(records('filed')['pending'])==1; run(cli,'poll'); assert len(records('filed')['pending'])==1
    before={t:(home/f'data/{t}/contributions.json').read_bytes() for t in ['delivery','filed']}
    mode='slow'; result,elapsed=run(cli,'poll',extra={'FM_CONTRIBUTIONS_BUDGET':'7'})
    assert elapsed<10 and 'observation unavailable' not in result.stdout
    assert all((home/f'data/{t}/contributions.json').read_bytes()==before[t] for t in before)
    log.append('Slow paginated response: prior observations retained byte-for-byte; no unavailable episode; bounded wall time.\n')
    mode='assembly'
    assemblytmp=SCRATCH/'assembly-tmp'; assemblytmp.mkdir(exist_ok=True)
    assemblyenv=env.copy(); assemblyenv.update(TMPDIR=str(assemblytmp),FM_CONTRIBUTIONS_BUDGET='7')
    start=time.monotonic(); owned=None; proof=None
    process=subprocess.Popen([cli,'poll'],env=assemblyenv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        while process.poll() is None and time.monotonic()-start<8:
            rows=subprocess.check_output(['ps','-axo','pid,ppid,command'],text=True).splitlines()[1:]
            table={int(parts[0]):(int(parts[1]),parts[2]) for row in rows if len(parts:=row.strip().split(None,2))==3}
            for pid,(ppid,command) in table.items():
                parts=command.split()
                if len(parts)<4 or pathlib.Path(parts[0]).name!='jq' or parts[1:3]!=['-s','.'] or str(assemblytmp) not in command or '/pages.' not in command: continue
                chain=[pid]; ancestor=ppid
                while ancestor in table and ancestor not in chain:
                    chain.append(ancestor)
                    if ancestor==process.pid: break
                    ancestor=table[ancestor][0]
                if process.pid not in chain: continue
                os.kill(pid,signal.SIGSTOP); owned=pid; proof={'assembler_pid':pid,'product_pid':process.pid,'parent_chain':chain,'command':command,'fault':'SIGSTOP on owned real jq process','elapsed_at_fault':time.monotonic()-start}; break
            if owned: break
            time.sleep(.01)
        if proof: (EVIDENCE/'live-assembly-fault-attempt.json').write_text(json.dumps(proof,indent=2))
        out,err=process.communicate(timeout=15); elapsed=time.monotonic()-start
        assert owned is not None, 'No actual assembler caught; cannot claim assembly proof'
        assert process.returncode==0 and elapsed<10 and not out.strip(), (process.returncode,elapsed,out,err)
        assert all((home/f'data/{t}/contributions.json').read_bytes()==before[t] for t in before)
        status=subprocess.run(['ps','-p',str(owned),'-o','stat='],capture_output=True,text=True)
        assert not status.stdout.strip(), 'Real stopped assembler outlived its bound'
        proof.update(elapsed_total=elapsed,exit=process.returncode,stdout=out,stderr=err,prior_observations_preserved=True,assembler_reaped=True)
        (EVIDENCE/'live-assembly-fault.json').write_text(json.dumps(proof,indent=2))
        owned=None
        log.append(f'Real page assembly suspended after ownership proof; poll returned silently in {elapsed:.3f}s, retained prior records, and reaped the actual jq process.\n')
    finally:
        if process.poll() is None: process.kill(); process.wait()
        if owned:
            try: os.kill(owned,signal.SIGCONT); os.kill(owned,signal.SIGKILL)
            except ProcessLookupError: pass
    mode='unavailable'; result,_=run(cli,'poll'); assert 'observation unavailable' in result.stdout; assert records('filed')['error'] is not None
    result,_=run(cli,'poll'); assert 'observation unavailable' not in result.stdout
    mode='normal'; run(cli,'poll'); assert records('filed')['error'] is None
    log.append('Unavailable service: one episode notification, subsequent suppression, successful recovery clears error.\n')
    (EVIDENCE/'live-contributions-final.json').write_text(json.dumps({'pr':records('delivery'),'issue':records('filed')},indent=2))
    basebin=SCRATCH/'base-bin'
    shutil.copytree(ROOT/'bin',basebin,dirs_exist_ok=True)
    (basebin/'fm-contributions.sh').write_bytes(subprocess.check_output(['git','show','eb77f02b16aeca9533102070de34b1f8812f4fa2:bin/fm-contributions.sh']))
    basehome=SCRATCH/'base-home'; shutil.rmtree(basehome,ignore_errors=True)
    for d in ['data','state','config','projects']: (basehome/d).mkdir(parents=True,exist_ok=True)
    (basehome/'data/backlog.md').write_bytes((home/'data/backlog.md').read_bytes())
    baseenv={f'FM_{k}':str(basehome if k=='HOME' else basehome/d) for k,d in [('HOME',''),('STATE_OVERRIDE','state'),('DATA_OVERRIDE','data'),('CONFIG_OVERRIDE','config'),('PROJECTS_OVERRIDE','projects')]}
    result,_=run(str(basebin/'fm-contributions.sh'),'poll',extra=baseenv)
    assert result.stdout.count('observation unavailable')==2
    assert all(json.loads((basehome/f'data/{t}/contributions.json').read_text())['records'][0]['error'] for t in ['filed','delivery'])
    log.append('Base eb77f02b reproduced two unavailable observations on the identical real gh2.45/local API setup; target captured later-page signals.\n')
    log.append('All real-product/gh2.45 pagination, ownership filtering, checks, wake dedup, ack, budget, and failure-recovery assertions passed.\n')
finally:
    (EVIDENCE/'live-contributions-transcript.log').write_text('\n'.join(log)); (EVIDENCE/'local-api-requests.json').write_text(json.dumps(requests,indent=2)); server.shutdown(); server.server_close(); sock.unlink(missing_ok=True)
