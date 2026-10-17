import os, pathlib, subprocess, time, json, shutil
root=pathlib.Path.cwd(); evidence=pathlib.Path('/home/art/.no-mistakes/evidence/01M5416CTFJVDPWBPVA1J6A66S'); base=evidence/'fixtures'
base.mkdir(exist_ok=True)
env=os.environ.copy()
for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:
 env.pop(key,None)
children=[]; results=[]
lib=root/'bin/fm-sol-cap-lib.sh'
def home(name):
 p=base/name; subprocess.run([str(root/'bin/fm-lab-home.sh'),'create',str(p)],env=env,check=True,stdout=subprocess.DEVNULL)
 (p/'config/crew-dispatch.json').write_text(json.dumps({'rules':[{'when':'Sol','use':[{'harness':'codex','model':'gpt-6.1-sol'},{'harness':'codex','model':'gpt-6-sol'}]}],'default':{'harness':'codex','model':'gpt-9.9-sol'}}))
 return p
def call(p,*args,expect=0):
 e=env|{'FM_HOME':str(p)}
 r=subprocess.run(['bash',str(lib),*map(str,args)],env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=20)
 print('$ FM_HOME=<'+p.name+'> fm-sol-cap-lib.sh '+' '.join(map(str,args)),flush=True); print(r.stdout.strip(),flush=True)
 assert r.returncode==expect,(r.returncode,expect,r.stdout)
 return r.stdout

def claim(p,id,model='gpt-6.1-sol',expect=0):
 return call(p,'refuse-claim',id,'ship','codex',model,p/'config',p/'state',expect=expect)
def rows(p):
 f=p/'state/sol-sessions.tsv'; return [x.split('\t') for x in f.read_text().splitlines()] if f.exists() else []
def launch(p,id):
 claim(p,id)
 worker=subprocess.Popen(['bash',str(lib),'run',id,str(p/'state'),'sleep','180'],env=env|{'FM_HOME':str(p)})
 children.append(worker)
 for i in range(100):
  if any(r[0]==id and r[3]==str(worker.pid) for r in rows(p)): break
  time.sleep(.02)
 else: raise AssertionError('launcher did not promote')
 print('Actual launch-hook worker PID:',worker.pid,'registry:',rows(p),flush=True)
 return worker

def done(name): results.append({'name':name,'result':'pass'}); print('SCENARIO PASS:',name,flush=True)
try:
 p=home('ceiling'); models=call(p,'models',p/'config'); assert models.strip()=='gpt-6-sol|gpt-6.1-sol|gpt-9.9-sol'
 workers=[launch(p,'worker-'+str(i)) for i in range(4)]
 out=claim(p,'fifth','gpt-9.9-sol',expect=1); assert '4 concurrent' in out
 done('Derived model set admits four real launch-hook processes and refuses the fifth, including a newly configured Sol model')
 before=(p/'state/sol-sessions.tsv').read_bytes()
 for model in ['glm-5','qwen3']:
  claim(p,model,model)
  assert (p/'state/sol-sessions.tsv').read_bytes()==before
 done('GLM and qwen admissions bypass a full Sol registry without changing occupancy')
 claim(p,'worker-0',expect=1)
 workers[0].terminate(); workers[0].wait(); replacement=launch(p,'replacement')
 claim(p,'sixth',expect=1)
 done('A live worker cannot be replaced; a confirmed process exit frees exactly one slot')
 (p/'config/sol-cap').write_text('2\n'); call(p,'ceiling',p/'config'); claim(p,'lowered',expect=1)
 (p/'config/sol-cap').write_text('5\n'); claim(p,'invalid-cap',expect=1)
 (p/'config/crew-dispatch.json').write_text('{broken')
 claim(p,'broken-config',expect=1)
 for model in ['glm-5','qwen3']: claim(p,model,model)
 done('Lower-only ceiling and unreadable dispatch configuration refuse Sol while GLM and qwen remain admitted')
 p=home('parallel')
 ws=[launch(p,'held-'+str(i)) for i in range(3)]
 # Each contender keeps its admission process alive after claiming, just as a real spawn does before delivery.
 script='. "$PWD/bin/fm-wake-lib.sh"; . "$PWD/bin/fm-secondmate-registry-lib.sh"; . "$PWD/bin/fm-sol-cap-lib.sh"; if fm_sol_cap_refuse_and_claim "$1" ship codex gpt-6.1-sol "$FM_HOME/config" "$FM_HOME/state"; then echo ADMITTED; sleep 3; else echo "$FM_SOL_CAP_REFUSAL"; exit 1; fi'
 a=subprocess.Popen(['bash','-c',script,'driver','race-a'],env=env|{'FM_HOME':str(p)},stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 b=subprocess.Popen(['bash','-c',script,'driver','race-b'],env=env|{'FM_HOME':str(p)},stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 children.extend([a,b]); ao=a.communicate(timeout=15)[0]; bo=b.communicate(timeout=15)[0]; print('Concurrent admission A:',a.returncode,ao,'B:',b.returncode,bo,flush=True)
 assert sorted([a.returncode,b.returncode])==[0,1]
 done('Two simultaneous dispatches competing for the fourth slot admit exactly one')
 p=home('queued'); ws=[launch(p,'held-'+str(i)) for i in range(3)]
 call(p,'record-actual','queued','gpt-6.1-sol',p/'state')
 (p/'state/queued.meta').write_text('model=gpt-6.1-sol\nwindow=primary:queued\nharness=codex\nkind=ship\n')
 claim(p,'fifth',expect=1); assert next(r for r in rows(p) if r[0]=='queued')[3]=='0'
 done('An uncertain queued delivery retains the fourth slot after its submitting process exits')
 p=home('actual'); call(p,'record-actual','reused','gpt-6.1-sol',p/'state'); claim(p,'default-retry','default')
 call(p,'record-actual','reused','glm-5',p/'state'); assert rows(p)==[]
 done('Confirmed actual-route reports preserve Sol occupancy and release it for a non-Sol replacement')
 p=home('shared'); child=home('child')
 (child/'.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=local\nparent_home='+str(p)+'\n')
 (p/'data/secondmates.md').write_text('- child - local child (home: '+str(child)+'; scope: work; projects: project; added 2026-10-16)\n')
 ws=[launch(p,'root-'+str(i)) for i in range(3)]; launch(child,'child-worker'); claim(p,'root-fifth',expect=1); claim(child,'child-fifth',expect=1)
 done('Parent and local secondmate homes share the same four-session ceiling')
finally:
 for c in children:
  if c.poll() is None: c.terminate()
 for c in children:
  try:c.wait(timeout=5)
  except subprocess.TimeoutExpired:c.kill();c.wait()
 print('All launch-hook and race processes stopped:',all(c.poll() is not None for c in children),flush=True)
 shutil.rmtree(base)
 (evidence/'live-results.json').write_text(json.dumps(results,indent=2))
