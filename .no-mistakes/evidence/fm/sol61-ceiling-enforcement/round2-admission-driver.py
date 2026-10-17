import os, pathlib, subprocess, time, json, shutil
root=pathlib.Path.cwd(); base=root/'.test-sol-lab'; evidence=pathlib.Path('/home/art/.no-mistakes/evidence/01M53EGCQXW2H51Q8EPQ12MT36'); log=open(evidence/'round2-live-admission.log','w',buffering=1)
env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','TASKS_AXI_FILE','TASKS_AXI_BACKEND']: env.pop(k,None)
env['TMPDIR']=str(base/'tmp')
(base/'tmp').mkdir(parents=True,exist_ok=True)
children=[]
def note(s): print(s,flush=True); log.write(s+'\n')
def call(args,home,expected=0):
 e=env|{'FM_HOME':str(home)}
 p=subprocess.run(args,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=25)
 note('$ '+' '.join(map(str,args))+'\n'+p.stdout+'exit='+str(p.returncode))
 assert p.returncode==expected,(p.returncode,expected,p.stdout)
 return p.stdout
def make(name):
 h=base/name; call(['bin/fm-lab-home.sh','create',str(h)],h)
 (h/'config/crew-dispatch.json').write_text(json.dumps({'rules':[{'when':'Sol','use':[{'harness':'codex','model':'gpt-6.1-sol'},{'harness':'codex','model':'gpt-6-sol'}]}],'default':{'harness':'codex','model':'gpt-9.9-sol'}}))
 return h
def claim(h,id,model='gpt-6.1-sol',rc=0,state=None):
 return call(['bash','bin/fm-sol-cap-lib.sh','refuse-claim',id,'ship','codex',model,str(h/'config'),str(state or h/'state')],h,rc)
def start(h,id,model='gpt-6.1-sol',state=None):
 state=state or h/'state'
 script='source bin/fm-wake-lib.sh; source bin/fm-secondmate-registry-lib.sh; source bin/fm-sol-cap-lib.sh; fm_sol_cap_refuse_and_claim "$1" ship codex "$2" "$FM_HOME/config" "$3" || { echo "$FM_SOL_CAP_REFUSAL"; exit 1; }; exec bash bin/fm-sol-cap-lib.sh run "$1" "$3" sleep 300'
 p=subprocess.Popen(['bash','-c',script,'live',id,model,str(state)],env=env|{'FM_HOME':str(h)},stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True); children.append(p)
 for _ in range(100):
  if p.poll() is not None: return p
  f=state/'sol-sessions.tsv'
  if f.exists() and any(row.split('\t')[0]==id and row.split('\t')[3]==str(p.pid) for row in f.read_text().splitlines()):
   note('RUN '+id+' model='+model+' live pid='+str(p.pid)); return p
  time.sleep(.05)
 raise Exception('worker not promoted')
def stop(p):
 if p.poll() is None: p.terminate(); p.wait(timeout=5)
try:
 h=make('home')
 note('SCENARIO derived model set including future default profile')
 assert set(call(['bash','bin/fm-sol-cap-lib.sh','models',str(h/'config')],h).strip().split('|'))=={'gpt-6-sol','gpt-6.1-sol','gpt-9.9-sol'}
 ps=[start(h,'worker-'+str(i),m) for i,m in enumerate(['gpt-6.1-sol','gpt-6-sol','gpt-9.9-sol','gpt-6.1-sol'])]
 assert all(p.poll() is None for p in ps)
 note('SCENARIO fifth Sol refused with four live process workers')
 assert 'Sol ceiling reached' in claim(h,'fifth',rc=1)
 note((h/'state/sol-sessions.tsv').read_text())
 note('SCENARIO GLM, qwen and default bypass a full ceiling without registry mutation')
 before=(h/'state/sol-sessions.tsv').read_bytes()
 for m in ['glm-5','qwen3','default']: claim(h,'lane-'+m,m)
 assert before==(h/'state/sol-sessions.tsv').read_bytes()
 note('SCENARIO dead positive PID frees a slot and is pruned')
 stop(ps[-1]); replacement=start(h,'replacement'); assert replacement.poll() is None
 assert 'worker-3\t' not in (h/'state/sol-sessions.tsv').read_text()
 note('SCENARIO two homes compete for one remaining slot')
 stop(replacement)
 mate=make('mate'); (mate/'.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={h}\n')
 (h/'data/secondmates.md').write_text(f'- mate - local mate (home: {mate}; scope: work; projects: project; added 2026-10-16)\n')
 # Start simultaneously; each winner stays alive, preventing a stale-reservation false pass.
 script='source bin/fm-wake-lib.sh; source bin/fm-secondmate-registry-lib.sh; source bin/fm-sol-cap-lib.sh; fm_sol_cap_refuse_and_claim "$1" ship codex gpt-6.1-sol "$FM_HOME/config" "$FM_HOME/state" || { echo "$FM_SOL_CAP_REFUSAL"; exit 1; }; exec bash bin/fm-sol-cap-lib.sh run "$1" "$FM_HOME/state" sleep 300'
 racers=[]
 for home,id in [(h,'race-root'),(mate,'race-mate')]:
  p=subprocess.Popen(['bash','-c',script,'live',id],env=env|{'FM_HOME':str(home)},stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True); children.append(p); racers.append(p)
 time.sleep(2)
 assert sum(p.poll() is None for p in racers)==1
 for p in racers:
  if p.poll() is not None: note('race loser: '+p.stdout.read()); assert p.returncode==1
 note('exactly one racer remains live; other refused'); claim(mate,'cross-home-fifth',rc=1)
 for p in racers: stop(p)
 note('SCENARIO lower-only cap and malformed configuration fail closed for Sol only')
 (h/'config/sol-cap').write_text('2\n'); assert 'ceiling is 2' in claim(h,'lowered',rc=1)
 (h/'config/sol-cap').write_text('5\n'); assert '1 through 4' in claim(h,'raised',rc=1)
 (h/'config/crew-dispatch.json').write_text('{broken'); assert 'cannot be read' in claim(h,'broken',rc=1)
 for m in ['glm-5','qwen3']: claim(h,'broken-'+m,m)
 note('SCENARIO nested remote parent-route shares admission with host-local crew')
 remote=make('remote-layout'); route=remote/'state/parent-route'; route.mkdir()
 rp=start(remote,'remote-self',state=route)
 crew=[start(remote,'crew-'+str(i)) for i in range(3)]
 claim(remote,'crew-fifth',rc=1); claim(remote,'route-fifth',state=route,rc=1)
 note('SCENARIO pid-zero uncertain delivery blocks replacement')
 (remote/'state/sol-sessions.tsv').open('a').write('uncertain\tgpt-6.1-sol\t1\t0\n')
 assert 'already holds a live or uncertain session' in claim(remote,'uncertain',rc=1)
 note('LIVE ADMISSION SCENARIOS PASSED')
finally:
 for p in children: stop(p)
 note('Cleanup: all owned worker PIDs exited')
 shutil.rmtree(base)
 log.close()
