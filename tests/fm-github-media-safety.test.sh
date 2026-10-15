#!/usr/bin/env bash
# Offline public-CLI regressions for publication fences, no-child recovery,
# complete-line retirement, preclaim labels and changed-file suite selection.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ "$(uname -s)" != Linux ]; then
  printf '%s\n' 'skip: Linux subreaper/pidfd media lifecycle is unavailable'
  exit 0
fi
TEST_ROOT=$(fm_test_tmproot fm-github-media-safety)
export TEST_ROOT ROOT
python3 -B - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

support = Path(os.environ['ROOT'])/'libexec/github-media'
sys.path.insert(0, str(support))
from github_media_fixtures import (root, cli, fixture, command, run, prepared,
                                  add_video, deps, publish, native, validator)


def read_remote(p):
    return json.loads((p/'remote.json').read_text())


def body(p):
    return read_remote(p)['/repos/owner/repo/pulls/7']['body']


def set_body(p, value):
    remote = read_remote(p)
    remote['/repos/owner/repo/pulls/7']['body'] = value
    (p/'remote.json').write_text(json.dumps(remote))


def invoke(p, m, env, verb, *args):
    return subprocess.run(['bash', str(cli), verb, '--operation', m['operation'], *args],
                          env=env, capture_output=True, text=True, timeout=25)


def count_calls(p, name='native-calls'):
    return len((p/name).read_text().splitlines()) if (p/name).exists() else 0


# Synthetic validator changes the remote at the final validation call in the
# last batch before an attachment. It is the real public CLI that must refresh.
validator.write_text(validator.read_text().replace(
    "if (p/'legacy-validator').exists(): sys.exit()",
    """if (p/'validator-drift').exists() and len((p/'hygiene-calls').read_text().splitlines())==6:
 change=json.loads((p/'validator-drift').read_text())
 remote=json.loads((p/'remote.json').read_text())
 at=remote
 for key in change['path'][:-1]: at=at[key]
 at[change['path'][-1]]=change['value']
 (p/'remote.json').write_text(json.dumps(remote))
 (p/'drift-observed').touch()
if (p/'legacy-validator').exists(): sys.exit()"""))
# Check approved label bytes from the manifest instead of assuming one caption.
native.write_text(native.read_text().replace("else: assert label=='Approved view'", """else:
 manifest=json.loads((p/'manifest.json').read_text())
 assert label==manifest['files'][int(pathlib.Path(source).stem)]['label']"""))


def drift_case(path, value, diagnostic):
    p, m, env = fixture()
    add_video(p, m)
    op = prepared(p, m, env)
    (p/'validator-drift').write_text(json.dumps(dict(path=path, value=value)))
    result = invoke(p,m,env,'publish','--dependencies',str(deps(p)))
    record = json.loads((op/'operation.json').read_text())
    observed = dict(status=result.returncode, stderr=result.stderr.strip(), native=count_calls(p),
                    states=[i['state'] for i in record['items']])
    print('validator drift observation:', path, observed)
    assert (p/'drift-observed').exists()
    assert result.returncode == 1 and diagnostic in result.stderr, observed
    assert count_calls(p) == 0 and all('attempts' not in i for i in record['items']), observed
    remote = read_remote(p)
    for key in path:
        remote = remote[key]
    assert remote == value, 'concurrent remote content was overwritten'


def collision_case(index, label):
    p, m, env = fixture()
    add_video(p,m)
    m['files'][index]['label'] = label
    result = run(p,m,env)
    claimed = list((p/'registry').glob('*.json'))
    print('label collision observation:', index, label, result.returncode, len(claimed))
    assert result.returncode == 1 and 'snapshot' in result.stderr, result.stderr
    assert not claimed and count_calls(p) == 0 and not (p/'calls').exists()
    assert not (Path(m['home'])/'data/task/github-media/op1').exists()


