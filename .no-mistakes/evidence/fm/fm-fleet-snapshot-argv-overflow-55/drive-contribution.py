import os, pathlib, subprocess, tempfile, shutil, json, resource, signal

root = pathlib.Path.cwd()
evidence = pathlib.Path('/home/art/.no-mistakes/evidence/01M4CK3M44RTV3MR0ZCWQ01TRK')
lab = pathlib.Path(tempfile.mkdtemp(prefix='.contribution-live-', dir=root))
baseline = root / 'bin/.contribution-baseline.sh'
results = []
env = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND')}
env.update(FM_HOME=str(lab), TMPDIR=str(lab/'tmp'), FM_SNAPSHOT_NOW='2026-10-07T12:00:00Z', FM_CONTRIBUTIONS_NOW='2026-10-07T12:00:00Z')
for name in ('data','state','config','projects','tmp'):
    (lab/name).mkdir()

def run(label, argv, preexec_fn=None, custom_env=None):
    p = subprocess.run(argv, cwd=root, env=custom_env or env, capture_output=True, text=True, timeout=60, preexec_fn=preexec_fn)
    (evidence/(label+'.stdout')).write_text(p.stdout)
    (evidence/(label+'.stderr')).write_text(p.stderr)
    results.append({'command': argv, 'label':label, 'exit':p.returncode, 'stdout_bytes':len(p.stdout.encode()), 'stderr':p.stderr[:1500]})
    return p

def clean_tmp():
    assert not list((lab/'tmp').iterdir()), list((lab/'tmp').iterdir())

try:
    baseline.write_bytes(subprocess.check_output(['git','show','2ce57d0067d4e860e8969fa8fa8289771b855ec5:bin/fm-fleet-snapshot.sh']))
    backlog = lab/'data/backlog.md'
    backlog.write_text('# Backlog\n\n## Queued\n- [ ] sample - Unicode café "quoted" \\ text https://github.com/example/repo/pull/1 (repo: sample) (kind: ship)\n')
    (lab/'state/sample.meta').write_text('kind=ship\npr=https://github.com/example/repo/pull/1\npr_head=abc123\n')
    a = run('small-before',['bash',str(baseline),'--contribution-input'])
    b = run('small-after',['bash','bin/fm-fleet-snapshot.sh','--contribution-input'])
    assert a.returncode == b.returncode == 0
    assert json.loads(a.stdout) == json.loads(b.stdout)
    assert len(json.loads(b.stdout)['tasks']) == 1
    clean_tmp()
    results.append({'scenario':'small ownership pair preserves exact JSON semantics and cleans transport', 'result':'pass'})

    backlog.write_text('# Backlog\n\n## Queued\n' + ''.join(f'- [ ] task-{i:04d} - Contribution café {i} https://github.com/example/repo/pull/{i+1} (repo: sample) (kind: ship)\n' for i in range(400)))
    a = run('large-backlog-before',['bash',str(baseline),'--contribution-input'])
    assert a.stdout == '' and 'Argument list too long' in a.stderr
    b = run('large-backlog-after',['bash','bin/fm-fleet-snapshot.sh','--contribution-input'])
    assert b.returncode == 0, b.stderr
    data = json.loads(b.stdout)
    assert len(data['backlog']['records']) == 400
    assert [x['id'] for x in data['backlog']['records']] == [f'task-{i:04d}' for i in range(400)]
    assert len(json.dumps(data['backlog']).encode()) > 131072
    consumer = run('large-backlog-consumer',['bash','bin/fm-contributions.sh','snapshot',str(evidence/'large-backlog-after.stdout')])
    assert consumer.returncode == 0, consumer.stderr
    c = json.loads(consumer.stdout)
    assert c['known'] >= 400, c
    clean_tmp()
    results.append({'scenario':'400-row backlog exceeds 128 KiB and reaches real contribution consumer', 'result':'pass', 'backlog_json_bytes':len(json.dumps(data['backlog']).encode()), 'known':c['known']})

    bearings = run('large-backlog-bearings',['bash','bin/fm-bearings-snapshot.sh','--json'])
    assert bearings.returncode == 0, bearings.stderr
    assert json.loads(bearings.stdout)['contributions']['known'] >= 400
    clean_tmp()
    results.append({'scenario':'Bearings shows contributions for a large backlog', 'result':'pass'})

    backlog.write_text('# Backlog\n\n## Queued\n')
    for i in range(3):
        (lab/f'state/large-{i}.meta').write_text('kind=ship\npr=https://github.com/example/repo/pull/2\npr_head='+str(i)*50000+'\n')
    a = run('large-tasks-before',['bash',str(baseline),'--contribution-input'])
    assert a.stdout == '' and 'Argument list too long' in a.stderr
    b = run('large-tasks-after',['bash','bin/fm-fleet-snapshot.sh','--contribution-input'])
    assert b.returncode == 0, b.stderr
    data = json.loads(b.stdout)
    assert len(json.dumps(data['tasks']).encode()) > 131072
    for i in range(3):
        assert next(t for t in data['tasks'] if t['id']==f'large-{i}')['pr']['head'] == str(i)*50000
    clean_tmp()
    results.append({'scenario':'task document exceeds 128 KiB and preserves every metadata value', 'result':'pass', 'tasks_json_bytes':len(json.dumps(data['tasks']).encode())})

    for meta in (lab/'state').glob('*.meta'):
        meta.unlink()
    backlog.unlink()
    p = run('missing-backlog',['bash','bin/fm-fleet-snapshot.sh','--contribution-input'])
    assert p.returncode == 0
    d = json.loads(p.stdout)
    assert d['backlog']['present'] is False and d['backlog']['records'] == [] and d['tasks'] == []
    clean_tmp()
    results.append({'scenario':'absent backlog and empty fleet remain valid empty ownership JSON', 'result':'pass'})

    backlog.write_text('# Backlog\n\n## Queued\n' + ''.join(f'- [ ] row-{i} - Entry {i}\n' for i in range(30)))
    def file_limit():
        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
        resource.setrlimit(resource.RLIMIT_FSIZE, (1024,1024))
    p = run('transport-write-failure',['bash','bin/fm-fleet-snapshot.sh','--contribution-input'],preexec_fn=file_limit)
    assert p.returncode != 0 and 'contribution backlog write failed' in p.stderr
    assert p.stdout == ''
    clean_tmp()
    results.append({'scenario':'failed transport write reports failure, emits no JSON, and removes temporary files', 'result':'pass'})

    bad_env = dict(env, TMPDIR=str(lab/'does-not-exist'))
    p = run('transport-creation-failure',['bash','bin/fm-fleet-snapshot.sh','--contribution-input'],custom_env=bad_env)
    assert p.returncode != 0 and 'contribution temp dir failed' in p.stderr and p.stdout == ''
    results.append({'scenario':'unavailable temporary directory reports failure without a misleading empty result', 'result':'pass'})
finally:
    baseline.unlink(missing_ok=True)
    shutil.rmtree(lab)
    (evidence/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')

print(json.dumps(results,indent=2))
