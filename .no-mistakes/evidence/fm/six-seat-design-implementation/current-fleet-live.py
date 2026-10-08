import concurrent.futures,json,os,pathlib,shlex,subprocess,time
ROOT=pathlib.Path.cwd()
EVIDENCE=pathlib.Path('/Users/kesslerio/.no-mistakes/evidence/01M4C86PSDNBECPTMSZ1YVFF8Q')
BASE=ROOT/'.test-current-live'
BASE.mkdir(parents=True,exist_ok=True)
ENV=os.environ.copy()
for k in list(ENV):
    if k.startswith('FM_') or k in ('TMUX','HERDR_ENV','HERDR_SESSION','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):ENV.pop(k,None)
ENV['TMPDIR']=str(BASE)
SELECT='defaults,concurrency,buffered,unmanaged'
LOG=(EVIDENCE/'current-fleet-live.log').open('w')
RESULTS=[]
SOCKET_DIR=None

def run(args,home=None,code=0,env=None,stdin=None,log=True):
    e=ENV.copy()
    if home:e['FM_HOME']=str(home)
    if env:e.update(env)
    p=subprocess.run([str(a) for a in args],cwd=ROOT,env=e,text=True,input=stdin,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=45)
    if log:
        LOG.write('$ '+shlex.join([str(a) for a in args])+'\n'+p.stdout+'exit='+str(p.returncode)+'\n');LOG.flush()
    if code is not None:assert p.returncode==code,(args,p.returncode,p.stdout)
    return p

def home(name):
    h=BASE/name
    run(['bin/fm-lab-home.sh','create',h]);return h

def policy(h,cap=1):
    (h/'config/fleet-seats').write_text(json.dumps({'pools':[{'name':'shared','capacity':cap,'models':['pool-a','pool-b']}]}))

def seats(h,*args,code=0,env=None):return run(['bin/fm-fleet-seats.sh',*args],h,code,env)
def reserve(h,task,gen,prev=None,kind='ship',code=0,env=None):
    a=['reserve',task,'--generation',gen,'--kind',kind,'--harness','claude','--model','pool-a','--holder-pid',str(os.getpid())]
    if prev:a+=['--previous-generation',prev]
    return seats(h,*a,code=code,env=env)
def show(h,t):return json.loads(seats(h,'show',t).stdout)
def current(h,t,g):return next(x for x in show(h,t)['incarnations'] if x['generation']==g)
def scenario(name,fn):
    if SELECT and fn.__name__ not in SELECT.split(','):return
    try:fn();RESULTS.append({'name':name,'result':'pass','live':True});LOG.write('SCENARIO PASS: '+name+'\n')
    except Exception as exc:RESULTS.append({'name':name,'result':'fail','live':True,'reason':str(exc)});LOG.write('SCENARIO FAIL: '+name+' '+repr(exc)+'\n')
    LOG.flush()

def defaults():
    h=home('defaults')
    p=seats(h,'reserve','off','--generation','g-off','--harness','claude','--model','default','--holder-pid',str(os.getpid()))
    assert p.stdout=='' and not (h/'state/fleet-seats').exists()
    policy(h)
    seats(h,'reserve','default','--generation','g-default','--harness','claude','--model','default','--holder-pid',str(os.getpid()),code=5)
    seats(h,'reserve','raw','--generation','g-raw','--harness','claude','--model','pool-a','--holder-pid',str(os.getpid()),'--raw-launch',code=5)
    (h/'config/fleet-seats').write_text('{"pools":[{"name":"../escape","capacity":6,"models":["pool-a"]}]}')
    reserve(h,'bad','g-bad',code=5)
    assert not any((h/'state').glob('fleet-seats/holders/*.json'))

def concurrency():
    h=home('capacity');policy(h,6)
    child=home('child')
    (child/'.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=local\nparent_home='+str(h)+'\n')
    (child/'.fm-secondmate-home').write_text('child\n')
    (h/'data/secondmates.md').write_text('- child - Lab mate. (home: '+str(child)+'; scope: tests; projects: ; added 2026-10-07)\n')
    def contender(i):
        hh=h if i%2==0 else child
        p=run(['bin/fm-fleet-seats.sh','reserve','task'+str(i),'--generation','g'+str(i),'--harness','claude','--model','pool-a','--holder-pid',str(os.getpid())],hh,code=None,log=False)
        return i,hh,p
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as ex:out=list(ex.map(contender,range(12)))
    for i,hh,p in out:LOG.write('home='+str(hh)+' task='+str(i)+' exit='+str(p.returncode)+'\n'+p.stdout)
    winners=[(i,hh) for i,hh,p in out if p.returncode==0]
    assert len(winners)==6 and all(p.returncode in (0,4) for _,_,p in out)
    i,hh=winners[0];t='task'+str(i);g='g'+str(i)
    reserve(hh,t,g)
    assert len(show(hh,t)['incarnations'])==1
    reserve(hh,t,'replacement',prev=g)
    assert len(show(hh,t)['incarnations'])==2
    seats(hh,'release',t,'--generation','foreign','--reason','prelaunch')
    assert current(hh,t,'replacement')['lifecycle']=='reserved'
    reserve(h,'extra','g-extra',code=4)
    seats(hh,'release',t,'--generation','replacement','--reason','prelaunch')
    assert current(hh,t,g)['lifecycle']=='reserved'
    reserve(h,'still-full','g-still-full',code=4)
    seats(hh,'release',t,'--generation',g,'--reason','prelaunch')
    reserve(h,'new-slot','g-new-slot')

def prepare(h,t,g,target,kind='secondmate',dispatch=True):
    r=h/'state'/('route-'+g)
    r.write_text(json.dumps({'placement':'local','backend':'tmux','target':target,'home':str(h),'host':None,'remote_root':None,'spawn_gen':g,'operation':None}));r.chmod(0o600)
    cmd='bin/fm-fleet-seats.sh reserve '+shlex.quote(t)+' --generation '+shlex.quote(g)+' --kind '+kind+' --harness claude --model pool-a --holder-pid "$$"'
    if dispatch:cmd+=' && bin/fm-fleet-seats.sh dispatch '+shlex.quote(t)+' --generation '+shlex.quote(g)+' --route-file '+shlex.quote(str(r))
    run(['bash','-c',cmd],h,env=TMENV)

def never_dispatched():
    h=home('prepared');policy(h)
    prepare(h,'mate','g-prepared','primary:fm-mate',dispatch=False)
    (h/'state/mate.meta').write_text('kind=secondmate\nmodel=pool-a\nfleet_seat_generation=g-prepared\n')
    cmd=""". bin/fm-secondmate-liveness-lib.sh; fm_supervisor_lifecycle_acquire "$FM_HOME/state" mate 0 || exit; lock=$(fm_meta_lock_path "$FM_HOME/state/mate.meta"); fm_lock_acquire_wait_max "$lock" 2 || exit; trap 'fm_lock_release "$lock"; fm_supervisor_lifecycle_release "$FM_HOME/state" mate' EXIT; bin/fm-fleet-seats.sh reclaim mate --generation g-prepared"""
    start=time.monotonic();run(['bash','-c',cmd],h,env=TMENV)
    assert time.monotonic()-start<10 and current(h,'mate','g-prepared')['lifecycle']=='reclaimed'

def buffered():
    h=home('buffered');policy(h)
    run(['tmux','-L','fm-lab','new-window','-d','-t','primary','-n','fm-buffered','-c',ROOT,'bash --noprofile --norc'],env=TMENV)
    prepare(h,'buffered','g-buffered','primary:fm-buffered')
    seats(h,'confirm','buffered','--generation','g-buffered',code=3,env=TMENV)
    seats(h,'dispatch','buffered','--generation','g-buffered','--route-file',str(h/'state/route-g-buffered'),code=5,env=TMENV)
    seats(h,'release','buffered','--generation','g-buffered','--reason','prelaunch',code=5,env=TMENV)
    seats(h,'reclaim','buffered','--generation','g-buffered',code=3,env=TMENV)
    reserve(h,'other','g-other',code=4,env=TMENV)
    run(['tmux','-L','fm-lab','kill-window','-t','primary:fm-buffered'],env=TMENV)
    seats(h,'reclaim','buffered','--generation','g-buffered',code=3,env=TMENV)
    assert current(h,'buffered','g-buffered')['lifecycle']=='reserved'

def unmanaged():
    h=home('legacy');policy(h)
    mate=home('legacy-home')
    run(['tmux','-L','fm-lab','new-window','-d','-t','primary','-n','fm-legacy','-c',ROOT,'bash --noprofile --norc'],env=TMENV)
    (h/'state/legacy.meta').write_text('kind=secondmate\nmodel=pool-a\nharness=claude\nhome='+str(mate)+'\nwindow=primary:fm-legacy\nworktree='+str(mate)+'\nproject='+str(ROOT)+'\n')
    p=reserve(h,'candidate','g-candidate',code=4,env=TMENV)
    assert 'unmanaged pooled supervisor legacy stays counted' in p.stdout
    run(['tmux','-L','fm-lab','kill-window','-t','primary:fm-legacy'],env=TMENV)
    p=reserve(h,'candidate','g-candidate',code=4,env=TMENV)
    assert 'unmanaged pooled supervisor legacy stays counted' in p.stdout
    (h/'state/legacy.meta').unlink()
    reserve(h,'candidate','g-candidate',env=TMENV)

def confirmed():
    h=home('confirmed');policy(h)
    run(['tmux','-L','fm-lab','new-window','-d','-t','primary','-n','fm-confirmed','-c',ROOT,'bash --noprofile --norc'],env=TMENV)
    run(['tmux','-L','fm-lab','send-keys','-t','primary:fm-confirmed','claude','Enter'],env=TMENV)
    prepare(h,'confirmed','g-confirmed','primary:fm-confirmed')
    state=''
    for _ in range(30):
        state=run(['bash','-c','. bin/fm-backend.sh; fm_backend_agent_state tmux primary:fm-confirmed'],h,env=TMENV,log=False).stdout
        if state=='alive':break
        time.sleep(.5)
    LOG.write('real Claude endpoint state='+state+'\n')
    assert state=='alive'
    seats(h,'confirm','confirmed','--generation','g-confirmed',env=TMENV)
    p=run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary:fm-confirmed'],env=TMENV)
    (EVIDENCE/'claude-terminal.txt').write_text(p.stdout)
    seats(h,'reclaim','confirmed','--generation','g-confirmed',code=3,env=TMENV)
    run(['tmux','-L','fm-lab','send-keys','-t','primary:fm-confirmed','C-c','C-c'],env=TMENV)
    # Exit the real foreground CLI only via the private pane, preserving its shell.
    for _ in range(30):
        state=run(['bash','-c','. bin/fm-backend.sh; fm_backend_agent_state tmux primary:fm-confirmed'],h,env=TMENV,log=False).stdout
        if state=='dead':break
        time.sleep(.5)
    LOG.write('after Claude exit state='+state+'\n')
    assert state=='dead'
    seats(h,'reclaim','confirmed','--generation','g-confirmed',env=TMENV)
    assert current(h,'confirmed','g-confirmed')['lifecycle']=='reclaimed'
    reserve(h,'after-death','g-after-death',env=TMENV)

try:
    lab=home('primary')
    SOCKET_DIR=run(['bin/fm-lab-home.sh','tmux-dir',lab]).stdout.strip()
    TMENV={'TMUX_TMPDIR':SOCKET_DIR}
    primary_env=TMENV.copy()
    primary_env.update({'NO_MISTAKES_GATE':'','FM_GATE_REFUSE_BYPASS':''})
    run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',ROOT,'-e','FM_HOME='+str(lab),'bash --noprofile --norc'],env=primary_env)
    sock=run(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path}'],env=TMENV).stdout.strip()
    TMENV['TMUX']=sock+',0,0'
    scenario('No declaration stays uncapped; declared pools refuse unresolved models, raw commands, and invalid policy',defaults)
    scenario('Twelve simultaneous callers across two homes get six seats; replay and same-holder replacement never create a seventh seat',concurrency)
    scenario('Never-dispatched supervisor reservation reclaims inside an owned lifecycle episode and held metadata lock',never_dispatched)
    scenario('Unconfirmed shell-only and missing endpoints retain their seats; replay and prelaunch release refuse',buffered)
    scenario('An unmanaged pooled supervisor stays counted with an actionable diagnostic after shell-only or missing endpoint readings',unmanaged)
    scenario('A real Claude endpoint confirms startup, holds its seat while alive, and releases after confirmed agent death',confirmed)
finally:
    if SOCKET_DIR:
        run(['tmux','-L','fm-lab','kill-server'],env={'TMUX_TMPDIR':SOCKET_DIR},code=None)
        run(['bin/fm-lab-home.sh','teardown',BASE/'primary'])
    run(['rm','-rf',BASE])
    LOG.write('All live lab homes and the private tmux server/socket directory removed.\n');LOG.close()
    (EVIDENCE/'current-fleet-live.json').write_text(json.dumps(RESULTS,indent=2))
print(json.dumps(RESULTS,indent=2))
