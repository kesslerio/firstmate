import hashlib, io, json, os, pathlib, shlex, shutil, subprocess, tarfile, time
ROOT = pathlib.Path.cwd()
EV = pathlib.Path('/Users/kesslerio/.no-mistakes/evidence/01M4C86PSDNBECPTMSZ1YVFF8Q')
BASE = ROOT / '.test-current-mama'
BASE.mkdir(mode=0o700)
LOG = (EV / 'current-remote-mama-recheck.log').open('w')
REPORT = {'head_sha': subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip(), 'scenarios': [], 'hosts': [], 'verdict': 'inconclusive', 'tested_committed_head': True}
SSH = ['ssh','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','UpdateHostKeys=no','-o','ConnectTimeout=8','-o','ForwardAgent=no']
ENV = os.environ.copy()
for key in list(ENV):
    if key.startswith('FM_') or key in ('TMUX','HERDR_SESSION','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
        ENV.pop(key, None)
ENV['TMPDIR'] = str(BASE)
manager = None
scratch = None
host = 'mama'

def run(args, data=None, timeout=60, env=None, expected=None):
    p = subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=isinstance(data,str) or data is None, timeout=timeout, cwd=ROOT, env=env or ENV)
    output = p.stdout if isinstance(p.stdout,str) else p.stdout.decode()
    LOG.write('$ ' + shlex.join(args) + '\n' + output + '\nexit=' + str(p.returncode) + '\n'); LOG.flush()
    if expected is not None: assert p.returncode == expected, output
    return p.returncode, output

def remote(script, expected=None, timeout=60):
    return run(SSH + [host, 'bash -s'], script, expected=expected, timeout=timeout)

