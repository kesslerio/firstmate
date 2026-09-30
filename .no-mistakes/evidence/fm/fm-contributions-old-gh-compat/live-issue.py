import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path('/Users/kesslerio/.no-mistakes/worktrees/8036f35f7c08/01M3QWKSRJRB00RM226TH7K477')
evidence = Path('/Users/kesslerio/.no-mistakes/evidence/01M3QWKSRJRB00RM226TH7K477')
gh = root / '.no-mistakes/test-phase-gh245/gh_2.45.0_macOS_arm64/bin/gh'
home = root / '.no-mistakes/test-phase-live-issue'
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','GH_HOST'):
        env.pop(key)
env['PATH'] = str(gh.parent) + os.pathsep + env['PATH']
env['GH_PROMPT_DISABLED'] = '1'
url = 'https://github.com/kunchenguid/firstmate/issues/6168'

def run(args):
    result = subprocess.run([str(x) for x in args], cwd=root, env=env,
                            capture_output=True, text=True, timeout=45)
    print('$', ' '.join(str(x) for x in args), flush=True)
    print(result.stdout[:3000], result.stderr[:1000], 'exit:', result.returncode, flush=True)
    assert result.returncode == 0
    return result.stdout

def api(endpoint):
    return json.loads(run([gh,'api',endpoint]))

try:
    core = api('repos/kunchenguid/firstmate/issues/6168')
    comments = api('repos/kunchenguid/firstmate/issues/6168/comments?per_page=100')
    events = api('repos/kunchenguid/firstmate/issues/6168/events?per_page=100')
    expected = [f"comment:{x['id']}:{x['updated_at']}" for x in comments
                if x['user']['login'] != core['user']['login'] and
                x['author_association'] in ('OWNER','MEMBER','COLLABORATOR')]
    expected += [f"ready-for-pr:{x['id']}" for x in events if x['event']=='labeled' and
                 x['label']['name'].lower() == 'ready-for-pr']
    assert any(x.startswith('comment:') for x in expected)
    assert any(x.startswith('ready-for-pr:') for x in expected)
    run(['bash','bin/fm-lab-home.sh','create',home])
    env['FM_HOME'] = str(home)
    (home / 'data/backlog.md').write_text(
        f'# Backlog\n\n## Queued\n\n- [ ] issue-proof - Read-only issue proof {url} (repo: live-proof) (kind: ship)\n')
    run(['bash','bin/fm-contributions.sh','arm'])
    run(['bash',home / 'state/contributions.check.sh'])
    pending = json.loads(run(['bash','bin/fm-contributions.sh','pending']))
    assert {x['token'] for x in pending} == set(expected)
    record = json.loads((home / 'data/issue-proof/contributions.json').read_text())
    assert record['records'][0]['error'] is None
    assert record['records'][0]['observation']['ready'] is True
    before = (home / 'state/.wake-queue').read_text()
    assert len(before.splitlines()) == len(expected)
    run(['bash',home / 'state/contributions.check.sh'])
    assert (home / 'state/.wake-queue').read_text() == before
    run(['bash','bin/fm-contributions.sh','ack','issue-proof',url,expected[0]])
    after = json.loads(run(['bash','bin/fm-contributions.sh','pending']))
    assert {x['token'] for x in after} == set(expected[1:])
    (evidence / 'live-issue-record.json').write_text(json.dumps(record, indent=2))
    (evidence / 'live-issue-wake-queue.log').write_text(before)
    (evidence / 'live-issue-result.json').write_text(json.dumps(
        {'result':'pass','url':url,'expected_tokens':expected,'pending_signals':len(pending)},indent=2))
    print('SCENARIO RESULT: maintainer comment and ready-for-pr event persist once; exact ack preserves the other signal', flush=True)
finally:
    if home.exists():
        shutil.rmtree(home)
