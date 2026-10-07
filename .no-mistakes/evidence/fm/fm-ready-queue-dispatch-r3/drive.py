import os, pathlib, subprocess, time, signal, json
ROOT=pathlib.Path.cwd(); E=pathlib.Path('/home/art/.no-mistakes/evidence/01M4B0WCFKS0F03ZZ5EPCCQ72P'); LAB=ROOT/'.lab'
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('NO_MISTAKES_GATE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','HERDR_SESSION','HERDR_ENV','HERDR_PANE_ID','TMUX','TMUX_PANE'): env.pop(k,None)
env.update(FM_HOME=str(LAB),TMPDIR=str(ROOT/'.test-tmp'),TMUX_TMPDIR=str(LAB/'tmux'),FM_BACKEND='tmux')
def run(args, check=True, **kwargs):
    p=subprocess.run(args,cwd=ROOT,env=env,text=True,capture_output=True,**kwargs)
    if check and p.returncode: raise RuntimeError(f'{args}: {p.returncode}: {p.stderr}')
    return p
socket=run(['tmux','-L','fm-lab','display-message','-p','#{socket_path}']).stdout.strip(); env['TMUX']=socket+',0,0'
(LAB/'.tasks.toml').write_text((ROOT/'.tasks.toml').read_text()); (LAB/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
log=[]
def cmd(*args,check=True):
    p=run([str(ROOT/'bin'/args[0]),*args[1:]],check=check); log.append('$ '+' '.join(args)+'\n'+p.stdout+p.stderr);return p
cmd('fm-tasks-axi.sh','add','next','beyond earlier capacity: next unit')
cmd('fm-tasks-axi.sh','add','dependency','landed dependency')
cmd('fm-tasks-axi.sh','block','next','--by','dependency')
cmd('fm-tasks-axi.sh','done','dependency','--pr','https://github.com/example/lab/pull/1')
cmd('fm-tasks-axi.sh','update','next','--body','Previously handed off; no live worker exists. Earlier capacity stop has cleared.')
cmd('fm-tasks-axi.sh','add','held','design choice waiting for captain')
cmd('fm-captain-hold.sh','hold','held','--reason','explicit design pick')
cmd('fm-tasks-axi.sh','add','paused','sibling waiting for review')
cmd('fm-tasks-axi.sh','block','paused','--by','held')
cmd('fm-tasks-axi.sh','ready')
# Run the full daemon and watcher with the real private tmux backend. Batch long
# enough to inspect persisted handoff without unsolicited model dispatch.
(LAB/'state/.afk').write_text('mode: quiet\n')
den=env.copy(); den.update(FM_SUPERVISOR_TARGET='primary',FM_SUPERVISOR_BACKEND='tmux',FM_POLL='0.2',FM_HEARTBEAT='1',FM_CHECK_INTERVAL='999999',FM_ESCALATE_BATCH_SECS='3600',FM_HOUSEKEEPING_TICK='3600',FM_WEDGE_ALARM_EXEC='discard')
f=(E/'daemon-output.log').open('w'); p=subprocess.Popen([str(ROOT/'bin/fm-supervise-daemon.sh')],cwd=ROOT,env=den,stdout=f,stderr=f,start_new_session=True)
try:
    deadline=time.time()+25
    while time.time()<deadline:
        q=LAB/'state/.subsuper-escalations'
        if q.exists() and 'ready-queue fleet check:' in q.read_text(): break
        if p.poll() is not None: raise RuntimeError('daemon exited')
        time.sleep(.2)
    else: raise RuntimeError('no durable ready-work handoff')
    (E/'daemon-handoff.txt').write_text('Real daemon, real private tmux, no status events.\n'+q.read_text()+'\nDaemon log:\n'+(LAB/'state/.supervise-daemon.log').read_text()+'\nWake queue:\n'+(LAB/'state/.wake-queue').read_text())
finally:
    # Prevent the shutdown flush from injecting the captured test handoff.
    run(['tmux','-L','fm-lab','kill-session','-t','primary'])
    os.killpg(p.pid,signal.SIGTERM)
    try:p.wait(timeout=8)
    except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
    f.close()
(LAB/'state/.afk').unlink()
# The host's real public drain needs its explicit opt-in, no harness shim.
(LAB/'config/supervision-host').touch()
summary='ready-work handoff: dispatch unit-first; '+'x'*4500+'; dispatch unit-last; dependency landed'
cmd('fm-branch-outcome.sh','append','--task','source','--verdict','captain','--summary',summary)
cmd('fm-branch-outcome.sh','append','--task','source','--verdict','captain','--summary','source finished; no new handoff')
a=cmd('fm-branch-outcome.sh','mark-processed','--through','1',check=False); assert a.returncode!=0
first=cmd('fm-wake-drain.sh'); assert summary in first.stdout and 'source: source finished' not in first.stdout
(E/'long-handoff-drain.txt').write_text(first.stdout+first.stderr)
replay=cmd('fm-wake-drain.sh'); assert summary in replay.stdout
cmd('fm-branch-outcome.sh','mark-processed','--through','1')
second=cmd('fm-wake-drain.sh');assert 'source: source finished' in second.stdout and 'dispatch unit-last' not in second.stdout
cmd('fm-branch-outcome.sh','mark-processed','--through','2')
# Two same-task rows inside the normal cap remain separately visible.
cmd('fm-branch-outcome.sh','append','--task','source','--verdict','captain','--summary','ready-work handoff: dispatch next')
cmd('fm-branch-outcome.sh','append','--task','source','--verdict','captain','--summary','source finished again; no new handoff')
both=cmd('fm-wake-drain.sh'); assert 'dispatch next' in both.stdout and 'source finished again' in both.stdout
(E/'older-handoff-drain.txt').write_text(both.stdout+both.stderr)
(E/'public-cli-transcript.txt').write_text('\n'.join(log))
print('Real daemon readiness handoff and real public drain replay/acknowledgement scenarios passed.')
