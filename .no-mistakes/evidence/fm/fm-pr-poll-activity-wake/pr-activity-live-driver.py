"""Disposable GraphQL service; actual gh, poll and watcher execute unchanged."""
import os, ssl, socketserver, threading, subprocess, json, shutil, signal, time, copy, re, sys
from pathlib import Path

ROOT=Path.cwd()
WORK=ROOT/'.test-phase'
EVIDENCE=Path('/Users/kesslerio/.no-mistakes/evidence/01M4EB6PH5HBE0EJC90N84Y25W')
URL='https://github.com/fixture/repo/pull/1'
CTX=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
CTX.load_cert_chain(WORK/'cert.pem',WORK/'key.pem')
STATE={'data':None,'status':200,'raw':None,'gate':None,'received':None}
REQUESTS=[]
LOG=[]
RESULTS=[]

class Proxy(socketserver.StreamRequestHandler):
    def handle(self):
        first=self.rfile.readline()
        while self.rfile.readline() not in (b'\r\n',b'\n',b''): pass
        if not first.startswith(b'CONNECT api.github.com:443 '):
            self.wfile.write(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n'); return
        self.wfile.write(b'HTTP/1.1 200 Connection established\r\n\r\n'); self.wfile.flush()
        try:
            with CTX.wrap_socket(self.connection,server_side=True) as s:
                f=s.makefile('rb'); line=f.readline().decode().strip(); headers={}
                while True:
                    h=f.readline()
                    if h in (b'\r\n',b'\n',b''): break
                    k,v=h.decode().split(':',1); headers[k.lower()]=v.strip()
                body=f.read(int(headers.get('content-length','0')))
                req=json.loads(body)
                REQUESTS.append({'request':line,**req})
                gate,received=STATE['gate'],STATE['received']
                if received: received.set()
                if gate and not gate.wait(12): return
                data=STATE['raw'] if STATE['raw'] is not None else json.dumps(STATE['data']).encode()
                status=STATE['status']
                s.sendall(f'HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {len(data)}\r\nConnection: close\r\n\r\n'.encode()+data)
        except (BrokenPipeError,ConnectionResetError,ssl.SSLError): pass

SERVER=socketserver.ThreadingTCPServer(('127.0.0.1',0),Proxy)
SERVER.daemon_threads=True
threading.Thread(target=SERVER.serve_forever,daemon=True).start()
(WORK/'toolbin').mkdir(exist_ok=True)
if not (WORK/'toolbin/gh').exists(): (WORK/'toolbin/gh').symlink_to(shutil.which('gh'))
ENV={k:v for k,v in os.environ.items() if not k.startswith(('FM_','GH_','GITHUB_','TASKS_AXI_')) and k not in ('TMUX','CLAUDECODE','CODEX_THREAD_ID')}
ENV.update(GH_TOKEN='disposable-fixture-token',GH_CONFIG_DIR=str(WORK/'gh'),HTTPS_PROXY=f'http://127.0.0.1:{SERVER.server_address[1]}',HTTP_PROXY=f'http://127.0.0.1:{SERVER.server_address[1]}',ALL_PROXY=f'http://127.0.0.1:{SERVER.server_address[1]}',NO_PROXY='',SSL_CERT_FILE=str(WORK/'cert.pem'),GH_NO_UPDATE_NOTIFIER='1',GH_TELEMETRY='0',GH_PROMPT_DISABLED='1',TMPDIR=str(WORK/'tmp'),PATH=str(WORK/'toolbin')+':/usr/bin:/bin:/usr/sbin:/sbin',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
PIDS=[]

def log(s): LOG.append(s); print(s,flush=True)
def response(comments=None,reviews=None,cp=False,rp=False,state='OPEN'):
    STATE.update(data={'data':{'repository':{'pullRequest':{'state':state,'comments':{'nodes':(comments or [])[:100],'pageInfo':{'hasNextPage':cp or len(comments or [])>100}},'reviews':{'nodes':(reviews or [])[:100],'pageInfo':{'hasNextPage':rp or len(reviews or [])>100}}}}}},raw=None,status=200,gate=None,received=None)
def comment(id,body='note',author='a',date='2026-10-08T01:00:00Z'):
    return {'id':id,'author':None if author is None else {'login':author},'createdAt':date,'body':body}
def review(id,state='CHANGES_REQUESTED',body='',author='b',date='2026-10-08T02:00:00Z'):
    return {'id':id,'author':None if author is None else {'login':author},'submittedAt':date,'state':state,'body':body}
def case(name):
    home=WORK/name
    p=subprocess.run(['bash','bin/fm-lab-home.sh','create',str(home)],env=ENV,capture_output=True,text=True,timeout=10)
    assert p.returncode==0,(p.stdout,p.stderr)
    state=home/'state'; (home/'wt').mkdir()
    (state/'task-a.meta').write_text(f'window=fm-task-a\nworktree={home}/wt\npr={URL}\n')
    env={**ENV,'FM_HOME':str(home)}
    cmd='. bin/fm-pr-lib.sh; fm_pr_poll_prepare "$FM_HOME/state" task-a github "https://github.com/fixture/repo/pull/1" github.com fixture/repo 1 "$PWD/bin/fm-pr-poll.sh" && fm_pr_poll_publish_prepared'
    p=subprocess.run(['bash','-c',cmd],env=env,capture_output=True,text=True,timeout=10)
    assert p.returncode==0,(p.stdout,p.stderr)
    return home,env,state/'task-a.pr-activity'
def poll(home,env,anchor=None,validated=False):
    if validated:
        args=['bash','bin/fm-pr-poll.sh','--validated','github',URL,'github.com','fixture/repo','1']
        if anchor is not None: args.append(str(anchor))
    else: args=['bash',str(home/'state/task-a.check.sh')]
    before=len(REQUESTS)
    p=subprocess.run(args,env=env,capture_output=True,text=True,timeout=15)
    assert p.returncode==0,(p.returncode,p.stdout,p.stderr)
    assert len(REQUESTS)-before==1,('not one request',len(REQUESTS)-before)
    q=REQUESTS[-1]['query']
    assert 'comments(first: 100)' in q and 'reviews(first: 100)' in q and q.count('pageInfo { hasNextPage }')==2
    assert 'after:' not in q and 'endCursor' not in q
    assert REQUESTS[-1]['variables']=={'owner':'fixture','repo':'repo','number':1}
    log(f'poll stdout={p.stdout!r}; stderr={p.stderr!r}; requests=1')
    return p.stdout
def watcher(home,env,timeout=18):
    e={**env,'FM_CHECK_INTERVAL':'0','FM_POLL':'0.02','FM_HEARTBEAT':'999999','FM_SIGNAL_GRACE':'0'}
    p=subprocess.Popen(['bash','bin/fm-watch.sh'],env=e,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
    PIDS.append(p.pid)
    try: out,err=p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid,signal.SIGKILL);out,err=p.communicate(); raise AssertionError(('watcher timeout',out,err))
    log(f'watcher exit={p.returncode}; stdout={out!r}; stderr={err!r}')
    return p.returncode,out
def queue(home): return (home/'state/.wake-queue').read_text()
def recover_and_watch(home,env):
    rc,out=watcher(home,env)
    if 'check: rearm-resurface' in out:
        drain=subprocess.run(['bash','bin/fm-wake-drain.sh'],env=env,capture_output=True,text=True,timeout=20)
        log(f'recovery drain exit={drain.returncode}; stdout={drain.stdout!r}; stderr={drain.stderr!r}')
        ack=re.search(r'WAKE_ACK_REQUIRED:.*--ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)',drain.stderr)
        assert ack,'recovery drain did not supply acknowledgment'
        done=subprocess.run(['bash','bin/fm-wake-drain.sh','--ack-through',ack[1],'--recovery-generation',ack[2]],env=env,capture_output=True,text=True,timeout=20)
        log(f'recovery acknowledgment exit={done.returncode}; stdout={done.stdout!r}; stderr={done.stderr!r}')
        assert done.returncode==0,'recovery acknowledgment failed'
        rc,out=watcher(home,env)
    return rc,out
def run(name,fn):
    log('\nSCENARIO: '+name)
    try: fn(); RESULTS.append({'name':name,'result':'pass','live':True});log('RESULT: pass')
    except Exception as e: RESULTS.append({'name':name,'result':'fail','live':True,'error':repr(e)});log('RESULT: fail '+repr(e))

def seeds():
    h,e,c=case('seeds'); response([comment('OLD')]); assert poll(h,e)==''
    assert c.read_text()==f'fm-pr-activity-v1\n{URL}\nOLD\n'; assert c.stat().st_mode&0o777==0o600
    assert poll(h,e)==''
    c.write_text('fm-pr-activity-v1\nhttps://github.com/fixture/repo/pull/9\nOTHER\n')
    assert poll(h,e)=='';assert URL in c.read_text();assert 'OLD\n' in c.read_text()
    c.unlink();assert poll(h,e,validated=True)=='';assert not c.exists()
    log('first sight and URL-mismatch seed silently; missing anchor leaves no cursor; mode=0600')

def comments():
    h,e,c=case('comments');response();assert poll(h,e)=='';baseline=c.read_text()
    marker=h/'executed';body='x'*199+'😀'+'extra\nsecond line'
    response([comment('NEW',body)]);expected=f'pr-activity: {URL} comment a: '+'x'*199+'😀\n'
    assert poll(h,e)==expected;assert c.read_text()==baseline;assert 'NEW\n' in Path(str(c)+'.pending').read_text()
    rc,out=watcher(h,e);assert rc==0 and expected.strip() in out
    assert expected.strip() in queue(h);assert 'NEW\n' in c.read_text();assert not Path(str(c)+'.pending').exists();assert poll(h,e)==''
    injection=f'hello $(touch {marker})';response([comment('NEW',body),comment('NEW2',injection,None)])
    assert poll(h,e)==f'pr-activity: {URL} comment unknown: {injection}\n';assert not marker.exists()
    log('valid UTF-8 200-character output; one-character login; unknown author; literal shell text; queued then committed; replay silent')

def reviews():
    h,e,c=case('reviews');response();assert poll(h,e)==''
    response(reviews=[review('DRAFT','PENDING','draft')]);assert poll(h,e)==''
    response([comment('C1','older',date='2026-10-08T01:00:00Z')],[review('R1'),review('DRAFT','PENDING','draft')])
    expected=f'pr-activity: {URL} review b: 2 new: CHANGES_REQUESTED\n';assert poll(h,e)==expected
    rc,out=watcher(h,e);assert rc==0 and expected.strip() in out;assert queue(h).count(expected.strip())==1
    response([comment('C1','edited')],[review('R1',body='edited'),review('DRAFT','PENDING','draft')]);assert poll(h,e)==''
    response([comment('C1','edited')],[review('R1',body='edited'),review('DRAFT','APPROVED','approved')]);assert poll(h,e)==f'pr-activity: {URL} review b: approved\n'
    log('pending draft suppressed; submitted batch is one line; edits do not wake; later submitted approval wakes')

def failed_append():
    h,e,c=case('failed-append');response();assert poll(h,e)=='';baseline=c.read_text()
    response([comment('NEW','retry note')]);(h/'state/.wake-queue.seq').mkdir()
    rc,out=watcher(h,e);assert rc!=0;assert c.read_text()==baseline;assert 'NEW\n' in Path(str(c)+'.pending').read_text()
    assert poll(h,e)==f'pr-activity: {URL} comment a: retry note\n'
    (h/'state/.wake-queue.seq').rmdir();rc,out=recover_and_watch(h,e);assert rc==0;assert 'retry note' in queue(h);assert 'NEW\n' in c.read_text();assert poll(h,e)==''
    log('failed durable append preserves committed cursor; repaired queue delivers and commits the same activity')

def interrupted():
    h,e,c=case('interrupted');response();assert poll(h,e)=='';baseline=c.read_text()
    response([comment('NEW','after crash')]);gate=threading.Event();received=threading.Event();STATE.update(gate=gate,received=received)
    p=subprocess.Popen(['bash','bin/fm-watch.sh'],env={**e,'FM_CHECK_INTERVAL':'0','FM_POLL':'0.02','FM_HEARTBEAT':'999999','FM_SIGNAL_GRACE':'0'},stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True);PIDS.append(p.pid)
    try:
        assert received.wait(12),'watcher never requested activity'
        os.kill(p.pid,signal.SIGSTOP);gate.set()
        deadline=time.monotonic()+12
        while not Path(str(c)+'.pending').exists() and time.monotonic()<deadline: time.sleep(.02)
        assert Path(str(c)+'.pending').exists(),'poll did not stage while watcher stopped'
        assert c.read_text()==baseline;assert not (h/'state/.wake-queue').exists()
    finally:
        os.killpg(p.pid,signal.SIGKILL);out,err=p.communicate(timeout=5);STATE.update(gate=None,received=None)
    log(f'watcher stopped before capture handoff, poll staged NEW, process group killed; exit={p.returncode}')
    assert c.read_text()==baseline;assert poll(h,e)==f'pr-activity: {URL} comment a: after crash\n'
    rc,out=recover_and_watch(h,e);assert rc==0 and 'after crash' in out;assert 'NEW\n' in c.read_text();assert poll(h,e)==''

def bounded():
    for kind in ('comment','review'):
        h,e,c=case('bounded-'+kind)
        comments=[comment('C'+str(i),'old') for i in range(101)] if kind=='comment' else []
        reviews=[review('R'+str(i),'COMMENTED','old') for i in range(101)] if kind=='review' else []
        response(comments,reviews);assert poll(h,e)=='';baseline=c.read_text()
        if kind=='comment':comments[100]=comment('OUTSIDE','unread')
        else:reviews[100]=review('OUTSIDE','COMMENTED','unread')
        response(comments,reviews);assert poll(h,e)=='';assert c.read_text()==baseline;assert 'OUTSIDE' not in c.read_text()
        if kind=='comment':reviews=[review('NEW','COMMENTED','bounded note')];newkind='review';author='b'
        else:comments=[comment('NEW','bounded note')];newkind='comment';author='a'
        response(comments,reviews);expected=f'pr-activity: {URL} {newkind} {author}: truncated: bounded note\n';assert poll(h,e)==expected
        rc,out=watcher(h,e);assert rc==0 and expected.strip() in out;assert 'OUTSIDE' not in c.read_text();assert poll(h,e)==''
    log('both collections limited to 100; unread items never recorded or wake; either hasNextPage marks delivered activity truncated; one request per sweep')

def malformed():
    h,e,c=case('malformed');response();assert poll(h,e)=='';baseline=c.read_text()
    response([comment('NEW')]);valid=copy.deepcopy(STATE['data'])
    bad=[]
    x=copy.deepcopy(valid);del x['data']['repository']['pullRequest']['comments']['pageInfo'];bad.append(('missing pageInfo',x,None,200))
    x=copy.deepcopy(valid);x['data']['repository']['pullRequest']['reviews']['pageInfo']['hasNextPage']='true';bad.append(('nonboolean pageInfo',x,None,200))
    bad.extend([('short JSON',{'data':{'repository':{'pullRequest':{'state':'OPEN'}}}},None,200),('invalid JSON',None,b'{"data":',200),('GraphQL error',{'errors':[{'message':'fixture error'}]},None,200),('HTTP error',valid,None,503)])
    x=copy.deepcopy(valid);x['data']['repository']['pullRequest']['comments']['nodes'].append(comment('NEW'));bad.append(('duplicate IDs',x,None,200))
    for label,data,raw,status in bad:
        STATE.update(data=data,raw=raw,status=status);assert poll(h,e)=='';assert c.read_text()==baseline;assert not Path(str(c)+'.pending').exists();log(label+': silent and unchanged')
    response([comment('RECOVERY','recovered')]);assert poll(h,e)==f'pr-activity: {URL} comment a: recovered\n'

def unsafe():
    for suffix in ('','.pending'):
        for kind in ('symlink','hardlink','mode','directory'):
            h,e,c=case('unsafe'+suffix+'-'+kind);response();assert poll(h,e)=='';baseline=c.read_text()
            dest=Path(str(c)+suffix);sentinel=h/'sentinel';sentinel.write_text('sentinel\n');sentinel.chmod(0o600)
            if dest.exists():dest.unlink()
            if kind=='symlink':dest.symlink_to(sentinel)
            elif kind=='hardlink':os.link(sentinel,dest)
            elif kind=='mode':dest.write_text('sentinel\n');dest.chmod(0o644)
            else:dest.mkdir()
            response([comment('NEW')]);assert poll(h,e)=='';assert sentinel.read_text()=='sentinel\n'
            if suffix:assert c.read_text()==baseline
            log(f'{kind} cursor{suffix}: refused without touching sentinel')
    h,e,c=case('tamper-check');response();check=h/'state/task-a.check.sh';check.write_text(check.read_text()+'\n# tampered copy\n');before=len(REQUESTS)
    rc,out=watcher(h,e);assert rc==0 and 'rejected unauthenticated state checks' in out;assert len(REQUESTS)==before;assert not c.exists();log('tampered registered check rejected before forge read')

def merge():
    h,e,c=case('merge');response();assert poll(h,e)=='';baseline=c.read_text()
    response([comment('NEW','unread on merge')],state='MERGED');assert poll(h,e)=='merged\n';assert c.read_text()==baseline;assert not Path(str(c)+'.pending').exists()
    response(state='CLOSED');assert poll(h,e)=='';log('merged output exactly merged; no cursor change; closed state silent')

def paths():
    h,e,c=case('path-guards');response();assert poll(h,e)=='';baseline=c.read_text()
    response([comment('NEW','must not escape')]);(h/'linked').symlink_to(h/'state',target_is_directory=True)
    for anchor in (str(h)+'/state/../state/task-a.check.sh',str(h)+'/state/./task-a.check.sh',str(h)+'/state//task-a.check.sh',str(h)+'/linked/task-a.check.sh'):
        assert poll(h,e,anchor=anchor,validated=True)==''
        assert c.read_text()==baseline;assert not Path(str(c)+'.pending').exists()
        log('refused cursor anchor: '+anchor)

try:
    if len(sys.argv)>1:
        LOG=(EVIDENCE/'pr-activity-live-transcript.txt').read_text().splitlines()
        RESULTS=[r for r in json.loads((EVIDENCE/'pr-activity-live-results.json').read_text()) if r['result']=='pass']
        REQUESTS=json.loads((EVIDENCE/'pr-activity-graphql-requests.json').read_text())
        log('\nSETUP CORRECTION: initial failure and crash retries stopped at the existing rearm-resurface handshake. Re-drive them through the real wake-drain and generation-bound acknowledgment interfaces before asserting delivery. No product changes.')
    log(subprocess.run(['gh','--version'],capture_output=True,text=True).stdout.strip())
    log('Actual gh and unmodified production scripts; disposable GraphQL TLS proxy on loopback; no production credentials or endpoint; watcher has no fleet backend available; jq absent from product PATH.')
    for name,fn in [('First sight, missing anchor, and URL reseeding are silent',seeds),('A new comment queues once, preserves text, and suppresses replay',comments),('Submitted reviews wake once while drafts and edits remain silent',reviews),('Failed queue append preserves activity for retry',failed_append),('Watcher crash before durable queue cannot drop staged activity',interrupted),('Bounded collections mark delivered activity truncated',bounded),('Forge and parsing failures leave the cursor unchanged',malformed),('Unsafe cursor siblings and unauthenticated checks are refused',unsafe),('Merge output remains exactly merged without activity cursor writes',merge),('Unsafe cursor anchor paths cannot alter task state',paths)]:
        if len(sys.argv)==1 or fn.__name__ in sys.argv[1:]:run(name,fn)
finally:
    SERVER.shutdown();SERVER.server_close()
    remaining=[]
    ps=subprocess.run(['ps','-axo','pid=,pgid=,stat='],capture_output=True,text=True)
    for line in ps.stdout.splitlines():
        parts=line.split()
        if len(parts)>=3 and int(parts[1]) in PIDS and not parts[2].startswith('Z'):remaining.append(line)
    log('Remaining live processes in watcher groups: '+repr(remaining))
    if remaining:RESULTS.append({'name':'Watcher descendants stop','result':'fail','live':True,'error':repr(remaining)})
    (EVIDENCE/'pr-activity-live-transcript.txt').write_text('\n'.join(LOG)+'\n')
    (EVIDENCE/'pr-activity-live-results.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
    (EVIDENCE/'pr-activity-graphql-requests.json').write_text(json.dumps(REQUESTS,indent=2)+'\n')
    snapshots=json.loads((EVIDENCE/'pr-activity-persisted-state.json').read_text()) if (EVIDENCE/'pr-activity-persisted-state.json').exists() else {}
    for home in WORK.iterdir():
        if home.is_dir() and (home/'.fm-lab-home').exists():
            records={}
            for leaf in ('task-a.pr-activity','task-a.pr-activity.pending','.wake-queue'):
                f=home/'state'/leaf
                if f.is_file() and not f.is_symlink():
                    records[leaf]={'mode':oct(f.stat().st_mode&0o777),'content':f.read_text()}
            snapshots[home.name]=records
    (EVIDENCE/'pr-activity-persisted-state.json').write_text(json.dumps(snapshots,indent=2)+'\n')
    for home in WORK.iterdir():
        if home.is_dir() and (home/'.fm-lab-home').exists():shutil.rmtree(home)
raise SystemExit(1 if any(r['result']=='fail' for r in RESULTS) else 0)
