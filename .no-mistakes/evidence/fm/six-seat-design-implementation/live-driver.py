import os, json, subprocess, pathlib, time, shutil, concurrent.futures
E=pathlib.Path('/Users/kesslerio/.no-mistakes/evidence/01M3RP9FKDWJ4VTFQQY8Q2R70E')
R=pathlib.Path.cwd(); L=E/'l'; log=open(E/'live-transcript.log','w',buffering=1); results=[]
env=os.environ.copy()
for k in ['FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','HERDR_SESSION','HERDR_SOCKET_PATH','HERDR_PANE_ID']:
 env.pop(k,None)
env.update(FM_HOME=str(L),TMUX_TMPDIR=str(L/'tmux'))
def run(args, home=L, expect=None, input=None, extra=None):
 ev=env.copy(); ev['FM_HOME']=str(home)
 if extra: ev.update(extra)
 p=subprocess.run([str(a) for a in args],env=ev,cwd=R,input=input,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=45)
 log.write('$ '+ ' '.join(map(str,args))+'\n'+p.stdout+'exit='+str(p.returncode)+'\n')
 if expect is not None: assert p.returncode==expect,(args,p.returncode,p.stdout)
 return p
socket=run(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path},#{pid},0'],expect=0).stdout.strip()
env['TMUX']=socket
S=R/'bin/fm-fleet-seats.sh'
def seats(*args,home=L,expect=0,input=None): return run([S,*args],home,expect,input)
def write(path, data):
 path.write_text(data if isinstance(data,str) else json.dumps(data)+'\n'); path.chmod(0o600)
def policy(home,capacity=6): write(home/'config/fleet-seats',{'pools':[{'name':'.shared','capacity':capacity,'models':['opus','sonnet']},{'name':'..other','capacity':1,'models':['haiku']}]})
def reserve(task,gen,model='opus',previous='-',home=L,kind='ship',expect=0):
 return seats('reserve',task,'--generation',gen,'--previous-generation',previous,'--kind',kind,'--harness','claude','--model',model,'--holder-pid',str(os.getpid()),home=home,expect=expect)
def show(task,home=L):
 data=json.loads(seats('show',task,home=home).stdout); log.write(json.dumps(data,indent=2)+'\n'); return data
def state(task,gen,home=L): return next(x for x in show(task,home)['incarnations'] if x['generation']==gen)
def owner(task,gen,target,kind='secondmate',home=L):
 route=home/'state'/('route-'+gen); write(route,dict(placement='local',backend='tmux',target=target,home=None,host=None,remote_root=None,spawn_gen=gen,operation=None))
 run(['bash','-c','"$1" reserve "$2" --generation "$3" --kind "$4" --harness claude --model opus --holder-pid "$$" && "$1" dispatch "$2" --generation "$3" --route-file "$5"','_',S,task,gen,kind,route],home,expect=0)
def scenario(name,fn):
 log.write('\nSCENARIO '+name+'\n')
 try:
  fn(); results.append(dict(name=name,result='pass',live=True,evidence='live-transcript.log',reason=''))
 except Exception as ex:
  log.write('FAIL '+repr(ex)+'\n'); results.append(dict(name=name,result='fail',live=True,evidence='live-transcript.log',reason=str(ex)))
def optout():
 assert reserve('off','off','default').stdout==''
 assert not (L/'state/fleet-seats/holders').exists()
 policy(L)
 reserve('implicit','implicit','default',expect=5)
 for name in ['.','..','bad/name']:
  write(L/'config/fleet-seats',{'pools':[{'name':name,'capacity':1,'models':['opus']}]})
  reserve('invalid','invalid',expect=5)
 policy(L); reserve('grammar','grammar'); seats('release','grammar','--generation','grammar','--reason','prelaunch')
