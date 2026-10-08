import os, pathlib, subprocess, time, signal, json, shutil, traceback, resource
ROOT=pathlib.Path.cwd()
BASE=ROOT/'.test-startup-network/live'
EVID=pathlib.Path('/Users/kesslerio/.no-mistakes/evidence/01M4E63C3Z7SP0Z1415AH2WBNA')
BASE.mkdir(parents=True,exist_ok=True)
RESULTS=[]
PROCS=[]
HOMES=[]
S=ROOT/'bin/fm-startup-network.sh'

def env(home, **kw):
    e={'PATH':'/usr/bin:/bin','HOME':str(home),'FM_HOME':str(home),'TMPDIR':str(BASE),'FM_STARTUP_NETWORK_TIMEOUT':'2','FM_SESSION_START_TIMEOUT':'2','GIT_CONFIG_GLOBAL':'/dev/null','GIT_CONFIG_NOSYSTEM':'1','LC_ALL':'C'}
    e.update({k:str(v) for k,v in kw.items()})
    return e

def home(name):
    h=BASE/name
    subprocess.run([str(ROOT/'bin/fm-lab-home.sh'),'create',str(h)],env={'PATH':'/usr/bin:/bin','HOME':str(BASE)},check=True,capture_output=True)
    HOMES.append(h)
    return h

def run(h,*args,**kw):
    r=subprocess.run([str(S),*args],env=env(h,**kw),capture_output=True,text=True,timeout=15)
    print('$ fm-startup-network.sh '+' '.join(args)+'\nexit='+str(r.returncode)+'\n'+r.stdout+r.stderr,flush=True)
    return r

def read(h,name):
    p=h/'state'/name
    return p.read_text() if p.is_file() else ''

def status(h):
    return dict(x.split('=',1) for x in read(h,'.startup-network.status').splitlines() if '=' in x)

def wake_count(h):
    return sum('\tcheck\tstartup-network\t' in x for x in read(h,'.wake-queue').splitlines())

def record(h):
    for name in ['.startup-network.status','.startup-network.report','.startup-network.timings','.wake-queue','.startup-network.delivered']:
        print(name+':\n'+read(h,name),flush=True)

def until(fn,seconds=8):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        if fn(): return
        time.sleep(.025)
    raise AssertionError('observable condition did not arrive within '+str(seconds)+'s')

def alive(pid):
    try: os.kill(int(pid),0); return True
    except (ProcessLookupError,ValueError,TypeError): return False

def settled(h):
    until(lambda: status(h).get('state') in ['done','failed','timeout'])
    pid=status(h).get('pid')
    until(lambda: not alive(pid),10)

