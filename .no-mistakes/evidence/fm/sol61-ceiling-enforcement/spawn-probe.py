import pathlib,os,subprocess,shutil,json,time
root=pathlib.Path.cwd(); e=pathlib.Path('/home/art/.no-mistakes/evidence/01M5416CTFJVDPWBPVA1J6A66S'); p=e/'spawn-home'; env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:env.pop(k,None)
env['FM_HOME']=str(p); cs=[]
def run(args):
 r=subprocess.run(list(map(str,args)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=35);print('$',' '.join(map(str,args)),flush=True);print(r.stdout,flush=True);return r
try:
 assert run([root/'bin/fm-lab-home.sh','create',p]).returncode==0
 (p/'config/crew-dispatch.json').write_text(json.dumps({'rules':[{'when':'Sol','use':{'harness':'codex','model':'gpt-6.1-sol'}}]}))
 (p/'config/crew-harness').write_text('codex\n');(p/'state/.last-watcher-beat').touch()
 for i in range(4):
  id='held'+str(i);assert run(['bash',root/'bin/fm-sol-cap-lib.sh','refuse-claim',id,'ship','codex','gpt-6.1-sol',p/'config',p/'state']).returncode==0
  c=subprocess.Popen(['bash',str(root/'bin/fm-sol-cap-lib.sh'),'run',id,str(p/'state'),'sleep','120'],env=env);cs.append(c)
  for _ in range(100):
   if str(c.pid) in (p/'state/sol-sessions.tsv').read_text():break
   time.sleep(.02)
 project=p/'projects/disposable'; project.mkdir();assert run(['git','init','-q',project]).returncode==0
 (p/'data/fifth').mkdir();(p/'data/fifth/brief.md').write_text('# Task\n## Captain\'s intent\nExercise the Sol ceiling.\n\n## Firstmate spec\nPerform no work.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n')
 before=run(['git','-C',project,'worktree','list','--porcelain']).stdout
 r=run([root/'bin/fm-spawn.sh','fifth',project,'--mode','no-mistakes','--yolo','off','--harness','codex','--model','gpt-6.1-sol','--backend','tmux'])
 assert r.returncode==1 and 'Sol ceiling reached' in r.stdout,r.stdout
 assert not (p/'state/fifth.meta').exists();assert not (p/'data/fifth/launch-brief.md').exists()
 assert before==run(['git','-C',project,'worktree','list','--porcelain']).stdout
 print('PASS: real fm-spawn refuses the fifth worker before creating a launch brief, task record, terminal, or worktree',flush=True)
 (p/'state/sol-sessions.tsv').write_text('broken\tgpt-6.1-sol\tnot-an-epoch\t0\n')
 r=run(['bash',root/'bin/fm-sol-cap-lib.sh','refuse-claim','broken-try','ship','codex','gpt-6.1-sol',p/'config',p/'state'])
 assert r.returncode==1 and 'malformed row' in r.stdout
 print('PASS: malformed registry refuses admission with the broken row identified',flush=True)
finally:
 for c in cs:
  if c.poll() is None:c.terminate()
 for c in cs:c.wait(timeout=5)
 shutil.rmtree(p)
 print('All disposable launch processes and the home removed',flush=True)