scenario('No-pool launches opt out; pooled defaults and invalid names refuse while hidden pool names work',optout)
def capacity():
 child=E/'c'; run([R/'bin/fm-lab-home.sh','create',child],expect=0)
 write(child/'.fm-secondmate-parent',f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={L}\n'); write(child/'.fm-secondmate-home','child\n')
 write(L/'data/secondmates.md',f'- child - Lab mate. (home: {child}; scope: tests; projects: ; added 2026-09-30)\n')
 with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
  attempts=list(pool.map(lambda n: reserve('parallel'+str(n),'p'+str(n),home=L if n%2==0 else child,expect=None),range(12)))
 assert sum(p.returncode==0 for p in attempts)==6
 assert all(p.returncode in [0,4] for p in attempts)
 for n,p in enumerate(attempts):
  if p.returncode==0: seats('release','parallel'+str(n),'--generation','p'+str(n),'--reason','prelaunch',home=L if n%2==0 else child)
 reserve('handoff','g1'); reserve('handoff','g1'); reserve('handoff','g2',previous='g1')
 reserve('handoff','g3',previous='g2',expect=5)
 reserve('destination','d1','haiku')
 reserve('handoff','cross','haiku',previous='g2',expect=4) # unresolved earlier generation fences this request
 seats('release','handoff','--generation','g2','--reason','prelaunch')
 reserve('handoff','cross','haiku',previous='g1',expect=4)
 seats('release','destination','--generation','d1','--reason','prelaunch')
 reserve('handoff','cross','haiku',previous='g1')
 seats('release','handoff','--generation','cross','--reason','prelaunch'); seats('release','handoff','--generation','g1','--reason','prelaunch')
 reserve('handoff','g1',expect=5)
scenario('Concurrent homes share six seats, retries count once, and relaunch candidates respect destination capacity and terminal fencing',capacity)
def buffer():
 run(['tmux','-L','fm-lab','new-window','-d','-t','primary:','-n','fm-buffer','bash'],expect=0)
 owner('buffer','buffer1','primary:fm-buffer')
 seats('reclaim','buffer','--generation','buffer1',expect=3)
 seats('release','buffer','--generation','buffer1','--reason','prelaunch',expect=5)
 seats('release','buffer','--generation','buffer1','--reason','cancelled',expect=3)
 assert state('buffer','buffer1')['lifecycle']=='reserved'
 run(['tmux','-L','fm-lab','kill-window','-t','primary:fm-buffer'],expect=0)
 seats('release','buffer','--generation','buffer1','--reason','cancelled',expect=3)
 assert state('buffer','buffer1')['lifecycle']=='reserved'
scenario('A submitted shell endpoint stays counted after owner death; tmux disappearance without socket proof also stays counted',buffer)
def confirmation():
 run(['tmux','-L','fm-lab','rename-window','-t','primary','fm-live'],expect=0)
 owner('live','live1','primary:fm-live')
 seats('confirm','live','--generation','live1')
 assert state('live','live1')['startup_confirmed'] is True
 seats('reclaim','live','--generation','live1',expect=3)
 assert state('live','live1')['lifecycle']=='confirmed'
 # Lifecycle episode held by a real process; child may adopt, unrelated process may not.
 lockscript='''. "$1/bin/fm-secondmate-liveness-lib.sh"; fm_supervisor_lifecycle_acquire "$FM_HOME/state" live 0 || exit 1; "$1/bin/fm-fleet-seats.sh" confirm live --generation live1 || exit 2; echo ready > "$2"; while [ ! -f "$3" ]; do sleep 0.05; done; fm_supervisor_lifecycle_release "$FM_HOME/state" live'''
 ev=env.copy(); proc=subprocess.Popen(['bash','-c',lockscript,'_',str(R),str(E/'lock-ready'),str(E/'lock-stop')],env=ev,stdout=log,stderr=log)
 try:
  for _ in range(100):
   if (E/'lock-ready').exists(): break
   time.sleep(.05)
  assert (E/'lock-ready').exists()
  seats('confirm','live','--generation','live1',expect=5)
 finally:
  (E/'lock-stop').touch(); proc.wait(timeout=10)
 seats('confirm','live','--generation','live1')
 (E/'lock-ready').unlink(missing_ok=True); (E/'lock-stop').unlink(missing_ok=True)
scenario('Real Claude startup confirms its exact seat, live reclamation refuses, and lifecycle mutex ownership allows only verified descendants',confirmation)
def legacy():
 run(['tmux','-L','fm-lab','new-window','-d','-t','primary:','-n','fm-recover','-c',str(R),'bash'],expect=0)
 run(['tmux','-L','fm-lab','send-keys','-t','primary:fm-recover','CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude','Enter'],expect=0)
 time.sleep(3)
 owner('recover','recover1','primary:fm-recover')
 seats('confirm','recover','--generation','recover1')
 write(L/'state/recover.meta',f'kind=secondmate\nharness=claude\nmodel=opus\nspawn_gen=recover1\nbackend=tmux\nwindow=primary:fm-recover\nendpoint_task_id=recover\nworktree={R}\nproject={R}\n')
 h=E/'v'; run([R/'bin/fm-lab-home.sh','create',h],expect=0); policy(h,1)
 write(h/'state/recover.meta',f'kind=secondmate\nharness=claude\nmodel=opus\nspawn_gen=legacy1\nbackend=tmux\nwindow=primary:fm-recover\nendpoint_task_id=recover\nworktree={R}\nproject={R}\n')
 st=str(h/'state'); p=subprocess.run(['cksum'],input=st+'\trecover',text=True,stdout=subprocess.PIPE,check=True).stdout.split(); name='-'.join(p[:2])
 (h/'state/fleet-seats/legacy').mkdir(parents=True)
 write(h/'state/fleet-seats/legacy'/f'{name}.seat',f'state={st}\ntask=recover\nmodel=opus\npid=99999999\npid_identity=\n')
 reserve('contender','contender',home=h,expect=4)
 assert state('recover','legacy1',h)['route']['spawn_gen']=='legacy1'
 assert not (h/'state/fleet-seats/legacy'/f'{name}.seat').exists()
 seats('confirm','recover','--generation','legacy1',home=h)
 assert state('recover','legacy1',h)['startup_confirmed']
scenario('A v1 holder imports once with a generation-bound route and confirms against the running Claude endpoint',legacy)
def remote_serve():
 h=E/'r'; run([R/'bin/fm-lab-home.sh','create',h],expect=0)
 write(h/'.fm-secondmate-parent','schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=disposable-primary\n'); write(h/'.fm-secondmate-home','remote\n')
 policy(h,1); body=(h/'config/fleet-seats').read_text()
 def digest():
  p=subprocess.run(['bash','-c','jq -cS . "$1" | cksum | tr -s " " "-" | cut -d- -f1-2','_',str(h/'config/fleet-seats')],text=True,stdout=subprocess.PIPE,check=True); return p.stdout.strip()
 d=digest()
 first=seats('serve','--digest',d,'--epoch','lab.1','--allowance','.shared=1','--allowance','..other=1',home=h,input=body).stdout
 assert json.loads(first)['complete'] is True
 replay=seats('serve','--digest',d,'--epoch','lab.1','--allowance','.shared=0',home=h,input=body).stdout
 assert json.loads(first)==json.loads(replay)
 seats('serve','--digest',d,'--epoch','lab.0',home=h,input=body,expect=5)
 policy(h,2); changed=(h/'config/fleet-seats').read_text(); changed_digest=digest()
 seats('serve','--digest',changed_digest,'--epoch','lab.1',home=h,input=changed,expect=5)
 policy(h,1)
 ev=env.copy(); ev['FM_HOME']=str(h)
 proc=subprocess.Popen([str(S),'reserve','remote-worker','--generation','remote1','--harness','claude','--model','opus','--holder-pid',str(os.getpid())],env=ev,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 try:
  for _ in range(100):
   if list((h/'state/fleet-seats/requests').glob('*.req')): break
   time.sleep(.05)
  assert list((h/'state/fleet-seats/requests').glob('*.req'))
  cert=json.loads(seats('serve','--digest',d,'--epoch','lab.2','--allowance','.shared=1',home=h,input=body).stdout)
  output,_=proc.communicate(timeout=5); log.write(output+'exit='+str(proc.returncode)+'\n'); assert proc.returncode==0
  assert any(x['task']=='remote-worker' and x['generation']=='remote1' for x in cert['holders'])
  write(E/'remote-certificate.json',cert)
 finally:
  if proc.poll() is None: proc.terminate(); proc.wait(timeout=5)
scenario('Remote serving grants a real queued request, publishes a complete certificate, replays epochs without regranting, and rejects stale or conflicting epochs',remote_serve)
def death():
 run([R/'bin/fm-control.sh','recover','exit'],expect=0,extra={'FM_CONTROL_EXIT_WAIT':'10','FM_CONTROL_POLL':'0.1'})
 seats('reclaim','recover','--generation','recover1')
 assert state('recover','recover1')['lifecycle']=='reclaimed'
 seats('reclaim','recover','--generation','legacy1',home=E/'v')
 assert state('recover','legacy1',E/'v')['lifecycle']=='reclaimed'
 reserve('recover','recover1',kind='secondmate',expect=5)
 seats('reclaim','recover','--generation','recover1')
 assert state('recover','recover1')['lifecycle']=='reclaimed'
 run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary:fm-live'],expect=0)
 run(['tmux','-L','fm-lab','kill-server'],expect=0)
scenario('A confirmed Claude task exits through real control; its recorded and imported legacy generations reclaim without reviving on stale retries',death)
run(['tmux','-L','fm-lab','kill-server'],expect=None)
write(E/'live-results.json',results)
for path in [L,E/'c',E/'r',E/'v']:
 if path.exists(): shutil.rmtree(path)
log.write('TEARDOWN: private tmux server stopped; all disposable homes removed\n')
log.close()
print(json.dumps(results,indent=2))
