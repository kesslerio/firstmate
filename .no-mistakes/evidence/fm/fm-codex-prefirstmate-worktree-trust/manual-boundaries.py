import os,pathlib,subprocess,hashlib,json,tomllib,shutil
root=pathlib.Path.cwd(); base=root/'.test-validation/manual'; base.mkdir()
ev=pathlib.Path('/home/art/.no-mistakes/evidence/01M3Y7D8T0561B932DK0JS6M3P')
env=dict(os.environ,GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
repo=base/'repository'; pool=base/'pool'; wt=pool/'slots/fresh'; store=base/'custom store'
store.mkdir(); pool.mkdir(); (pool/'treehouse-state.json').write_text('{}\n')
def git(*args):
 subprocess.run(['git',*map(str,args)],env=env,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
git('init',repo); git('-C',repo,'-c','user.name=Live test','-c','user.email=live@example.invalid','commit','--allow-empty','-m','fixture')
git('-C',repo,'worktree','add','-b','fresh',wt)
nonpool=base/'ordinary/worktree'; git('-C',repo,'worktree','add','-b','ordinary',nonpool)
(wt/'subdir').mkdir()
config=store/'config.toml'; original=b'# operator setting\nmodel = "gpt-6.1-sol"\n\n[projects."/unrelated/operator-project"]\ntrust_level = "untrusted"\n'
config.write_bytes(original)
log=[]
def call(name,target,project=None,ok=False,secondmate=None):
 cmd=[str(root/'bin/fm-codex-trust.sh')]
 cmd+=['--secondmate-home',str(target),secondmate] if secondmate else [str(target),str(project or repo)]
 before=config.read_bytes()
 result=subprocess.run(cmd,env=dict(env,CODEX_HOME=str(store),HOME=str(base/'home')),capture_output=True,text=True)
 log.append(f'{name}\nexit={result.returncode}\n{result.stdout}{result.stderr}')
 assert (result.returncode==0)==ok,name
 if not ok: assert config.read_bytes()==before,name+' mutated store on refusal'
call('Reject primary checkout',repo)
call('Reject ordinary linked worktree outside pool',nonpool)
call('Reject subdirectory of a qualifying worktree',wt/'subdir')
call('Approve qualifying linked pool worktree',wt,ok=True)
assert config.read_bytes().startswith(original)
parsed=tomllib.loads(config.read_text()); assert parsed['projects'][str(repo)]['trust_level']=='trusted'
assert parsed['projects']['/unrelated/operator-project']['trust_level']=='untrusted'
first=config.read_bytes(); call('Repeat approval is idempotent',wt,ok=True); assert first==config.read_bytes()
config.write_text(f'[projects.{json.dumps(str(repo))}]\ntrust_level = "untrusted"\n')
call('Refuse to overwrite operator denial',wt)
config.write_bytes(original)
sm=pool/'slots/secondmate'; git('-C',repo,'worktree','add','-b','secondmate',sm)
(sm/'.fm-secondmate-home').write_text('lab-secondmate\n'); (sm/'AGENTS.md').write_text('# Disposable seeded home\n')
for folder in ['bin','data','state','config','projects']: (sm/folder).mkdir()
call('Reject secondmate identity mismatch',sm,secondmate='wrong-id')
call('Approve seeded linked pool secondmate',sm,secondmate='lab-secondmate',ok=True)
standalone=base/'standalone'; git('init',standalone); git('-C',standalone,'-c','user.name=Live test','-c','user.email=live@example.invalid','commit','--allow-empty','-m','fixture')
(standalone/'.fm-secondmate-home').write_text('lab-secondmate\n'); (standalone/'AGENTS.md').write_text('# Disposable seeded home\n'); (standalone/'bin').mkdir()
call('Reject standalone seeded secondmate',standalone,secondmate='lab-secondmate')
assert set(path.name for path in store.iterdir())=={'config.toml'}
log.append('Readback: qualifying repository trusted; unrelated operator denial preserved; only config.toml created; no hook trust artifacts.\n')
(ev/'live-boundaries.log').write_text('\n'.join(log))
(ev/'live-boundaries-store.toml').write_bytes(config.read_bytes())
print('\n'.join(log))
shutil.rmtree(base)
