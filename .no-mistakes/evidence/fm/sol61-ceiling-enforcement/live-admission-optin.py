#!/usr/bin/env python3
"""Live admission scenarios for the opt-in concurrent-session ceiling.

Every scenario below drives the shipped bin/fm-sol-cap-lib.sh CLI and the
shipped bin/fm-spawn.sh entry point against a disposable lab home, under the
captain-declared config/sol-cap contract: the guard is off unless the file
declares a ceiling and the models it covers.
"""
import os, pathlib, subprocess, tempfile, shutil, json, time, concurrent.futures

root = pathlib.Path.cwd()
lab = pathlib.Path(tempfile.mkdtemp(prefix='.ceiling-live-', dir=root))
children = []
env = os.environ.copy()
for k in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE',
          'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_GATE_REFUSE_BYPASS', 'TMUX'):
    env.pop(k, None)
env['FM_HOME'] = str(lab)
prefix = '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-secondmate-registry-lib.sh"; . "$1/bin/fm-sol-cap-lib.sh"; shift; '


def call(*args, ok=True):
    p = subprocess.run([str(root / 'bin/fm-sol-cap-lib.sh'), *map(str, args)],
                       env=env, text=True, capture_output=True, timeout=20)
    print('$ fm-sol-cap-lib.sh ' + ' '.join(map(str, args)), flush=True)
    print(p.stdout + p.stderr + f'exit={p.returncode}', flush=True)
    if ok:
        assert p.returncode == 0
    return p


def shell(code, *args, ok=True):
    p = subprocess.run(['bash', '-c', prefix + code, 'live', str(root), *map(str, args)],
                       env=env, text=True, capture_output=True, timeout=20)
    print(p.stdout + p.stderr + f'exit={p.returncode}', flush=True)
    if ok:
        assert p.returncode == 0
    return p


config = lab / 'config'
state = lab / 'state'
reg = state / 'sol-sessions.tsv'
DECLARED = 'max=4\nmodels=gpt-6.1-sol|gpt-6-sol\n'


def reset():
    for f in state.iterdir():
        if f.is_dir():
            shutil.rmtree(f)
        else:
            f.unlink()
    # The captain's declaration is the home's own setting, not per-scenario
    # state: every scenario below runs under the same declared ceiling unless
    # it says otherwise.
    (config / 'sol-cap').write_text(DECLARED)


def rows():
    s = reg.read_text() if reg.exists() else ''
    print('Persisted registry:\n' + s, flush=True)
    return s


def claim(id, model='gpt-6.1-sol', ok=True):
    return call('refuse-claim', id, 'ship', 'codex', model, config, state, ok=ok)


def reserve(id):
    return shell('fm_sol_cap_refuse_and_claim "$1" ship codex gpt-6.1-sol "$FM_HOME/config" "$FM_HOME/state" '
                 '|| { echo "$FM_SOL_CAP_REFUSAL"; exit 1; }; fm_sol_cap_promote "$1" 0 "$FM_HOME/state"; echo "reserved $1"',
                 id, ok=False)


