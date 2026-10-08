import hashlib, json, os, pathlib, pwd, shlex, shutil, signal, socket, subprocess
ROOT = pathlib.Path.cwd()
EV = pathlib.Path('/Users/kesslerio/.no-mistakes/evidence/01M4C86PSDNBECPTMSZ1YVFF8Q')
BASE = ROOT / '.test-herdr-round3'
BASE.mkdir(mode=0o700)
ENV = os.environ.copy()
for key in list(ENV):
    if key.startswith('FM_') or key in ('TMUX', 'HERDR_ENV', 'HERDR_SESSION', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'):
        ENV.pop(key, None)
ENV.update(TMPDIR=str(BASE), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', FM_HERDR_LAB_STATE_DIR=str(BASE / 'herdr-lab-state'))
LOG = (EV / 'live-herdr-round3.log').open('w')
P = None
JOBS = BASE / 'jobs'
report = {'tested_head_sha': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(), 'verdict': 'inconclusive', 'live_lifecycle_executed': False, 'checks': []}
def run(args, home=None, expected=0):
    env = ENV.copy()
    if home: env['FM_HOME'] = str(home)
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=env, text=True, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    LOG.write('$ ' + (('FM_HOME=' + str(home) + ' ') if home else '') + shlex.join([str(a) for a in args]) + '\n' + p.stdout + 'exit=' + str(p.returncode) + '\n')
    LOG.flush()
    if expected is not None: assert p.returncode == expected, (p.returncode, p.stdout)
    return p

def inventory(home):
    return {str(p.relative_to(home)): hashlib.sha256(p.read_bytes()).hexdigest() for p in home.rglob('*') if p.is_file()}
try:
    # No Herdr session is provisioned: first reproduce the controller's metadata refusal.
    parent, remote, code = (BASE / n for n in ('parent', 'remote-home', 'remote-code'))
    for home in (parent, remote): run(['bin/fm-lab-home.sh', 'create', home])
    code.mkdir()
    archive = subprocess.Popen(['git', 'archive', 'HEAD'], cwd=ROOT, env=ENV, stdout=subprocess.PIPE)
    tar = subprocess.run(['tar', '-x', '-C', str(code)], stdin=archive.stdout, env=ENV)
    archive.stdout.close()
    assert archive.wait() == 0 and tar.returncode == 0
    run(['git', '-C', code, 'init', '-q'])
    run(['git', '-C', code, 'add', 'bin', 'AGENTS.md'])
    task = 'herdr-round3'
    session = run(['bin/fm-herdr-lab.sh', 'name', task]).stdout.strip()
    report.update(task=task, lab_session=session, ownership={'fixture_root': str(BASE), 'homes': [str(parent), str(remote)], 'session_provisioned': False, 'synthetic_registration': True})
    (remote / '.fm-secondmate-home').write_text(task + '\n')
    shutil.copyfile(ROOT / 'AGENTS.md', remote / 'AGENTS.md')
    (remote / 'bin').mkdir()
    state = remote / 'state/parent-route'
    state.mkdir()
    meta = state / (task + '.meta')
    meta.write_text('\n'.join(['window=' + session + ':w1:p1', 'backend=herdr', 'endpoint_task_id=' + task, 'herdr_session=' + session, 'herdr_workspace_id=w1', 'herdr_tab_id=w1:t1', 'herdr_pane_id=w1:p1', 'worktree=' + str(remote), 'project=' + str(code), 'home=' + str(remote), 'harness=claude', 'kind=secondmate', 'mode=secondmate', 'yolo=off', 'spawn_gen=synthetic.g0']) + '\n')
    out = run(['bin/fm-remote-secondmate-control.sh', 'relaunch', task, 'claude', '-', '-', '--expect-generation', 'synthetic.g0'], remote, expected=1)
    assert "expected 'fm-remote'" in out.stdout and session in out.stdout
    report['checks'].append('Reproduced the lab-session refusal before endpoint access through the real controller')
    # Real SSH transport, with a private daemon and all worker data inside the worktree.
    auth = BASE / 'ssh'; auth.mkdir(mode=0o700)
    user = pwd.getpwuid(os.getuid()).pw_name
    sock = socket.socket(); sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]; sock.close()
    for key in ('host', 'identity'): run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', auth / key])
    (auth / 'authorized_keys').write_text((auth / 'identity.pub').read_text()); (auth / 'authorized_keys').chmod(0o600)
    force = BASE / 'forced-command.py'
    force.write_text('import os,shlex\na=shlex.split(os.environ.get("SSH_ORIGINAL_COMMAND",""))\nassert a and a[0]=="fm-remote-entrypoint.sh"\ne=os.environ.copy()\ne["FM_REMOTE_JOB_PLATFORM_OVERRIDE"]="Linux"\ne["FM_REMOTE_JOB_STATE_ROOT"]=' + repr(str(JOBS)) + '\ne["TMPDIR"]=' + repr(str(BASE)) + '\nos.execve(' + repr(str(code / 'bin/fm-remote-entrypoint.sh')) + ',a,e)\n')
    conf = auth / 'sshd_config'
    conf.write_text(f'Port {port}\nListenAddress 127.0.0.1\nHostKey {auth}/host\nPidFile {auth}/sshd.pid\nAuthorizedKeysFile {auth}/authorized_keys\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nStrictModes no\nAllowUsers {user}\nLogLevel ERROR\nForceCommand ' + shlex.join([shutil.which('python3'), str(force)]) + '\n')
    serverlog = (EV / 'live-herdr-round3-sshd.log').open('w')
    P = subprocess.Popen([shutil.which('sshd'), '-D', '-e', '-f', str(conf)], stdout=serverlog, stderr=serverlog, start_new_session=True)
    wrapper = BASE / 'ssh-wrapper'
    wrapper.write_text('#!/bin/sh\nexec ' + shlex.join(['ssh', '-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'UserKnownHostsFile=' + str(auth / 'known_hosts'), '-p', str(port), '-i', str(auth / 'identity'), '-l', user]) + ' "$@"\n')
    wrapper.chmod(0o700); ENV['FM_SSH_BIN'] = str(wrapper)
    (parent / 'data/secondmates.md').write_text(f'- {task} - Synthetic Herdr test. (host: 127.0.0.1; root: {code}; home: {remote}; scope: tests; projects: ; added 2026-10-07)\n')
    (parent / 'state' / (task + '.meta')).write_text('\n'.join(['window=remote:' + task, 'endpoint_task_id=' + task, 'worktree=' + str(remote), 'project=' + str(code), 'home=' + str(remote), 'harness=claude', 'kind=secondmate', 'mode=secondmate', 'yolo=off', 'remote_host=127.0.0.1', 'remote_root=' + str(code), 'remote_backend=herdr', 'remote_herdr_session=' + session, 'remote_target=' + session + ':w1:p1', 'remote_spawn_gen=synthetic.g0']) + '\n')
    run(['bin/fm-on.sh', task, 'fm-remote-secondmate-control.sh', 'state', task], parent)
    before = run(['bin/fm-herdr-lab.sh', 'run', session, 'session', 'list', '--json'], expected=None)
    report['default_session_observation_before'] = before.stdout
    baseline = inventory(remote)
    # Stale request denial is testable without calling a Herdr endpoint.
    for args in (['bin/fm-remote-secondmate-relaunch.sh', task, 'claude', '-', '-', '--expect-generation', 'synthetic.stale'], ['bin/fm-on.sh', task, 'fm-remote-secondmate-control.sh', 'relaunch', task, 'claude', '-', '-', '--expect-generation', 'synthetic.stale']):
        p = run(args, parent, expected=6)
        assert 'generation-mismatch' in p.stdout
    assert baseline == inventory(remote)
    report['checks'].append('Parent and host stale-generation requests refuse with exit 6 and preserve synthetic remote files')
    p = run(['bin/fm-remote-secondmate-relaunch.sh', task, 'claude', '-', '-', '--expect-generation', 'synthetic.g0'], parent, expected=1)
    assert "expected 'fm-remote'" in p.stdout
    assert baseline == inventory(remote)
    report['replacement'] = {'result': 'untested', 'reason': 'The real parent wrapper and SSH worker reach host control, but a matching-generation synthetic fm-lab-* route refuses before replacement because remote control requires fm-remote. Provisioning fm-remote or translating the endpoint would violate the required lab isolation or change the tested source behavior.'}
    # Seat-operation files are explicit synthetic persisted-state contracts.
    for filename in (task + '.seat-operation.synthetic.g0', task + '.seat-reservation.synthetic.g0', 'other-task.seat-operation.synthetic.g1', 'other-task.seat-reservation.synthetic.g1'):
        (state / filename).write_text('synthetic retained operation file: ' + filename + '\n')
    baseline = inventory(remote)
    p = run(['bin/fm-on.sh', task, 'fm-remote-secondmate-control.sh', 'retire', task], parent, expected=1)
    assert "expected 'fm-remote'" in p.stdout
    assert baseline == inventory(remote)
    report['retirement'] = {'result': 'untested', 'reason': 'The real SSH retirement interface rejects the fm-lab-* route before teardown; all synthetic task and neighboring operation files remain unchanged. Successful live retirement and selective cleanup cannot be claimed.'}
    for args in (['bin/fm-herdr-lab.sh', 'provision', 'fm-remote'], ['bin/fm-herdr-lab.sh', 'stop', 'default'], ['bin/fm-herdr-lab.sh', 'run', session, 'server', 'stop']):
        run(args, expected=1)
    after = run(['bin/fm-herdr-lab.sh', 'run', session, 'session', 'list', '--json'], expected=None)
    report['default_session_observation_after'] = after.stdout
    assert before.returncode == after.returncode and before.stdout == after.stdout
    def default_snapshot(observation):
        try: return [s for s in json.loads(observation)['sessions'] if s.get('default')]
        except (json.JSONDecodeError, KeyError, TypeError): return None
    defaults = default_snapshot(before.stdout)
    report['default_session_tripwire'] = {'observations_identical': True, 'running_default_proven': bool(defaults and len(defaults) == 1 and defaults[0].get('running')), 'snapshot': defaults, 'session_provisioned': False}
    report['checks'].append('Helper refuses fm-remote provisioning, literal-default stop, and server-global operations before executing them; before/after session observations identical')
except Exception as exc:
    report['driver_error'] = repr(exc)
    LOG.write('DRIVER ERROR: ' + repr(exc) + '\n'); LOG.flush()
finally:
    if (JOBS / 'worker.pid').exists():
        run(['bash', '-c', '. bin/fm-remote-job-lib.sh; fm_remote_job_stop_worker_tree "$(cat "$1")"', '_', JOBS / 'worker.pid'], expected=None)
    if P:
        try: os.killpg(P.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        P.wait(timeout=10)
    shutil.rmtree(BASE)
    report['cleanup'] = {'fixture_tree_removed': not BASE.exists(), 'ssh_daemon_stopped': not P or P.poll() is not None, 'herdr_sessions_created': 0, 'real_secondmates_changed': False, 'source_changes': False}
    LOG.write('Cleanup: private SSH daemon and worker stopped; synthetic homes, copied code, keys, and worker state removed. No Herdr session provisioned or lifecycle executed.\n'); LOG.close()
    (EV / 'live-herdr-round3-results.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
