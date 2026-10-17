import os,json,hashlib,subprocess,socket,pathlib
with open('/dev/null','w') as f: f.write('preflight')
p=json.load(open('/expected.json'))
def sha(f): return hashlib.sha256(pathlib.Path(f).read_bytes()).hexdigest()
def run(*args):return subprocess.check_output(args,text=True).strip()
assert sha(os.environ['WORK']+'/.git')==p['dotgit']
assert sha(p['gitdir']+'/index')==p['index']
assert run('git','-C',os.environ['WORK'],'rev-parse','HEAD')==p['head']
assert run('git','-C',os.environ['WORK'],'rev-parse','--git-common-dir')==p['common']
assert run('git','-C',os.environ['WORK'],'log','-1','--format=%H')==p['head']
assert {k:os.environ.get(k) for k in p['markers']}==p['markers']
for f in [os.environ['WORK']+'/.git',p['gitdir']+'/index']:
 try: fd=os.open(f,os.O_WRONLY);os.close(fd)
 except OSError:pass
 else:raise AssertionError('write permitted: '+f)
for f in ['/home/art/.codex/installation_id','/tmp/nm1486-native-proof-LUktrlG0/codex-native-runtime/installation_id','/home/art/.claude.json','/home/art/.pi','/home/art/projects','/home/art/.no-mistakes/state','/home/art/.no-mistakes/repos/9f75ec418609.git/no-mistakes-gate-config',p['common']+'/worktrees/foreign','/run/user/1000','/tmp/tmux-1000']:
 assert not os.access(f,os.R_OK), 'protected path accessible: '+f
status=pathlib.Path('/proc/self/status').read_text()
for key in ['CapInh','CapPrm','CapEff','CapBnd','CapAmb']:
 assert int(next(l.split()[1] for l in status.splitlines() if l.startswith(key+':')),16)==0,key
assert 'NoNewPrivs:\t1' in status
assert subprocess.run(['mount','-o','remount,rw',os.environ['WORK']],capture_output=True).returncode!=0
assert subprocess.run(['mount','-t','tmpfs','tmpfs','/home/art'],capture_output=True).returncode!=0
assert not os.path.exists('/proc/1/root/home/art/.codex/installation_id')
assert run('ip','-o','link','show').count('\n')==0 and 'lo:' in run('ip','-o','link','show')
s=socket.socket();s.settimeout(.2)
assert s.connect_ex(('1.1.1.1',443))!=0;s.close()
s=socket.socket();s.bind(('127.0.0.1',0));s.listen();s.close()
assert run('getent','passwd','0').split(':')[5]=='/synthetic-home'
print('PREFLIGHT PASS: authentic source/history/index and marker equality; readonly source/index; protected paths absent; private PID/proc/network; loopback allowed; caps empty; remount/unmask denied; disposable account home',flush=True)
