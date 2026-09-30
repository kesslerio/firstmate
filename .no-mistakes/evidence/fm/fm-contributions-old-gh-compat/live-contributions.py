import json
import os
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path('/Users/kesslerio/.no-mistakes/worktrees/8036f35f7c08/01M3QWKSRJRB00RM226TH7K477')
EVIDENCE = Path('/Users/kesslerio/.no-mistakes/evidence/01M3QWKSRJRB00RM226TH7K477')
GH = ROOT / '.no-mistakes/test-phase-gh245/gh_2.45.0_macOS_arm64/bin/gh'
HOMES = ROOT / '.no-mistakes/test-phase-live-homes'
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'GH_HOST'):
        env.pop(key)
env['PATH'] = str(GH.parent) + os.pathsep + env['PATH']
env['GH_PROMPT_DISABLED'] = '1'
env['GH_NO_UPDATE_NOTIFIER'] = '1'
results = []

def run(args, local_env=env, check=True):
    proc = subprocess.run([str(x) for x in args], cwd=ROOT, env=local_env,
                          text=True, capture_output=True, timeout=45)
    print('$ ' + ' '.join(str(x) for x in args), flush=True)
    if proc.stdout:
        print(proc.stdout[:4000], flush=True)
    if proc.stderr:
        print(proc.stderr[:2000], flush=True)
    print('exit:', proc.returncode, flush=True)
    if check and proc.returncode:
        raise RuntimeError('command failed')
    return proc

def api(endpoint):
    return json.loads(run([GH, 'api', endpoint]).stdout)

def page_contract(endpoint):
    pages = []
    for number in range(1, 20):
        page = api(endpoint + f'?per_page=100&page={number}')
        pages.append(page)
        if len(page) < 100:
            break
    else:
        raise RuntimeError('reference pagination exceeds bounded selection')
    return pages

def token(item, signal):
    return f"{signal}:{item['id']}:{item.get('updated_at') or item.get('submitted_at') or ''}:{item.get('state') or ''}"

def scenario(name, url, references=None, expected_failure=False):
    home = HOMES / name
    run(['bash', 'bin/fm-lab-home.sh', 'create', home])
    local = env.copy()
    local['FM_HOME'] = str(home)
    local['FM_CONTRIBUTIONS_BUDGET'] = '25'
    (home / 'data/backlog.md').write_text(
        f'# Backlog\n\n## Queued\n\n- [ ] proof - Read-only live proof {url} (repo: live-proof) (kind: ship)\n')
    try:
        run(['bash', 'bin/fm-contributions.sh', 'arm'], local)
        started = time.monotonic()
        output = run(['bash', home / 'state/contributions.check.sh'], local)
        elapsed = time.monotonic() - started
        path = home / 'data/proof/contributions.json'
        record = json.loads(path.read_text())['records'][0]
        assert record['checked_at'], 'poll deferred without an observation'
        pending = json.loads(run(['bash', 'bin/fm-contributions.sh', 'pending'], local).stdout)
        queue = home / 'state/.wake-queue'
        before_queue = queue.read_text() if queue.exists() else ''
        if expected_failure:
            assert record['error'] and record['observation'] is None
            assert 'observation unavailable' in output.stdout
            assert not pending
        else:
            assert record['error'] is None, record['error']
            if references is not None:
                expected = references['expected_tokens']
                assert set(x['token'] for x in pending) == set(expected)
                assert set(x['token'] for x in record['observation']['events']) == set(expected)
                assert len(before_queue.splitlines()) == len(expected)
            else:
                assert not pending, 'author comment created a maintainer wake'
                assert record['observation']['head']
                assert record['observation']['checks'], 'live CI checks were not normalized'
        repeat = run(['bash', home / 'state/contributions.check.sh'], local)
        assert (queue.read_text() if queue.exists() else '') == before_queue, 'repeat poll duplicated wake'
        if expected_failure:
            assert 'observation unavailable' not in repeat.stdout
        elif pending:
            first = pending[0]
            run(['bash', 'bin/fm-contributions.sh', 'ack', 'proof', url, first['token']], local)
            remaining = json.loads(run(['bash', 'bin/fm-contributions.sh', 'pending'], local).stdout)
            assert len(remaining) == len(pending) - 1
            assert first['token'] not in {x['token'] for x in remaining}
        (EVIDENCE / f'{name}-record.json').write_text(path.read_text())
        (EVIDENCE / f'{name}-wake-queue.log').write_text(before_queue)
        result = {'name':name, 'result':'pass', 'elapsed_seconds':round(elapsed, 2),
                  'pending_signals':len(pending), 'url':url,
                  'head':(record['observation'] or {}).get('head')}
        results.append(result)
        print('SCENARIO RESULT ' + json.dumps(result), flush=True)
    finally:
        shutil.rmtree(home)

try:
    run([GH, '--version'])
    reject = run([GH, 'api', 'repos/kunchenguid/firstmate', '--paginate', '--slurp'], check=False)
    assert reject.returncode and 'unknown flag: --slurp' in reject.stderr
    scenario('owned-pr-gh245', 'https://github.com/kunchenguid/firstmate/pull/5645')
    core = api('repos/cli/cli/pulls/10513')
    reference = {'author':core['user']['login'], 'pages':{}, 'expected_tokens':[]}
    for signal, endpoint in (
        ('comment','repos/cli/cli/issues/10513/comments'),
        ('review','repos/cli/cli/pulls/10513/reviews'),
        ('review-comment','repos/cli/cli/pulls/10513/comments')):
        pages = page_contract(endpoint)
        reference['pages'][signal] = [[{'id':item['id'], 'author':item['user']['login'],
            'association':item['author_association'], 'token':token(item,signal)} for item in page] for page in pages]
        reference['expected_tokens'] += [token(item,signal) for page in pages for item in page
            if item['user']['login'] != core['user']['login'] and item['author_association'] in ('OWNER','MEMBER','COLLABORATOR')]
    assert len(reference['pages']['review-comment']) > 1
    assert any(x['association'] in ('OWNER','MEMBER','COLLABORATOR') and x['author'] != reference['author']
               for x in reference['pages']['review-comment'][1])
    assert any(x['association'] not in ('OWNER','MEMBER','COLLABORATOR')
               for pages in reference['pages'].values() for page in pages for x in page)
    (EVIDENCE / 'multipage-reference.json').write_text(json.dumps(reference, indent=2))
    scenario('multipage-pr-gh245', 'https://github.com/cli/cli/pull/10513', reference)
    scenario('missing-pr-gh245', 'https://github.com/cli/cli/pull/999999999', expected_failure=True)
finally:
    if HOMES.exists():
        shutil.rmtree(HOMES)
    (EVIDENCE / 'live-results.json').write_text(json.dumps(results, indent=2))