def normal_case():
    p,m,env=fixture(); add_video(p,m)
    prepared(p,m,env)
    first=json.loads(publish(p,m,env).stdout)
    second=json.loads(publish(p,m,env).stdout)
    assert first['items']==second['items'] and count_calls(p)==2
    assert [x['state'] for x in second['items']]==['published-confirmed']*2
    for item, approved in zip(second['items'],m['files']):
        assert hashlib.sha256((Path(second['operation_dir'])/item['snapshot']).read_bytes()).hexdigest()==approved['sha256']


def snapshot_body_case(value):
    p,m,env=fixture(); add_video(p,m); set_body(p,value)
    prepared(p,m,env)
    result=invoke(p,m,env,'publish','--dependencies',str(deps(p)))
    assert result.returncode==1 and 'snapshot' in result.stderr, result.stderr
    assert count_calls(p)==0


def retirement_case(original, retired, retained, allowed):
    p,m,env=fixture(); set_body(p,original); prepared(p,m,env)
    rec=json.loads(publish(p,m,env).stdout)
    media='![Approved view]('+rec['items'][0]['attempts'][-1]['url']+')'
    draft='\n\n'+media+'\n\n'+retained
    path=p/'approved.md'; path.write_bytes(draft.encode())
    approval=dict(schema=1,id='final',home=m['home'],task=m['task'],operation=m['operation'],
        target=m['target'],actor=m['actor'],source=m['source'],authority=m['authority'],
        purpose='final',before_body_sha256=hashlib.sha256(body(p).encode()).hexdigest(),
        draft=dict(path=str(path),sha256=hashlib.sha256(draft.encode()).hexdigest()),
        prose_offset=0,retire_media_owed=retired)
    a=p/'approval.json'; a.write_text(json.dumps(approval))
    before=body(p)
    result=invoke(p,m,env,'edit-body','--dependencies',str(deps(p)),'--approval',str(a))
    print('retirement observation:', repr(original), repr(retired), result.returncode, result.stderr.strip())
    if allowed:
        assert result.returncode==0 and body(p)==draft and count_calls(p,'body-calls')==1, result.stderr
    else:
        assert result.returncode==1 and count_calls(p,'body-calls')==0 and body(p)==before, result.stderr


