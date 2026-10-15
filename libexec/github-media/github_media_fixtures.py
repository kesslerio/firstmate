# Explicit synthetic backend fixtures shared by media and guarded policy tests.
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

root = Path(os.environ['TEST_ROOT'])
cli = Path(os.environ['ROOT']) / 'bin/fm-github-media.sh'
fake = root / 'fakebin'
fake.mkdir()
transport = fake / 'gh-axi'
transport.write_text('''#!/usr/bin/env python3
import base64, json, os, pathlib, subprocess, sys, time
args = sys.argv[1:]
p = pathlib.Path(os.environ['FIXTURE'])
if args[:2] in (['pr','edit'], ['issue','edit']):
 assert args[2:6] == ['7','--repo','owner/repo','--body-file'] and len(args)==7,args
 with (p/'body-calls').open('a') as f: f.write(json.dumps(args)+'\\n')
 if (p/'body-block').exists():
  subprocess.Popen([sys.executable,'-c',"import os,pathlib,time; os.setsid(); pathlib.Path(os.environ['FIXTURE']+'/grandchild-pid').write_text(str(os.getpid())); time.sleep(90)"],close_fds=True)
  (p/'body-pid').write_text(str(os.getpid()))
  while not (p/'grandchild-pid').exists(): time.sleep(.01)
  (p/'body-entered').touch(); time.sleep(90)
 remote=json.loads((p/'remote.json').read_text()); key='/repos/owner/repo/'+('pulls' if args[0]=='pr' else 'issues')+'/7'
 if not (p/'body-no-write').exists():
  remote[key]['body']=pathlib.Path(args[6]).read_bytes().decode()
  (p/'remote.json').write_text(json.dumps(remote))
 if (p/'body-lose-readback').exists(): (p/'bad-wire').touch()
 sys.exit(1 if (p/'body-nonzero').exists() else 0)
assert args[:2] == ['api', 'GET'], args
assert args[-2:] == ['--hostname', 'github.com'], args
assert args[3:6] == ['--jq', '@base64', '--full'], args
p = pathlib.Path(os.environ['FIXTURE'])
(p/'transport-pid').write_text(str(os.getpid()))
with (p/'calls').open('a') as f: f.write(json.dumps(args)+'\\n')
if (p/'block').exists():
 if (p/'read-grandchild').exists():
  subprocess.Popen([sys.executable,'-c',"import os,pathlib,time; os.setsid(); pathlib.Path(os.environ['FIXTURE']+'/grandchild-pid').write_text(str(os.getpid())); time.sleep(90)"],close_fds=True)
  while not (p/'grandchild-pid').exists(): time.sleep(.01)
 (p/'entered').touch()
 while not (p/'release').exists(): time.sleep(.02)
if (p/'mutate').exists():
 pathlib.Path((p/'mutate').read_text()).write_bytes(b'changed after snapshot')
data = json.loads((p/'remote.json').read_text())[args[2]]
if (p/'bad-wire').exists(): print('[3]: wrong,shape,false'); sys.exit()
if (p/'read-error').exists(): print('synthetic-auth-secret',file=sys.stderr); sys.exit(1)
print('api_response:\\n  body: '+base64.b64encode(json.dumps(data).encode()).decode()+'\\n  truncated: false')
''')
transport.chmod(0o700)
native = fake/'github-media-gh'
native.write_text('''#!/usr/bin/env python3
import hashlib,json,os,pathlib,subprocess,sys,time
p=pathlib.Path(os.environ['FIXTURE'])
args=sys.argv[1:]
if args==['--version']:
 print('gh version '+('0.0.0' if (p/'bad-version').exists() else '2.102.0')); sys.exit()
if args[-1:] == ['--help']:
 print('--attach file'); sys.exit()
assert args[0] in ['pr','issue'] and args[1]=='edit' and len(args)==7,args
assert args[2]=='https://github.com/owner/repo/'+('pull' if args[0]=='pr' else 'issues')+'/7',args
assert args[3:6]==['--repo','github.com/owner/repo','--attach'],args
source,sep,label=args[6].partition('#')
assert pathlib.Path(source).is_file()
if source.endswith('.mp4'): assert not sep
else: assert label=='Approved view'
with (p/'native-calls').open('a') as f: f.write(json.dumps(args)+'\\n')
with (p/'native-hashes').open('a') as f: f.write(hashlib.sha256(pathlib.Path(source).read_bytes()).hexdigest()+'\\n')
if (p/'native-auth-error').exists(): print('synthetic-auth-secret: unsupported token/SSO',file=sys.stderr); sys.exit(1)
if (p/'upload-failure').exists(): sys.exit(1)
if (p/'patch-failure').exists(): (p/'uploaded-unreferenced').touch(); sys.exit(1)
if (p/'native-block').exists():
 code="import os,pathlib,time; os.setsid(); pathlib.Path(os.environ['FIXTURE']+'/grandchild-pid').write_text(str(os.getpid())); time.sleep(90)"
 subprocess.Popen([sys.executable,'-c',code],close_fds=True)
 (p/'native-pid').write_text(str(os.getpid()))
 while not (p/'grandchild-pid').exists(): time.sleep(.01)
 (p/'native-entered').touch()
 time.sleep(90)
remote=json.loads((p/'remote.json').read_text()); key='/repos/owner/repo/'+('pulls' if args[0]=='pr' else 'issues')+'/7'
if not (p/'no-append').exists():
 count=len((p/'native-calls').read_text().splitlines())
 url='https://github.com/user-attachments/assets/11111111-1111-1111-1111-'+str(count).zfill(12)
 if (p/'evil-url').exists(): url=(p/'evil-url').read_text()
 addition=url if source.endswith('.mp4') else '!['+label+']('+url+')'
 before=(remote[key]['body'] or '').rstrip(' \\t\\r\\n')
 remote[key]['body']=before+('\\n\\n' if before else '')+addition
 if (p/'body-drift').exists(): remote[key]['body']='unrelated concurrent edit\\n\\n'+addition
 if (p/'head-drift').exists(): remote[key]['head']['sha']='b'*40
 (p/'remote.json').write_text(json.dumps(remote))
if (p/'lose-readback').exists(): (p/'bad-wire').touch()
if (p/'block-after-land').exists(): time.sleep(90)
print('https://github.com/owner/repo/'+('pull' if args[0]=='pr' else 'issues')+'/7')
sys.exit(1 if (p/'native-nonzero').exists() else 0)
''')
native.chmod(0o700)
parser = fake/'cmark-gfm'
parser.write_text('#!/usr/bin/env python3\nimport os,time\nif os.environ.get("FIXTURE"):\n import pathlib\n p=pathlib.Path(os.environ["FIXTURE"])\n if (p/"parser-block").exists():\n  (p/"parser-pid").write_text(str(os.getpid()))\n  (p/"parser-entered").touch()\n  time.sleep(90)\n')
parser.chmod(0o700)
validator = fake/'pr-body-lint'
validator.write_text('''import hashlib,json,os,pathlib,subprocess,sys,time
p=pathlib.Path(os.environ['FIXTURE']); args=sys.argv[1:]
assert args[:1]==['--validate-attachment-body']
parser=pathlib.Path(args[args.index('--cmark')+1]); digest=args[args.index('--cmark-sha256')+1]
assert parser.is_absolute() and hashlib.sha256(parser.read_bytes()).hexdigest()==digest
assert args.count('--cmark')==args.count('--cmark-sha256')==1
if (p/'parser-block').exists():
 (p/'validator-pid').write_text(str(os.getpid()))
 subprocess.run([str(parser)],check=True)
repo=args[args.index('--repo')+1]; kind=args[args.index('--target-kind')+1]
body=pathlib.Path(args[args.index('--body-file')+1]).read_bytes()
labels=[args[i+1] for i,a in enumerate(args) if a=='--media-label']
with (p/'hygiene-calls').open('a') as f: f.write(json.dumps(dict(body=body.decode(),labels=labels))+'\\n')
if (p/'legacy-validator').exists(): sys.exit()
if (p/'validator-timeout').exists(): time.sleep(90)
if (p/'deny-private').exists() and b'SYNTHETIC_PRIVATE_MARKER' in body: sys.exit(2)
if (p/'deny-draft').exists() and b'Approved playback' in body: sys.exit(2)
if (p/'deny-label').exists() and 'Forbidden label' in labels: sys.exit(2)
if (p/'deny-cumulative').exists() and body.count(b'user-attachments/assets/')>1: sys.exit(2)
if (p/'deny-readback').exists() and b'11111111-1111' in body: sys.exit(2)
receipt=dict(protocol='attachment-body/v1',valid=True,repo=repo,target_kind=kind,body_sha256=hashlib.sha256(body).hexdigest(),labels_sha256=hashlib.sha256(json.dumps(labels,ensure_ascii=False,separators=(',',':')).encode()).hexdigest())
if (p/'mismatch-validator').exists(): receipt[(p/'mismatch-validator').read_text()]='mismatched'
if (p/'mismatch-draft').exists() and b'Approved playback' in body: receipt[(p/'mismatch-draft').read_text()]='mismatched'
if (p/'malformed-validator').exists(): print('not JSON'); sys.exit()
print(json.dumps(receipt))
''')
count = 0

