import os,pathlib,subprocess,time,signal,json,shutil
R=pathlib.Path.cwd();E=pathlib.Path('/home/art/.no-mistakes/evidence/01M4B0WCFKS0F03ZZ5EPCCQ72P'); transcript=[]
for mode in ('empty','held'):
    home=R/'.test-tmp'/('live-'+mode);home.mkdir(exist_ok=True)
    
    if not (home/'.fm-lab-home').exists(): subprocess.run(['bin/fm-lab-home.sh','create',str(home)],check=True,capture_output=True)
    shutil.copyfile(R/'.tasks.toml',home/'.tasks.toml');(home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    env=os.environ.copy()
    for k in list(env):
        if k.startswith('FM_') or k in ('NO_MISTAKES_GATE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','HERDR_SESSION','HERDR_ENV','HERDR_PANE_ID'):env.pop(k,None)
    env.update(FM_HOME=str(home),FM_BACKEND='tmux',TMUX=str(R/('.lab/tmux/tmux-'+str(os.getuid())+'/fm-lab'))+',0,0',FM_POLL='0.2',FM_HEARTBEAT='1',FM_CHECK_INTERVAL='999999',TMPDIR=str(R/'.test-tmp'))
    def cmd(args):
        p=subprocess.run(args,env=env,cwd=R,text=True,capture_output=True);assert p.returncode==0,p.stderr;transcript.append('$ '+' '.join(args)+'\n'+p.stdout+p.stderr)
    if mode=='held':
        cmd(['bin/fm-tasks-axi.sh','add','held','credential waiting for captain'])
        cmd(['bin/fm-captain-hold.sh','hold','held','--reason','credential required; explicit hold'])
    cmd(['bin/fm-tasks-axi.sh','ready'])
    p=subprocess.Popen(['bin/fm-watch.sh'],env=env,cwd=R,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
    try:
        deadline=time.time()+20
        while time.time()<deadline:
            streak=home/'state/.heartbeat-streak'
            if streak.exists() and int(streak.read_text())>=1:break
            time.sleep(.2)
        else:raise RuntimeError('watcher did not review queue')
    finally:
        os.killpg(p.pid,signal.SIGTERM)
        try:out,err=p.communicate(timeout=5)
        except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);out,err=p.communicate()
    queue=home/'state/.wake-queue';assert not out and (not queue.exists() or not queue.read_text())
    transcript.append(f'{mode}: watcher heartbeat reviewed queue; streak={streak.read_text().strip()}; stdout={out!r}; wake_queue_empty=True\n')
    shutil.rmtree(home)
(E/'quiet-queues.txt').write_text('\n'.join(transcript));print('Real watcher empty and captain-held queues remained silent after heartbeat review.')
