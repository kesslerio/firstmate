#!/usr/bin/env bash
# Guarded real-policy integration with synthetic remote/native backends only.
# Usage: FM_GITHUB_MEDIA_POLICY_SOURCE=/absolute/reviewed/pr-body-lint
#        FM_GITHUB_MEDIA_POLICY_SHA256=<reviewed digest>
#        FM_GITHUB_MEDIA_CMARK_SOURCE=/nix/store/<hash>-cmark-gfm-0.29.0.gfm.13/bin/cmark-gfm
#        FM_GITHUB_MEDIA_CMARK_SHA256=<reviewed digest> bash tests/fm-github-media-hygiene.test.sh
# All four unset: explicit gated omission. Partial, stale or unsafe binding: failure.
# Supply a stable reviewed artifact, never an actively changing default/hook.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ -z "${FM_GITHUB_MEDIA_POLICY_SOURCE:-}${FM_GITHUB_MEDIA_POLICY_SHA256:-}${FM_GITHUB_MEDIA_CMARK_SOURCE:-}${FM_GITHUB_MEDIA_CMARK_SHA256:-}" ]; then
  printf '%s\n' 'skip: real-policy integration gated: explicit reviewed policy and parser paths and SHA256 required; no real policy pass'
  exit 0
fi
if [ "$(uname -s)" != Linux ]; then
  printf '%s\n' 'real-policy integration requires Linux subreaper/pidfd support' >&2
  exit 1
fi
TEST_ROOT=$(fm_test_tmproot fm-github-media-hygiene)
export TEST_ROOT ROOT
python3 -B - <<'PY'
import hashlib
import os
from pathlib import Path
import re
import sys

source = os.environ.get('FM_GITHUB_MEDIA_POLICY_SOURCE', '')
digest = os.environ.get('FM_GITHUB_MEDIA_POLICY_SHA256', '')
path = Path(source)
if (not path.is_absolute() or str(path.resolve()) != source or not path.is_file() or
        not re.fullmatch(r'[0-9a-f]{64}', digest) or hashlib.sha256(path.read_bytes()).hexdigest() != digest):
    raise SystemExit('real-policy integration held: missing/unsafe/changed reviewed source binding')
parser_source = os.environ.get('FM_GITHUB_MEDIA_CMARK_SOURCE', '')
parser_digest = os.environ.get('FM_GITHUB_MEDIA_CMARK_SHA256', '')
parser_path = Path(parser_source)
if (not re.fullmatch(r'/nix/store/[a-z0-9]{32}-cmark-gfm-0\.29\.0\.gfm\.13/bin/cmark-gfm', parser_source) or
        str(parser_path.resolve()) != parser_source or not parser_path.is_file() or
        not os.access(parser_path, os.X_OK) or not re.fullmatch(r'[0-9a-f]{64}', parser_digest) or
        hashlib.sha256(parser_path.read_bytes()).hexdigest() != parser_digest):
    raise SystemExit('real-policy integration held: missing/unsafe/changed reviewed parser binding')
sys.path.insert(0, str(Path(os.environ['ROOT'])/'libexec/github-media'))
from github_media_fixtures import fixture, prepared, publish, deps, cli, add_video
import json
import subprocess

for kind in ('pr', 'issue'):
    p, m, env = fixture(kind)
    add_video(p, m)
    prepared(p, m, env)
    dependency = deps(p, {'validator': path, 'parser': parser_path})
    # The helper, not this test, must verify all six real receipt fields for
    # current body, ordered labels, cumulative predictions and readback.
    record = json.loads(publish(p, m, env, dependency=dependency).stdout)
    before = json.loads((p/'remote.json').read_text())['/repos/owner/repo/'+('pulls' if kind == 'pr' else 'issues')+'/7']['body']
    image = '![Approved view]('+record['items'][0]['attempts'][-1]['url']+')'
    draft = '\n\n'+image+'\n\nApproved playback\n\n'+record['items'][1]['attempts'][-1]['url']+'\n\noriginal body'
    draft_path = p/'approved.md'; draft_path.write_text(draft)
    approval = dict(schema=1, id='final-policy', home=m['home'], task=m['task'], operation=m['operation'],
                    target=m['target'], actor=m['actor'], source=m.get('source'), authority=m['authority'],
                    purpose='final', before_body_sha256=hashlib.sha256(before.encode()).hexdigest(),
                    draft=dict(path=str(draft_path), sha256=hashlib.sha256(draft.encode()).hexdigest()), prose_offset=0)
    approval_path=p/'approval.json'; approval_path.write_text(json.dumps(approval))
    result=subprocess.run(['bash',str(cli),'edit-body','--operation','op1','--dependencies',str(dependency),
                           '--approval',str(approval_path)],env=env,capture_output=True,text=True,timeout=30)
    assert result.returncode == 0, result.stderr
    publish(p,m,env,dependency=dependency)
    assert len((p/'native-calls').read_text().splitlines()) == 2
    assert len((p/'body-calls').read_text().splitlines()) == 1
    print('ok - real reviewed policy with synthetic '+kind+' image/video predictions, readback and approved final draft')

    for body in ('![External](https://example.invalid/private.png)', 'Private file /home/operator/secret.png'):
        p,m,env=fixture(kind); env['PR_LINT_SKIP']='1'
        remote=json.loads((p/'remote.json').read_text())
        key='/repos/owner/repo/'+('pulls' if kind=='pr' else 'issues')+'/7'
        remote[key]['body']=body; (p/'remote.json').write_text(json.dumps(remote))
        prepared(p,m,env)
        publish(p,m,env,'validator',dependency=deps(p,{'validator':path, 'parser':parser_path}))
        assert not (p/'native-calls').exists()
    print('ok - real policy rejects external/private body even with skip environment')
assert hashlib.sha256(path.read_bytes()).hexdigest() == digest, 'reviewed policy source changed during integration'
assert hashlib.sha256(parser_path.read_bytes()).hexdigest() == parser_digest, 'reviewed parser changed during integration'
print('ok - real policy integration only; no GitHub requests/uploads or rendered/playback acceptance')
PY