def setup_fault_case(boundary, phase='read', fail_receipt=False):
    p,m,env=fixture()
    op=Path(m['home'])/'data/task/github-media/op1'
    if phase == 'attach':
        prepared(p,m,env)
    shim=p/'shim'; shim.mkdir()
    # Private interpreter launcher injects an OS boundary failure while keeping
    # the Bash argv, public argparse dispatch, journals, stdout and status real.
    driver=shim/'startup.py'
    driver.write_text('''import errno,json,os,runpy,sys
from pathlib import Path
args=sys.argv[1:]
if args[:1]==['-B']: args=args[1:]
if not args or Path(args[0]).name!='fm-github-media-state.py':
 os.execv(sys.executable,[sys.executable,*sys.argv[1:]])
boundary='''+repr(boundary)+'''
phase='''+repr(phase)+'''
operation=Path('''+repr(str(op))+''')
fail_receipt='''+repr(fail_receipt)+'''
original=getattr(os,boundary)
before=set(os.listdir('/proc/self/fd'))
def fail_once(*args,**kwargs):
 if not any(r.get('state')=='starting' and r.get('phase')==phase
            for r in (json.loads(p.read_text()) for p in operation.glob('command-*.json'))):
  return original(*args,**kwargs)
 setattr(os,boundary,original)
 if fail_receipt:
  replace=os.replace
  def fail_write(*args,**kwargs):
   os.replace=replace
   raise OSError(errno.ENOSPC,'synthetic receipt write failure')
  os.replace=fail_write
 raise OSError(errno.EMFILE if boundary=='pipe' else errno.EAGAIN,'synthetic setup failure')
setattr(os,boundary,fail_once)
sys.path.insert(0,str(Path(args[0]).parent))
sys.argv=args
try:
 runpy.run_path(args[0],run_name='__main__')
finally:
 setattr(os,boundary,original)
 after=set(os.listdir('/proc/self/fd'))
 Path('''+repr(str(p/'fd-proof.json'))+''').write_text(json.dumps(dict(before=sorted(before),after=sorted(after))))
''')
    launcher=shim/'python3'
    launcher.write_text('#!/usr/bin/env bash\nexec '+shlex.quote(sys.executable)+' -B '+shlex.quote(str(driver))+' "$@"\n')
    launcher.chmod(0o700)
    faultenv=dict(env,PATH=str(shim)+':'+env['PATH'])
    result=(run(p,m,faultenv) if phase=='read' else
            invoke(p,m,faultenv,'publish','--dependencies',str(deps(p))))
    receipts=[p for p in op.glob('command-*.json') if json.loads(p.read_text())['phase']==phase]
    assert len(receipts)==1
    path=receipts[0]; record=json.loads(path.read_text())
    fds=json.loads((p/'fd-proof.json').read_text())
    print('OS setup observation:',boundary,phase,fail_receipt,result.returncode,record,fds)
    assert result.returncode==1 and not result.stdout and count_calls(p)==0
    if phase=='read':
        assert not (p/'calls').exists()
    assert fds['before']==fds['after'], fds
    starting=dict(schema=1,id=path.stem[8:],phase=phase,state='starting')
    if fail_receipt:
        assert record==starting, record
        resumed=command(p,m,env); resumed.insert(3,'--resume')
        outcome=subprocess.run(resumed,env=env,capture_output=True,text=True,timeout=15)
        assert outcome.returncode==1 and 'ownership' in outcome.stderr, outcome.stderr
        return
    assert record==dict(schema=1,id=path.stem[8:],phase=phase,state='stopped',guardian=None,
                        reason='spawn-failed',returncode=None,output='',descendants_reaped=True,
                        child_started=False), record
    if phase=='attach':
        saved=json.loads((op/'operation.json').read_text())
        assert saved['items'][0]['state']=='unknown'
        assert len(saved['items'][0]['attempts'])==1
        publish(p,m,env,'disposition')
        assert count_calls(p)==0
        assert json.loads((op/'operation.json').read_text())['items']==saved['items']
        return
    resumed=command(p,m,env); resumed.insert(3,'--resume')
    path.write_text(json.dumps(starting))
    denied=subprocess.run(resumed,env=env,capture_output=True,text=True,timeout=15)
    assert denied.returncode==1 and 'ownership' in denied.stderr, denied.stderr
    assert not (p/'calls').exists()
    path.write_text(json.dumps(record))
    outcome=subprocess.run(resumed,env=env,capture_output=True,text=True,timeout=15)
    assert outcome.returncode==0, outcome.stderr
    assert json.loads(path.read_text())==record and count_calls(p)==0
    assert list(op.glob('preparation-*.json')), 'failed preparation history was erased'
    # An exact no-child receipt is accepted; every uncertain shape still holds.
    for mutation in ({'state':'starting'}, {'child_started':True}, {'child_pid':123},
                     {'guardian':{}}, {'returncode':0}, {'output':'YQ=='},
                     {'descendants_reaped':False}, {'reason':'exited'}, {'schema':True}):
        malformed=dict(record,**mutation); path.write_text(json.dumps(malformed))
        check=invoke(p,m,env,'inspect')
        assert check.returncode==1 and ('ownership' in check.stderr or 'receipt' in check.stderr), (mutation,check.stderr)
        assert count_calls(p)==0
    path.write_text(json.dumps(record))
    assert invoke(p,m,env,'inspect').returncode==0