try:
    # Copy unchanged current bytes, including the one authorized worktree fix.
    paths = subprocess.check_output(['git','ls-files','bin','AGENTS.md','.agents/skills','.tasks.toml','.pi','docs','README.md','.claude'], text=True).splitlines()
    REPORT['source_hashes'] = {p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths if (ROOT/p).is_file()}
    rc, out = remote('umask 077\nmktemp -d /tmp/fm6238-current.XXXXXX\n', expected=0)
    scratch = out.strip()
    assert scratch.startswith('/tmp/fm6238-current.') and '\n' not in scratch
    REPORT['remote_scratch'] = scratch
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive,mode='w') as tar:
        for path in paths:
            tar.add(ROOT/path,arcname=path,recursive=False)
    run(SSH + [host, shlex.join(['bash','-c','mkdir "$1/code" && tar -xf - -C "$1/code"','_',scratch])], archive.getvalue(), expected=0)
    code = scratch + '/code'; home = scratch + '/home'
    helper = code + '/bin/fm-herdr-lab.sh'
    rc, out = remote(shlex.join([helper,'name','6238-current'])+'\n', expected=0)
    session = out.strip()
    REPORT['session'] = session
    # Install a combined cleanup BEFORE home creation or Herdr provisioning.
    script = '''set -u
S=%s
C="$S/code"
H="$S/home"
SESSION=%s
export FM_HERDR_LAB_STATE_DIR="$S/lab-state" TMPDIR="$S" FM_REMOTE_JOB_STATE_ROOT="$S/jobs"
cleanup() {
  local rc=0
  if [ -f "$S/jobs/worker.pid" ]; then
    . "$C/bin/fm-remote-job-lib.sh"
    fm_remote_job_stop_worker_tree "$(cat "$S/jobs/worker.pid")" || rc=1
  fi
  if [ -f "$H/.fm-lab-home" ]; then "$C/bin/fm-lab-home.sh" teardown "$H" || rc=1; fi
  if [ -f "$S/lab-state/$SESSION.fleet-state.json" ]; then
    "$C/bin/fm-herdr-lab.sh" teardown "$SESSION" || rc=1
  fi
  "$C/bin/fm-herdr-lab.sh" run "$SESSION" session list --json
  if [ "$rc" = 0 ]; then rm -rf -- "$S"; echo CLEANUP_OK; else echo CLEANUP_FAILED; fi
}
trap cleanup EXIT
"$C/bin/fm-lab-home.sh" create "$H" || exit 1
"$C/bin/fm-lab-home.sh" create "$S/parent" || exit 1
"$C/bin/fm-lab-home.sh" create "$S/neighbor" || exit 1
"$C/bin/fm-herdr-lab.sh" run "$SESSION" session list --json
"$C/bin/fm-herdr-lab.sh" provision "$SESSION" || { echo PROVISION_REFUSED; exit 1; }
echo LAB_READY
for ((i=0;i<600;i++)); do [ ! -e "$S/done" ] || exit 0; sleep 1; done
echo LAB_TIMEOUT
exit 1
''' % (shlex.quote(scratch),shlex.quote(session))
    manager = subprocess.Popen(SSH + [host,'bash -s'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=ENV)
    manager.stdin.write(script); manager.stdin.close()
    lines = []
    while True:
        line = manager.stdout.readline()
        if not line: break
        LOG.write(line); LOG.flush(); lines.append(line)
        if 'LAB_READY' in line: break
    REPORT['provisioning'] = ''.join(lines)
    if not any('LAB_READY' in l for l in lines):
        manager.wait(timeout=90)
        REPORT['blocker'] = {'file':'bin/fm-herdr-lab.sh','line':110,'diagnostic':''.join(lines)}
        raise RuntimeError('Helper provisioning refused; lifecycle success paths remain unproven')
    REPORT['hosts'].append({'host':host,'provisioned':True,'scratch':scratch,'session':session})
    # Initialize only synthetic disposable code/home records. No real fleet data.
    task = 'lab6238'
    remote('set -e\n' + '\n'.join([
        shlex.join(['git','-C',code,'init','-q']),
        shlex.join(['git','-C',code,'add','bin','AGENTS.md','.pi','.claude','docs']),
        shlex.join(['cp','-a',code+'/bin',home+'/bin']),
        shlex.join(['cp',code+'/AGENTS.md',home+'/AGENTS.md']),
        shlex.join(['cp','-a',code+'/.pi',home+'/.pi']),
        shlex.join(['cp','-a',code+'/.claude',home+'/.claude']),
        shlex.join(['cp','-a',code+'/docs',home+'/docs']),
        shlex.join(['git','-C',home,'init','-q']),
        shlex.join(['git','-C',home,'add','bin','AGENTS.md','.pi','.claude','docs']),
        shlex.join(['git','-C',home,'-c','user.name=Lab','-c','user.email=lab@example.invalid','-c','core.hooksPath=/dev/null','commit','-qm','Synthetic lab fixture']),
        shlex.join(['python3','-c','import pathlib,sys; (pathlib.Path(sys.argv[1])/"data/charter.md").write_text("# Lab charter: Remain idle. Do not mutate any fleet, project, or user files; this disposable home exists only for lifecycle validation.")',home]),
        shlex.join(['bash','-c','printf "%s\\n" "$1" > "$2/.fm-secondmate-home"','_',task,home]),
    ]) + '\n', expected=0)
    # The product's real remote queue is isolated under the disposable lab.
    wrapper = BASE/'ssh-wrapper'
    wrapper.write_text('#!/usr/bin/env python3\nimport os,shlex,sys\na=sys.argv[1:]\nwhile a[0]=="-o": a=a[2:]\nassert a.pop(0)=="--"\nh=a.pop(0)\nassert h=="mama" and a.pop(0)=="fm-remote-entrypoint.sh"\ncmd='+repr(['env','FM_REMOTE_JOB_STATE_ROOT='+scratch+'/jobs','TMPDIR='+scratch,code+'/bin/fm-remote-entrypoint.sh'])+'+a\nos.execvp("ssh",'+repr(SSH)+'+[h,shlex.join(cmd)])\n')
    wrapper.chmod(0o700)
    parent=BASE/'parent'
    run(['bash','bin/fm-lab-home.sh','create',str(parent)], expected=0)
    (parent/'data/secondmates.md').write_text(f'- {task} - Synthetic lab (host: mama; root: {code}; home: {home}; scope: test; projects: none; added 2026-10-07)\n')
    e=ENV.copy(); e.update(FM_HOME=str(parent),FM_SSH_BIN=str(wrapper))
    def control(*args,expected=0):
        return run(['bash','bin/fm-on.sh',task,'fm-remote-secondmate-control.sh',*args,'--herdr-session',session],env=e,expected=expected,timeout=180)[1]
    # Route-only compatibility checks read synthetic persisted output without
    # accessing a shared session or endpoint.
    route_fixture='window=fm-remote:w999:p999\nbackend=herdr\nendpoint_task_id=lab6238\nherdr_session=fm-remote\nherdr_workspace_id=w999\nherdr_tab_id=w999:t999\nherdr_pane_id=w999:p999\nworktree='+home+'\nproject='+code+'\nhome='+home+'\nharness=pi\nkind=secondmate\nmode=secondmate\nspawn_gen=synthetic.g0\n'
    remote(shlex.join(['python3','-c','import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.parent.mkdir(parents=True,exist_ok=True); p.write_text(sys.argv[2])',home+'/state/parent-route/'+task+'.meta',route_fixture])+'\n',expected=0)
    ordinary=run(['bash','bin/fm-on.sh',task,'fm-remote-secondmate-control.sh','route',task],env=e,expected=0)[1]
    assert 'herdr_session=fm-remote' in ordinary
    control('route',task,expected=1)
    remote(shlex.join(['rm',home+'/state/parent-route/'+task+'.meta'])+'\n',expected=0)
    launch = control('launch',task,'pi','-','-','herdr')
    route = dict(line.split('=',1) for line in launch.splitlines() if '=' in line and line.split('=',1)[0] in ['spawn_gen','harness','model','effort','target'])
    gen = route['spawn_gen']
    time.sleep(4)
    launch_capture=control('capture',task,'60')
    (EV/'current-remote-mama-launch.txt').write_text(launch_capture)
    assert 'Error: Failed to load extension' not in launch_capture, launch_capture
    meta=parent/'state'/f'{task}.meta'
    meta.write_text('\n'.join(['window=remote:'+task,'endpoint_task_id='+task,'harness=pi','kind=secondmate','mode=secondmate','remote_host=mama','remote_root='+code,'home='+home,'remote_backend=herdr','remote_herdr_session='+session,'remote_target='+route['target'],'remote_spawn_gen='+gen])+'\n')
    # Observable persisted-state inventories establish denied-path nonmutation.
    inventory_script=shlex.join(['python3','-c','import hashlib,json,pathlib,sys; h=pathlib.Path(sys.argv[1]); print(json.dumps({str(p.relative_to(h)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (h/"state/parent-route").glob("*") if p.is_file()},sort_keys=True))',home])+'\n'
    before=remote(inventory_script,expected=0)[1]
    run(['bash','bin/fm-remote-secondmate-relaunch.sh',task,'pi','-','-','--expect-generation','stale.gen'],env=e,expected=6)
    control('relaunch',task,'pi','-','-','--expect-generation','stale.gen',expected=6)
    assert before==remote(inventory_script,expected=0)[1]
    REPORT['scenarios'].append({'name':'stale-generation refusal at parent and SSH host','result':'pass'})
    run(['bash','bin/fm-remote-secondmate-relaunch.sh',task,'pi','-','-','--expect-generation',gen],env=e,expected=0,timeout=180)
    time.sleep(4)
    captured=control('capture',task,'60')
    assert 'Error: Failed to load extension' not in captured, captured
    (EV/'current-remote-mama-terminal.txt').write_text(captured)
    after_route=control('route',task)
    newgen=dict(l.split('=',1) for l in after_route.splitlines() if '=' in l)['spawn_gen']
    assert newgen!=gen and 'remote_spawn_gen='+newgen in meta.read_text()
    REPORT['scenarios'].append({'name':'replace supervisor and publish confirmed generation','result':'pass','previous':gen,'confirmed':newgen})
    before=remote(inventory_script,expected=0)[1]
    for invalid in ['default','fm-remote','fm-lab-bad.name']:
        run(['bash','bin/fm-on.sh',task,'fm-remote-secondmate-control.sh','retire',task,'--herdr-session',invalid],env=e,expected=1)
    assert before==remote(inventory_script,expected=0)[1]
    REPORT['scenarios'].append({'name':'named and ordinary routes, unsafe session refusal','result':'pass'})
    state=home+'/state/parent-route'
    remote(shlex.join(['python3','-c','import pathlib,sys; s=pathlib.Path(sys.argv[1]); [(s/n).write_text(n) for n in sys.argv[2:]]',state,task+'.seat-operation.synthetic',task+'.seat-reservation.synthetic',task+'.seat-operation.synthetic-old',task+'.seat-reservation.synthetic-old'])+'\n',expected=0)
    neighbor=scratch+'/neighbor/state/parent-route'
    remote(shlex.join(['python3','-c','import pathlib,sys; s=pathlib.Path(sys.argv[1]); s.mkdir(parents=True,exist_ok=True); [(s/n).write_text(n) for n in sys.argv[2:]]',neighbor,'neighbor.seat-operation.synthetic','neighbor.seat-reservation.synthetic'])+'\n',expected=0)
    control('retire',task)
    remote(shlex.join(['python3','-c','import pathlib,sys; s=pathlib.Path(sys.argv[1]); assert not pathlib.Path(sys.argv[2]).exists(); assert (s/"neighbor.seat-operation.synthetic").read_text()=="neighbor.seat-operation.synthetic"; assert (s/"neighbor.seat-reservation.synthetic").read_text()=="neighbor.seat-reservation.synthetic"',neighbor,home])+'\n',expected=0)
    REPORT['scenarios'].append({'name':'retire supervisor and clean only owned operation files','result':'pass'})
    REPORT['verdict']='pass'
except Exception as exc:
    REPORT['error']=repr(exc)
finally:
    if manager and manager.poll() is None and scratch:
        remote('touch '+shlex.quote(scratch+'/done')+'\n')
    if manager:
        tail=manager.stdout.read(); LOG.write(tail); LOG.flush()
        manager.wait(timeout=90)
        REPORT['cleanup_output']=tail
        REPORT['manager_exit']=manager.returncode
    if scratch:
        rc,out=remote('test ! -e '+shlex.quote(scratch)+'\n')
        REPORT['remote_fixture_removed']=rc==0
    shutil.rmtree(BASE)
    REPORT['local_fixture_removed']=not BASE.exists()
    (EV/'current-remote-mama-recheck.json').write_text(json.dumps(REPORT,indent=2)+'\n')
    LOG.close()
print(json.dumps({k:v for k,v in REPORT.items() if k!='source_hashes'},indent=2))
