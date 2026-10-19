import os, pathlib, subprocess, json, shutil, time, concurrent.futures
root=pathlib.Path.cwd(); lab=root/'.ceiling-live-lab'; evidence=pathlib.Path('/home/art/.no-mistakes/evidence/01M5A0WQ2ZM7C94Z0R7M8EDB3K'); log=[]
env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS']: env.pop(k,None)
assert not lab.exists()
subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],check=True,capture_output=True)
env['FM_HOME']=str(lab); cfg=lab/'config'; state=lab/'state'; reg=state/'sol-sessions.tsv'
def call(*args,expected=0):
 p=subprocess.run(['bin/fm-sol-cap-lib.sh',*map(str,args)],env=env,text=True,capture_output=True,timeout=18)
 log.append({'command':'fm-sol-cap-lib.sh '+' '.join(map(str,args)).replace(str(lab),'$LAB'),'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
 assert p.returncode==expected, log[-1]
 return p.stdout.strip()
def claim(id,model='gpt-6.1-sol',expected=0): return call('refuse-claim',id,'ship','codex',model,cfg,state,expected=expected)
def seed(n):
 reg.write_text(''.join(f's{i}\tgpt-6.1-sol\t{int(time.time())}\t0\n' for i in range(n)))
try:
 cfg.joinpath('crew-dispatch.json').write_text(json.dumps({'rules':[{'when':'sol','use':[{'harness':'codex','model':'gpt-6.1-sol'},{'harness':'codex','model':'gpt-6-sol'},{'harness':'pi','model':'glm-5'}]}],'default':{'harness':'pi','model':'qwen3'}}))
 assert call('models',cfg)=='gpt-6-sol|gpt-6.1-sol'
 assert call('ceiling',cfg)=='4'
 seed(3); claim('fourth'); assert len(reg.read_text().splitlines())==4
 # Persist launch ownership using the real launch wrapper, which execs the supplied command.
 call('run','fourth',state,shutil.which('true'))
 # Dead process with no metadata can now be pruned; replace with conservative delivery claim.
 call('record-actual','fourth','gpt-6.1-sol',state)
 denied=claim('fifth',expected=1); assert 'Sol ceiling reached' in denied and 's0' in denied
 before=reg.read_bytes(); claim('glm','glm-5'); claim('qwen','qwen3'); assert reg.read_bytes()==before
 # Four concurrent processes compete for one remaining slot. PID-0 rows keep successful reservations occupied after callers exit.
 seed(3)
 def race(i):
  p=subprocess.run(['bin/fm-sol-cap-lib.sh','refuse-claim',f'race{i}','ship','codex','gpt-6.1-sol',str(cfg),str(state)],env=env,text=True,capture_output=True)
  # admission reserves the caller pid; keep the process alive with the real shell API to exercise simultaneous ownership
  return p
 # Use a shell that invokes the real admission function then stays alive until all other contenders have returned.
 procs=[]
 script='. bin/fm-wake-lib.sh; . bin/fm-secondmate-registry-lib.sh; . bin/fm-sol-cap-lib.sh; if fm_sol_cap_refuse_and_claim "$1" ship codex gpt-6.1-sol "$FM_HOME/config" "$FM_HOME/state"; then echo admitted; sleep 4; else echo "$FM_SOL_CAP_REFUSAL"; exit 1; fi'
 for i in range(4): procs.append(subprocess.Popen(['bash','-c',script,'drive',f'race{i}'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE))
 results=[(p.communicate(timeout=15),p.returncode) for p in procs]
 log.append({'scenario':'four concurrent admissions for one slot','results':results,'registry':reg.read_text()})
 assert sum(rc==0 for _,rc in results)==1
 seed(2); cfg.joinpath('sol-cap').write_text('2\n'); assert 'this ceiling is 2' in claim('lowered',expected=1)
 cfg.joinpath('sol-cap').write_text('5\n'); assert 'one integer from 1 through 4' in claim('raised',expected=1)
 cfg.joinpath('sol-cap').unlink(); cfg.joinpath('crew-dispatch.json').write_text('{broken')
 claim('bad-table',expected=1); before=reg.read_bytes(); claim('glm-bad-table','glm-5'); assert reg.read_bytes()==before
 # Restore table and exercise confirmed actual-model reconciliation including adopted and stopped records.
 cfg.joinpath('crew-dispatch.json').write_text('{"default":{"harness":"codex","model":"gpt-6.1-sol"}}')
 reg.write_text(f'adopted\tgpt-6.1-sol\t{int(time.time())}\t-2\n')
 call('record-actual','adopted','gpt-6.1-sol',state); assert reg.read_text().strip().endswith('\t-2')
 call('record-actual','adopted','glm-5',state); assert reg.read_text()==''
 reg.write_text(f'stopped\tgpt-6.1-sol\t{int(time.time())}\t-1\n')
 state.joinpath('stopped.meta').write_text('model=gpt-6.1-sol\n')
 lock=state/'.sol-cap.lock'; lock.mkdir(); lock.joinpath('pid').write_text(str(os.getpid())+'\n')
 before=reg.read_bytes(); t=time.monotonic()
 call('record-actual','stopped','glm-5',state); claim('glm-under-lock','glm-5'); claim('qwen-under-lock','qwen3'); assert time.monotonic()-t<3 and reg.read_bytes()==before
 log.append({'scenario':'stopped Sol marker and GLM/qwen bypass live held lock','elapsed_seconds':time.monotonic()-t,'registry':reg.read_text()})
 print('All direct product CLI scenarios passed')
finally:
 evidence.joinpath('ceiling-cli-transcript.json').write_text(json.dumps(log,indent=2)+'\n')
 shutil.rmtree(lab)