def selection_case(path):
    shim=root/('selection-'+hashlib.sha256(path.encode()).hexdigest()[:8]); shim.mkdir()
    git=shim/'git'
    git.write_text('''#!/usr/bin/env python3
import os,sys
x=sys.argv[1:]
if x[:1]==['-C']: x=x[2:]
if x[:2]==['rev-parse','--verify']: print('8ae4cd013a1d5e1ca11d71a879b02776c0afdfaf');sys.exit()
if x[:2]==['diff','--name-only']:
 if x[2].endswith('...HEAD'): print(os.environ['MEDIA_CHANGED_PATH'])
 sys.exit()
if x[:1]==['ls-files']:sys.exit()
raise SystemExit('unexpected synthetic git read: '+repr(x))
'''); git.chmod(0o700)
    env=dict(os.environ,PATH=str(shim)+':'+os.environ['PATH'],MEDIA_CHANGED_PATH=path)
    result=subprocess.run(['bash',str(cli.parent/'fm-test-run.sh'),'--list','--changed','--base','HEAD'],
                          env=env,capture_output=True,text=True,timeout=15)
    print('changed selection observation:',path,result.returncode,result.stdout.strip(),result.stderr.strip())
    assert result.returncode==0,result.stderr
    selected=set(result.stdout.splitlines())
    assert {'tests/fm-github-media.test.sh','tests/fm-github-media-hygiene.test.sh'}<=selected,selected


cases=[]
for path,value,diagnostic in [
    (['/repos/owner/repo/pulls/7','head','sha'],'b'*40,'source/head'),
    (['/repos/owner/repo/pulls/7','body'],'concurrent body','body drift'),
    (['/user','login'],'changed-user','actor mismatch'),
    (['/repos/owner/repo','permissions','push'],False,'writer capability'),
    (['/repos/owner/repo/pulls/7','head','repo','node_id'],'R_other','source/head')]:
    cases.append(('validator drift '+str(path),lambda p=path,v=value,d=diagnostic:drift_case(p,v,d)))
for index,label in [(0,'render 0.png'),(0,'render 1.mp4'),(1,'render 0.png'),(1,'render 1.mp4')]:
    cases.append(('label collision '+str(index)+' '+label,lambda i=index,l=label:collision_case(i,l)))
cases.append(('normal image video and confirmed reuse',normal_case))
for value in ['existing 0.png','existing %30.png',r'existing 0\.png']:
    cases.append(('snapshot reference '+value,lambda v=value:snapshot_body_case(v)))
for original,retired,retained,allowed in [
    ('Retained prose\nmedia still owed\n','media still owed\n','Retained prose',True),
    ('Before\nmedia still owed\nAfter','media still owed\n','Before\nAfter',True),
    ('Before\r\nmedia still owed\r\n','media still owed\r\n','Before',True),
    ('media still owed\n\nAfter\n','media still owed\n','\nAfter',True),
    ('media still owed\nmedia still owed\n','media still owed\n','',False),
    ('prefix media still owed\n','media still owed\n','prefix ',False),
    ('Retained\nmedia still owed','media still owed\n','Retained',False),
    ('Before\nmedia still owed\nAfter','media still owed','Before\nAfter',False),
    ('Before\nmedia still owed\nAfter','media still owed\nAfter','Before',False)]:
    cases.append(('retirement '+repr(original),lambda o=original,r=retired,t=retained,a=allowed:retirement_case(o,r,t,a)))
for boundary in ('pipe','fork'):
    cases.append(('OS setup '+boundary,lambda b=boundary:setup_fault_case(b)))
    cases.append(('OS setup attach '+boundary,lambda b=boundary:setup_fault_case(b,'attach')))
cases.append(('OS setup receipt failure',lambda:setup_fault_case('fork',fail_receipt=True)))
for path in ('bin/fm-github-media.sh','bin/fm-github-media-state.py','bin/fm_github_media_lifecycle.py',
             'libexec/github-media/fm-github-media-state.py','libexec/github-media/fm_github_media_lifecycle.py',
             'libexec/github-media/github_media_fixtures.py'):
    cases.append(('selection '+path,lambda p=path:selection_case(p)))
failures=[]
for name,case in cases:
    try:
        case()
        print('ok - '+name,flush=True)
    except AssertionError as exc:
        failures.append(name)
        print('not ok - '+name+': '+str(exc),flush=True)
assert not failures, failures

PY