def fixture(kind='pr', shared=None, author=None):
 global count
 count += 1
 p = root / str(count)
 p.mkdir()
 home = p/'home'
 (home/'data/task').mkdir(parents=True)
 media = p/'image.png'
 media.write_bytes(b'\x89PNG\r\n\x1a\n' + b'fixture' * 10)
 target = dict(host='github.com', repository='owner/repo', repository_id='R_repo', object_id='O_target', kind=kind, number=7)
 m = dict(schema=1, home=str(home), task='task', operation='op1', attempt=1,
          authority=dict(explicit=True, provenance='task approval message 42', approved_by='operator'),
          target=target, actor='approved-user', files=[dict(path=str(media), sha256=hashlib.sha256(media.read_bytes()).hexdigest(), size=media.stat().st_size, media_type='image/png', label='Approved view')])
 if kind == 'pr':
  m['source'] = dict(repository_id='R_source', head='a'*40, ref='topic')
 remote = {'/user': {'login':'approved-user'}, '/repos/owner/repo': {'node_id':'R_repo','full_name':'owner/repo','permissions':{'push':True}}, '/repos/owner/repo/'+('pulls' if kind=='pr' else 'issues')+'/7': {'node_id':'O_target','number':7,'body':'original body'}}
 if author is not None: remote['/repos/owner/repo/'+('pulls' if kind=='pr' else 'issues')+'/7']['user'] = {'login':author}
 if kind == 'pr': remote['/repos/owner/repo/pulls/7']['head'] = {'sha':'a'*40,'ref':'topic','repo':{'node_id':'R_source'}}
 (p/'remote.json').write_text(json.dumps(remote))
 env = {k:v for k,v in os.environ.items() if not any(s in k.upper() for s in ['TOKEN','AUTH','COOKIE','PASSWORD','SECRET']) and not k.startswith(('GH_','GITHUB_','FM_GITHUB_MEDIA_'))}
 env.update(PATH=str(fake)+':'+os.environ['PATH'], HOME=str(home), GH_CONFIG_DIR=str(home/'gh-empty'), FM_HOME=str(home), FM_TASK_ID='task', FM_GITHUB_MEDIA_TEST_ROOT=str(shared or p/'registry'), FIXTURE=str(p), FM_GITHUB_MEDIA_TEST_READ=str(transport))
 return p,m,env