try:
    subprocess.run([str(root / 'bin/fm-lab-home.sh'), 'create', str(lab)], check=True, env=env)
    (config / 'crew-dispatch.json').write_text(json.dumps(
        {'rules': [{'use': [{'model': 'gpt-6.1-sol'}, {'model': 'glm-5'}, {'model': 'gpt-6-sol'}]}],
         'default': {'model': 'gpt-9.9-sol'}}))

    print('SCENARIO a home that declared no ceiling is inert', flush=True)
    assert call('status', config).stdout.strip() == 'inert'
    assert call('ceiling', config).stdout.strip() == 'inert'
    assert call('models', config).stdout.strip() == ''
    assert claim('undeclared').stdout.strip() == 'not-capped'
    assert not reg.exists(), 'an undeclared home wrote a registry row'
    print('No ceiling, no reservation, and no registry row without a declaration.', flush=True)

    print('SCENARIO the declared model set and effective ceiling are read from the captain\'s file', flush=True)
    (config / 'sol-cap').write_text(DECLARED)
    assert call('status', config).stdout.strip() == 'active max=4 ceiling=4 models=gpt-6.1-sol|gpt-6-sol pattern='
    assert call('models', config).stdout.strip() == 'gpt-6.1-sol|gpt-6-sol'
    assert call('ceiling', config).stdout.strip() == '4'

    print('SCENARIO four reservations admit; fifth and same-ID retry refuse', flush=True)
    for i in range(4):
        assert reserve('worker-' + str(i)).returncode == 0
    before = rows()
    assert claim('fifth', ok=False).returncode != 0
    assert claim('worker-0', ok=False).returncode != 0
    assert rows() == before

    print('SCENARIO a model the declaration does not name bypasses a saturated ceiling', flush=True)
    for model in ('glm-5', 'qwen3', 'gpt-9.9-sol'):
        assert claim(model, model).stdout.strip() == 'not-capped'
    assert rows() == before

    print('SCENARIO a malformed declaration refuses every dispatch loudly, naming the file and the problem', flush=True)
    (config / 'sol-cap').write_text('max=4\nceiling=9\nmodels=gpt-6.1-sol\n')
    out = claim('bad-declaration', ok=False)
    assert out.returncode != 0
    assert 'ceiling unavailable' in out.stdout
    assert 'config/sol-cap' in out.stdout
    assert '1 through 4' in out.stdout
    assert claim('bad-declaration-uncapped', 'glm-5', ok=False).returncode != 0
    assert rows() == before

    print('SCENARIO a lower-only declaration refuses the excess', flush=True)
    reset()
    (config / 'sol-cap').write_text('max=4\nceiling=1\nmodels=gpt-6.1-sol|gpt-6-sol\n')
    assert reserve('only').returncode == 0
    out = claim('extra', ok=False)
    assert out.returncode != 0
    assert 'this ceiling is 1' in out.stdout

    print('SCENARIO simultaneous attempts at the last slot allow exactly one', flush=True)
    reset()
    (config / 'sol-cap').write_text(DECLARED)
    for i in range(3):
        assert reserve('existing-' + str(i)).returncode == 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(reserve, ['racer-a', 'racer-b']))
    assert sorted(p.returncode for p in results) == [0, 1]
    assert len(rows().splitlines()) == 4

    print('SCENARIO launch-process handoff and proven exit free capacity', flush=True)
    reset()
    assert reserve('probe').returncode == 0
    p = subprocess.Popen([str(root / 'bin/fm-sol-cap-lib.sh'), 'run', 'probe', str(state), 'sleep', '60'],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    children.append(p)
    for _ in range(50):
        if reg.read_text().strip().split('\t')[-1] == str(p.pid):
            break
        time.sleep(.1)
    assert reg.read_text().strip().split('\t')[-1] == str(p.pid)
    rows()
    p.terminate()
    p.wait(timeout=5)
    assert reserve('after-exit').returncode == 0
    assert 'probe\t' not in rows()

    print('SCENARIO a capped report keeps the uncertain claim and reconciles its model; an uncapped report releases it', flush=True)
    reset()
    assert reserve('reuse').returncode == 0
    before = rows().strip().split('\t')
    call('record-actual', 'reuse', 'gpt-6-sol', state)
    after = rows().strip().split('\t')
    assert after[3] == before[3], "the claim's pid changed"
    assert after[2] == before[2], "the claim's start epoch changed"
    assert after[1] == 'gpt-6-sol', 'the reported model did not reconcile the row'
    call('record-actual', 'reuse', 'glm-5', state)
    assert 'reuse\t' not in rows()

    print('SCENARIO stopped and dead positive-PID records bypass a held admission lock for uncapped models', flush=True)
    reset()
    holder = subprocess.Popen(['bash', '-c', prefix +
                                'fm_lock_try_acquire "$FM_HOME/state/.sol-cap.lock" || exit 1; echo ready; exec sleep 60',
                                'holder', str(root)], env=env, stdout=subprocess.PIPE, text=True)
    children.append(holder)
    assert holder.stdout.readline().strip() == 'ready'
    dead = subprocess.Popen(['true'])
    dead.wait()
    for pid in (-1, dead.pid):
        (state / 'retry.meta').write_text('model=gpt-6.1-sol\n')
        reg.write_text(f'retry\tgpt-6.1-sol\t{int(time.time())}\t{pid}\n')
        before = rows()
        start = time.monotonic()
        for model in ('glm-5', 'qwen3'):
            call('record-actual', 'retry', model, state)
            claim('fresh-' + model, model)
        assert time.monotonic() - start < 5
        assert rows() == before
    holder.terminate()
    holder.wait(timeout=5)

    print('ALL LIVE ADMISSION SCENARIOS PASSED', flush=True)
finally:
    for p in children:
        if p.poll() is None:
            p.terminate()
            p.wait(timeout=5)
    shutil.rmtree(lab)
    print('Disposable lab removed; owned probe processes stopped', flush=True)
