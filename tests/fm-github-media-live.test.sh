#!/usr/bin/env bash
# Opt-in publication acceptance, with task-specific authority for every case.
# FM_GITHUB_MEDIA_LIVE_CASES points to {schema:1, authority:{explicit:true,
# approved_by,provenance}, cases:[{manifest,dependencies,evidence}]}.
# Each manifest/dependencies file follows fm-github-media.sh --help.
# No default target, identity, media, approval or credential repair is provided.
# Evidence is independent attachment-render/v1 JSON bound to target, operation,
# exact body_sha256 and items [{ordinal,sha256,url,rendered:true,playback:bool,
# artifact:{path,sha256}}], plus reviewer and independent:true.
# Artifacts are existing screenshots/playback-review files; this test cannot
# invent rendered proof. Missing evidence fails after recording publication.
# Reruns reuse confirmed operations; ambiguous attempts require operator action.
# A pass requires independently reviewed PR+issue image+video surfaces.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_GITHUB_MEDIA_LIVE python3
unset FM_TEST_SEAM FM_GITHUB_MEDIA_TEST_ROOT FM_GITHUB_MEDIA_TEST_READ FM_GITHUB_MEDIA_TEST_TIMEOUT
export ROOT
python3 -B - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def require(ok, message):
    if not ok:
        raise ValueError(message)


def read(path):
    require(isinstance(path, str) and path.startswith('/'), 'explicit absolute input path required')
    return json.loads(Path(path).read_text(encoding='utf-8'))


def digest(path):
    with Path(path).open('rb') as stream:
        hasher = hashlib.sha256()
        for chunk in iter(lambda: stream.read(65536), b''):
            hasher.update(chunk)
        return hasher.hexdigest()


def invoke(args, env):
    result = subprocess.run(['bash', os.environ['ROOT']+'/bin/fm-github-media.sh', *args],
                            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    require(result.returncode == 0, 'media command held; inspect its private operation record before retry')
    return json.loads(result.stdout)


try:
    plan = read(os.environ.get('FM_GITHUB_MEDIA_LIVE_CASES'))
    authority = plan.get('authority', {})
    require(plan.get('schema') == 1 and authority.get('explicit') is True and
            all(isinstance(authority.get(k), str) and authority[k].strip() for k in ['approved_by','provenance']),
            'task-specific live publication authority required')
    cases = plan.get('cases')
    require(isinstance(cases, list) and 0 < len(cases) <= 10, 'bounded explicit live cases required')
    # Parse every case before the first publication, with no ambient target.
    inputs = []
    for case in cases:
        require(set(case) == {'manifest','dependencies','evidence'}, 'invalid live case fields')
        manifest = read(case['manifest'])
        require(manifest.get('authority', {}).get('explicit') is True, 'case publication approval missing')
        read(case['dependencies'])
        require(isinstance(case['evidence'], str) and case['evidence'].startswith('/'), 'explicit review evidence path required')
        inputs.append((case, manifest))
    exercised, reviewed = set(), set()
    for case, manifest in inputs:
        env = dict(os.environ, FM_HOME=manifest['home'], FM_TASK_ID=manifest['task'])
        operation = Path(manifest['home'])/'data'/manifest['task']/'github-media'/manifest['operation']
        if operation.exists():
            saved = invoke(['inspect','--operation',manifest['operation']], env)
            require(saved['manifest'] == manifest, 'live manifest differs from retained operation')
        else:
            invoke(['prepare','--manifest',case['manifest'],'--',*[f['path'] for f in manifest['files']]], env)
        result = invoke(['publish','--operation',manifest['operation'],'--dependencies',case['dependencies']], env)
        require(result['state'] == 'published-confirmed', 'publication has unresolved items')
        kind = manifest['target']['kind']
        for approved in manifest['files']:
            exercised.add(kind + ':' + ('video' if approved['media_type'].startswith('video/') else 'image'))
        print('exercised native publication: '+', '.join(sorted(exercised)), flush=True)
        evidence = read(case['evidence'])
        require(evidence.get('protocol') == 'attachment-render/v1' and evidence.get('independent') is True and
                isinstance(evidence.get('reviewer'), str) and evidence['reviewer'].strip() and
                evidence['reviewer'] != manifest['actor'] and
                evidence.get('operation') == manifest['operation'] and evidence.get('target') == manifest['target'] and
                evidence.get('body_sha256') == result['expected_body_sha256'],
                'fresh independent rendered-review evidence must bind the exact operation and readback')
        require(len(evidence.get('items', [])) == len(result['items']), 'every media item needs review evidence')
        for observed, item, approved in zip(evidence['items'], result['items'], manifest['files']):
            video = approved['media_type'].startswith('video/')
            require(observed.get('ordinal') == item['ordinal'] and observed.get('sha256') == approved['sha256'] and
                    observed.get('url') == item['attempts'][-1]['url'] and observed.get('rendered') is True and
                    (not video or observed.get('playback') is True), 'render/playback evidence does not bind confirmed media')
            artifact = observed.get('artifact', {})
            require(isinstance(artifact.get('path'), str) and artifact['path'].startswith('/') and
                    Path(artifact['path']).is_file() and Path(artifact['path']).stat().st_size > 0 and
                    digest(artifact['path']) == artifact.get('sha256'), 'review artifact missing or changed')
            reviewed.add(kind + ':' + ('video' if video else 'image'))
    required = {'pr:image','pr:video','issue:image','issue:video'}
    print('independently reviewed surfaces: '+', '.join(sorted(reviewed)), flush=True)
    require(reviewed == required, 'unexercised/unreviewed required surfaces: '+', '.join(sorted(required-reviewed)))
except (OSError, ValueError, KeyError, TypeError):
    print('not ok - live media acceptance incomplete; inspect private records and supply task-bound independent evidence', file=sys.stderr)
    sys.exit(1)
print('ok - authorized native PR/issue images/videos with independent rendering/playback evidence')
PY
