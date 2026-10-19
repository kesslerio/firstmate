import os, pathlib, subprocess, tempfile, shutil, json, time, concurrent.futures
root=pathlib.Path.cwd()
lab=pathlib.Path(tempfile.mkdtemp(prefix='.ceiling-live-',dir=root))
children=[]
env=os.environ.copy()
for k in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','TMUX'):
    env.pop(k,None)
env['FM_HOME']=str(lab)
prefix='. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-secondmate-registry-lib.sh"; . "$1/bin/fm-sol-cap-lib.sh"; shift; '
def call(*args, ok=True):
    p=subprocess.run([str(root/'bin/fm-sol-cap-lib.sh'),*map(str,args)],env=env,text=True,capture_output=True,timeout=20)
    print('$ fm-sol-cap-lib.sh '+' '.join(map(str,args)),flush=True)
    print(p.stdout+p.stderr+f'exit={p.returncode}',flush=True)
    if ok: assert p.returncode==0
    return p
def shell(code,*args,ok=True):
    p=subprocess.run(['bash','-c',prefix+code,'live',str(root),*map(str,args)],env=env,text=True,capture_output=True,timeout=20)
    print(p.stdout+p.stderr+f'exit={p.returncode}',flush=True)
    if ok: assert p.returncode==0
    return p
config=lab/'config'; state=lab/'state'; reg=state/'sol-sessions.tsv'
def reset():
    for f in state.iterdir():
        if f.is_dir(): shutil.rmtree(f)
        else: f.unlink()
    (config/'sol-cap').unlink(missing_ok=True)
def rows():
    s=reg.read_text() if reg.exists() else ''
    print('Persisted registry:\n'+s,flush=True)
    return s
def claim(id,model='gpt-6.1-sol',ok=True):
    return call('refuse-claim',id,'ship','codex',model,config,state,ok=ok)
def reserve(id):
    return shell('fm_sol_cap_refuse_and_claim "$1" ship codex gpt-6.1-sol "$FM_HOME/config" "$FM_HOME/state" || { echo "$FM_SOL_CAP_REFUSAL"; exit 1; }; fm_sol_cap_promote "$1" 0 "$FM_HOME/state"; echo "reserved $1"',id,ok=False)
try:
    subprocess.run([str(root/'bin/fm-lab-home.sh'),'create',str(lab)],check=True,env=env)
    (config/'crew-dispatch.json').write_text(json.dumps({'rules':[{'use':[{'model':'gpt-6.1-sol'},{'model':'glm-5'},{'model':'gpt-6-sol'}]}],'default':{'model':'gpt-9.9-sol'}}))
    print('SCENARIO derived Sol models and default ceiling',flush=True)
    assert call('models',config).stdout.strip()=='gpt-6-sol|gpt-6.1-sol|gpt-9.9-sol'
    assert call('ceiling',config).stdout.strip()=='4'
    print('SCENARIO four reservations admit; fifth and same-ID retry refuse',flush=True)
    for i in range(4): assert reserve('worker-'+str(i)).returncode==0
    before=rows()
    assert claim('fifth',ok=False).returncode!=0
    assert claim('worker-0',ok=False).returncode!=0
    assert rows()==before
    print('SCENARIO non-Sol lanes bypass saturated and corrupt ceiling state',flush=True)
    for model in ('glm-5','qwen3','default'): claim(model,model)
    assert rows()==before
    reg.write_text('broken\trow\n'); (config/'sol-cap').write_text('5\n')
    for model in ('glm-5','qwen3'): claim(model,model)
    assert reg.read_text()=='broken\trow\n'
    print('SCENARIO lower-only override and malformed state fail closed',flush=True)
    reset(); (config/'sol-cap').write_text('1\n')
    assert reserve('only').returncode==0
    assert claim('extra',ok=False).returncode!=0
    (config/'sol-cap').write_text('5\n')
    assert claim('invalid',ok=False).returncode!=0
    (config/'sol-cap').unlink(); reg.write_text('broken\trow\n')
    assert claim('malformed',ok=False).returncode!=0
    reset(); old=(config/'crew-dispatch.json').read_text(); (config/'crew-dispatch.json').write_text('{')
    assert claim('bad-config',ok=False).returncode!=0
    claim('glm','glm-5'); (config/'crew-dispatch.json').write_text(old)
    print('SCENARIO simultaneous attempts at last slot allow exactly one',flush=True)
    reset()
    for i in range(3): assert reserve('existing-'+str(i)).returncode==0
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results=list(pool.map(reserve,['racer-a','racer-b']))
    assert sorted(p.returncode for p in results)==[0,1]
    assert len(rows().splitlines())==4
    print('SCENARIO launch-process handoff and proven exit free capacity',flush=True)
    reset(); assert reserve('probe').returncode==0
    p=subprocess.Popen([str(root/'bin/fm-sol-cap-lib.sh'),'run','probe',str(state),'sleep','60'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True); children.append(p)
    for _ in range(50):
        if reg.read_text().strip().split('\t')[-1]==str(p.pid): break
        time.sleep(.1)
    assert reg.read_text().strip().split('\t')[-1]==str(p.pid)
    rows(); p.terminate(); p.wait(timeout=5)
    assert reserve('after-exit').returncode==0
    assert 'probe\t' not in rows()
    print('SCENARIO reported Sol preserves uncertain claim; confirmed non-Sol releases it',flush=True)
    reset(); assert reserve('reuse').returncode==0
    before=rows(); call('record-actual','reuse','gpt-6-sol',state); assert rows()==before
    call('record-actual','reuse','glm-5',state); assert 'reuse\t' not in rows()
    print('SCENARIO stopped and dead positive-PID records bypass held admission lock for GLM/qwen',flush=True)
    reset()
    holder=subprocess.Popen(['bash','-c',prefix+'fm_lock_try_acquire "$FM_HOME/state/.sol-cap.lock" || exit 1; echo ready; exec sleep 60','holder',str(root)],env=env,stdout=subprocess.PIPE,text=True); children.append(holder)
    assert holder.stdout.readline().strip()=='ready'
    dead=subprocess.Popen(['true']); dead.wait()
    for pid in (-1,dead.pid):
        (state/'retry.meta').write_text('model=gpt-6.1-sol\n')
        reg.write_text(f'retry\tgpt-6.1-sol\t{int(time.time())}\t{pid}\n')
        before=rows()
        start=time.monotonic()
        for model in ('glm-5','qwen3'):
            call('record-actual','retry',model,state)
            claim('fresh-'+model,model)
        assert time.monotonic()-start<5
        assert rows()==before
    holder.terminate(); holder.wait(timeout=5)
    print('ALL LIVE ADMISSION SCENARIOS PASSED',flush=True)
finally:
    for p in children:
        if p.poll() is None: p.terminate(); p.wait(timeout=5)
    shutil.rmtree(lab)
    print('Disposable lab removed; owned probe processes stopped',flush=True)