def command(p,m,env,extra=None):
 manifest = p/'manifest.json'
 manifest.write_text(json.dumps(m))
 return ['bash',str(cli),'prepare','--manifest',str(manifest),'--',*(extra if extra is not None else [x['path'] for x in m['files']])]

def run(p,m,env,extra=None):
 return subprocess.run(command(p,m,env,extra),env=env,capture_output=True,text=True,timeout=12)

def denied(p,m,e,needle,extra=None):
 r=run(p,m,e,extra)
 assert r.returncode != 0 and needle in r.stderr, (needle,r.returncode,r.stdout,r.stderr)
 if (p/'calls').exists():
  assert all(json.loads(s)[:2]==['api','GET'] for s in (p/'calls').read_text().splitlines())
 print('ok - refused '+needle)

def inspect(p,m,e,needle=None):
 r=subprocess.run(['bash',str(cli),'inspect','--operation',m['operation']],env=e,capture_output=True,text=True,timeout=5)
 assert (r.returncode==0) if needle is None else (r.returncode!=0 and needle in r.stderr),r.stderr
 return r

def add_video(p,m):
 f=p/'clip.mp4'; data=b'\x00\x00\x00\x18ftypisom\x00\x00\x00\x00isommp42'
 f.write_bytes(data)
 m['files'].append(dict(path=str(f),size=len(data),sha256=hashlib.sha256(data).hexdigest(),media_type='video/mp4',label='Approved playback'))

def deps(p, replacements=None):
 d=dict(schema=2)
 for name,path in [('native',native),('read',transport),('validator',validator),('parser',parser)]:
  path=(replacements or {}).get(name,path)
  d[name]=dict(path=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest())
 (p/'dependencies.json').write_text(json.dumps(d))
 return p/'dependencies.json'

def publish(p,m,e,needle=None,disposition=None,dependency=None):
 args=['bash',str(cli),'publish','--operation',m['operation'],'--dependencies',str(dependency or deps(p))]
 if disposition: args+=['--disposition',str(disposition)]
 r=subprocess.run(args,env=e,capture_output=True,text=True,timeout=20)
 assert (r.returncode==0) if needle is None else (r.returncode!=0 and needle in r.stderr),(r.returncode,r.stderr)
 return r

def prepared(p,m,e):
 r=run(p,m,e); assert r.returncode==0,r.stderr
 return Path(json.loads(r.stdout)['operation_dir'])


def wait_for_file(path,proc):
 for _ in range(300):
  if path.exists(): return
  assert proc.poll() is None,proc.communicate()
  time.sleep(.02)
 raise AssertionError('synthetic process failed to reach barrier')

def wait_gone(pids):
 for _ in range(300):
  if all(not Path('/proc/'+str(pid)).exists() for pid in pids): return
  time.sleep(.02)
 raise AssertionError(('owned descendant survived',pids))
