import os, pathlib, subprocess, tempfile, shutil
root = pathlib.Path.cwd()
lab = pathlib.Path(tempfile.mkdtemp(prefix='lab-', dir=root / '.test-capacity-tmp'))
env = os.environ.copy()
for key in list(env):
    if (key.startswith('FM_') and key.endswith('_OVERRIDE')) or key in ('FM_GATE_REFUSE_BYPASS', 'TMUX', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_SESSION', 'HERDR_SOCKET_PATH'):
        env.pop(key, None)
env.update(FM_HOME=str(lab), FM_BACKEND='tmux', FM_SPAWN_NO_GUARD='1')
def run(args):
    return subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
def probe(name, expected):
    p = run(['bin/fm-spawn.sh', 'candidate', str(project), '--mode', 'local-only', '--yolo', 'off', '--harness', 'codex'])
    print('\nSCENARIO:', name, flush=True)
    print(p.stdout, end='', flush=True)
    print('exit:', p.returncode, flush=True)
    if expected == 'deferred':
        assert p.returncode == 75 and '1 already hold a place (holder)' in p.stdout
    else:
        assert p.returncode == 1 and 'has no brief at inaccessible data path' in p.stdout
        assert 'deferred:' not in p.stdout
    assert not (lab/'state/candidate.meta').exists()
    assert not (lab/'data/candidate/launch-brief.md').exists()
    print('Observed: ' + ('capacity retained; candidate deferred without a record' if expected == 'deferred' else 'capacity released; candidate reached subsequent brief validation'), flush=True)
def meta(kind, mode, pr=False):
    (lab/'state/holder.meta').write_text(f'kind={kind}\nmode={mode}\nproject={project}\nharness=codex\n' + ('pr=123\n' if pr else ''))
status = lab/'state/holder.status'
try:
    p=run(['bin/fm-lab-home.sh', 'create', str(lab)])
    assert p.returncode == 0, p.stdout
    project = lab/'projects/project'
    project.mkdir()
    assert run(['git','-C',str(project),'init','-q']).returncode == 0
    assert run(['git','-C',str(project),'remote','add','origin',str(lab/'origin.git')]).returncode == 0
    (lab/'config/project-capacity').write_text('project 1\n')
    for kind, mode in [('ship','no-mistakes'), ('ship','direct-PR'), ('ship','local-only'), ('scout','no-mistakes')]:
        meta(kind,mode)
        status.write_text('paused [at=1791700000]: waiting\n')
        probe(f'{kind}/{mode}: paused before completion', 'deferred')
        with status.open('a') as f: f.write('working [at=1791700100]: resumed\ndone [at=1791700200]: finished\n')
        if kind == 'ship' and mode != 'local-only':
            probe(f'{mode}: done before PR handoff', 'deferred')
            meta(kind,mode,True)
            probe(f'{mode}: recorded PR handoff', 'admitted')
            continue
        probe(f'{kind}/{mode}: done frees capacity', 'admitted')
        for verb in ['captain-held','resolved','needs-decision','paused','blocked']:
            with status.open('a') as f: f.write(f'{verb} [at=1791700250]: bookkeeping\n')
            probe(f'{kind}/{mode}: done then {verb}', 'admitted')
        with status.open('a') as f: f.write('working [at=1791700300]: resumed\n')
        probe(f'{kind}/{mode}: later working restores occupancy', 'deferred')
        with status.open('a') as f: f.write('done: completed again')
        probe(f'{kind}/{mode}: newest done releases again without trailing newline', 'admitted')
finally:
    shutil.rmtree(lab)
    print('\nDisposable lab removed.', flush=True)