def launch_internal(h,generation='retained',locked='0',owner='0'):
    script='printf "state=running\\npid=%s\\nstarted=%s\\nlocked='+locked+'\\nphases=probe\\ngeneration='+generation+'\\nlock_pid='+owner+'\\n" "$$" "$(date +%s)" > "$FM_HOME/state/.startup-network.status"; exec "$1" run --locked "$2" --lock-pid "$3" --generation "$4"'
    p=subprocess.Popen(['/bin/bash','-c',script,'_',str(S),locked,owner,generation],env=env(h),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
    PROCS.append(p)
    return p

def hold(h,*names):
    script='. "$1"; shift; for lock in "$@"; do fm_lock_acquire_wait "$lock" || exit 2; done; touch "$FM_HOME/state/held-ready"; trap \'for lock in "$@"; do fm_lock_release "$lock"; done; exit\' TERM INT; while :; do sleep 1; done'
    ready=h/'state/held-ready'
    ready.unlink(missing_ok=True)
    p=subprocess.Popen(['/bin/bash','-c',script,'_',str(ROOT/'bin/fm-wake-lib.sh'),*[str(h/'state'/n) for n in names]],env=env(h),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
    PROCS.append(p)
    until(ready.exists)
    return p

def release(p):
    if p.poll() is None:
        os.killpg(p.pid,signal.SIGTERM)
        try: p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid,signal.SIGKILL); p.wait()

def recover(h):
    # The new claimant remains live while we harvest the fresh generation, so
    # its independent authentication diagnostic cannot mask duplicate recovery.
    assert run(h,'start','--locked','0','--harvest-pid',str(os.getpid())).returncode==0
    until(lambda: status(h).get('state') in ['done','failed','timeout'])
    assert run(h,'harvest','--pid',str(os.getpid())).returncode==0
    settled(h)

def scenario(name,fn):
    print('\nSCENARIO: '+name,flush=True)
    begin=time.monotonic()
    try:
        fn()
        r={'name':name,'result':'pass','live':True,'evidence':'live-startup-network.log','reason':''}
    except Exception as ex:
        traceback.print_exc()
        r={'name':name,'result':'fail','live':True,'evidence':'live-startup-network.log','reason':str(ex)}
    print('RESULT '+r['result']+' elapsed='+str(round(time.monotonic()-begin,3)),flush=True)
    RESULTS.append(r)


def claimant():
    h=home('live-claimant')
    begin=time.monotonic()
    assert run(h,'start','--locked','0','--harvest-pid',str(os.getpid()),FM_SESSION_START_TIMEOUT=5).returncode==0
    until(lambda: status(h).get('state')=='done')
    pid=status(h)['pid']
    print('Claimant '+str(os.getpid())+' remains alive; worker '+pid+' is awaiting delivery.',flush=True)
    cpu=[]
    for _ in range(4):
        cpu.append(subprocess.run(['/bin/ps','-p',pid,'-o','pid=,time=,%cpu=,stat='],capture_output=True,text=True).stdout.strip())
        time.sleep(.5)
    print('Worker CPU samples:\n'+'\n'.join(cpu),flush=True)
    settled(h)
    elapsed=time.monotonic()-begin
    assert elapsed<9,elapsed
    assert wake_count(h)==1
    assert 'NEEDS_GH_AUTH' in run(h,'report').stdout
    assert run(h,'harvest','--pid',str(os.getpid())).returncode==0
    assert wake_count(h)==1
    record(h)
    print('Worker settled in %.3fs while claimant still alive; one notification.'%elapsed,flush=True)


def inline():
    h=home('inline')
    assert run(h,'start','--locked','0','--harvest-pid',str(os.getpid()),FM_SESSION_START_TIMEOUT=5).returncode==0
    until(lambda: status(h).get('state')=='done')
    assert 'NEEDS_GH_AUTH' in run(h,'harvest','--pid',str(os.getpid())).stdout
    settled(h)
    assert wake_count(h)==0
    assert read(h,'.startup-network.delivered')=='delivered\n'
    record(h)


def failed_publication():
    h=home('failed-publication')
    (h/'state/.startup-network.report').mkdir()
    assert run(h,'run','--locked','0').returncode!=0
    g=status(h)['generation']
    out=run(h,'report').stdout
    assert 'NEEDS_GH_AUTH' in out and 'gh-auth' in out
    assert wake_count(h)==0
    out=run(h,'harvest').stdout
    assert 'could not publish' in out and 'NEEDS_GH_AUTH' not in out
    assert not (h/'state/.startup-network.delivered').exists()
    assert run(h,'start','--locked','0','--harvest-pid','0').returncode!=0
    assert status(h)['generation']==g and wake_count(h)==0
    (h/'state/.startup-network.report').rmdir()
    recover(h)
    assert wake_count(h)==1
    recover(h)
    assert wake_count(h)==1
    assert not (h/'state/.startup-network.pending').exists()
    record(h)


def blocked_precheck():
    h=home('precheck')
    holder=hold(h,'.startup-network.lock')
    p=launch_internal(h)
    output=p.communicate(timeout=8)[0]
    print('Reserved worker exit='+str(p.returncode)+'\n'+output,flush=True)
    assert p.returncode!=0
    assert wake_count(h)==0
    out=run(h,'report').stdout
    assert 'still held by pid '+str(holder.pid) in out
    release(holder)
    recover(h)
    assert wake_count(h)==1
    record(h)


def blocked_delivery(lock):
    h=home('delivery-'+lock.replace('.',''))
    holder=hold(h,lock)
    begin=time.monotonic()
    assert run(h,'run','--locked','0').returncode==0
    assert time.monotonic()-begin<6
    assert wake_count(h)==0
    assert 'NEEDS_GH_AUTH' in run(h,'report').stdout
    assert (h/'state/.startup-network.pending/report').is_file()
    release(holder)
    recover(h)
    assert wake_count(h)==1
    recover(h)
    assert wake_count(h)==1
    record(h)


def staged(allow):
    h=home('staged-'+str(allow))
    holder=hold(h,'.startup-network.lock','.startup-network.reserve.lock')
    p=launch_internal(h,'original')
    output=p.communicate(timeout=9)[0]
    print('Bounded worker exit='+str(p.returncode)+'\n'+output,flush=True)
    staged=list((h/'state').glob('.startup-network-pending.*/status'))
    assert p.returncode!=0 and len(staged)==1
    print('Recoverable staged status:\n'+staged[0].read_text(),flush=True)
    findings=staged[0].with_name('report').read_text()
    print('Recoverable staged report:\n'+findings,flush=True)
    assert 'still held by pid '+str(holder.pid) in findings
    assert wake_count(h)==0
    # Simulate replacement committing vs dying before its atomic commit.
    if not allow:
        (h/'state/.startup-network.status').write_text('state=done\ngeneration=successor\nreport_published=1\n')
    release(holder)
    recover(h)
    assert wake_count(h)==(1 if allow else 0)
    assert not list((h/'state').glob('.startup-network-pending.*'))
    assert not (h/'state/.startup-network.pending').exists()
    record(h)


def denied_owner():
    h=home('denied-owner')
    (h/'state/.lock').write_text(str(os.getpid())+'\n')
    p=launch_internal(h,'denied','1','999999999')
    print(p.communicate(timeout=8)[0],flush=True)
    assert p.returncode==0
    out=run(h,'report').stdout
    assert 'were skipped' in out
    assert status(h)['locked']=='0' and status(h)['phases']=='probe'
    assert wake_count(h)==1
    assert run(h,'start','--locked','1','--harvest-pid','0').returncode!=0
    record(h)

try:
    scenario('A live inline claimant cannot keep the worker running beyond its delivery budget',claimant)
    scenario('Inline harvest acknowledges published findings and suppresses their notification',inline)
    scenario('Failed publication retains readable findings and timings; later startup publishes and notifies once',failed_publication)
    scenario('A held publication lock ends the reserved worker with retained actionable timeout findings',blocked_precheck)
    scenario('A held notification queue lock leaves bounded delivery recoverable at the next startup',lambda: blocked_delivery('.wake-queue.lock'))
    scenario('A held nested recovery lock leaves bounded delivery recoverable at the next startup',lambda: blocked_delivery('.watcher-down.lock'))
    scenario('An interrupted reservation leaves staged current-generation findings recoverable by later startup',lambda: staged(True))
    scenario('A committed successor generation rejects stale staged findings without notification',lambda: staged(False))
    scenario('A replaced owner cannot execute mutating sweeps or launch a locked startup',denied_owner)
finally:
    for p in PROCS: release(p)
    for h in HOMES:
        pid=status(h).get('pid')
        if alive(pid):
            try: os.kill(int(pid),signal.SIGTERM)
            except ProcessLookupError: pass
    shutil.rmtree(BASE)
    (EVID/'live-scenarios.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
    print('Disposable homes and owned processes cleaned up.',flush=True)
raise SystemExit(0 if RESULTS and all(r['result']=='pass' for r in RESULTS) else 1)
