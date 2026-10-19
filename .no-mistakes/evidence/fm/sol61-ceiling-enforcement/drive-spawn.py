import os,pathlib,subprocess,shlex,time,shutil
root=pathlib.Path.cwd(); lab=root/'.lab'; ev=pathlib.Path('/home/art/.no-mistakes/evidence/01M5A0WQ2ZM7C94Z0R7M8EDB3K'); env=os.environ.copy()
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']: env.pop(k,None)
assert not lab.exists()
subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],check=True,capture_output=True)
(lab/'tmux').mkdir(); env['TMUX_TMPDIR']=str(lab/'tmux'); env['FM_HOME']=str(lab)
def tm(*a,check=True):return subprocess.run(['tmux','-L','fm-lab',*a],env=env,text=True,capture_output=True,check=check)
try:
 (lab/'config/supervision-host').touch()
 (lab/'config/crew-harness').write_text('codex\n')
 (lab/'config/crew-dispatch.json').write_text('{"default":{"harness":"codex","model":"gpt-6.1-sol"}}')
 (lab/'state/sol-sessions.tsv').write_text(''.join(f'live{i}\tgpt-6.1-sol\t{int(time.time())}\t0\n' for i in range(4)))
 brief=lab/'data/fifth/brief.md'; brief.parent.mkdir()
 brief.write_text("# Task\n## Captain's intent\nExercise admission refusal without launching work.\n\n## Firstmate spec\nVerify the ceiling.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n")
 project=lab/'project'; project.mkdir()
 subprocess.run(['git','init','-q',str(project)],check=True)
 tm('new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e','FM_HOME='+str(lab),'codex')
 time.sleep(5)
 ev.joinpath('primary-capture.txt').write_text(tm('capture-pane','-p','-t','primary').stdout)
 out=ev/'spawn-refusal.txt'; done=lab/'exit-code'
 command=' '.join(shlex.quote(str(x)) for x in [root/'bin/fm-spawn.sh','fifth',project,'--harness','codex','--model','gpt-6.1-sol','--mode','no-mistakes','--yolo','off'])
 command+=' > '+shlex.quote(str(out))+' 2>&1; printf "%s\\n" "$?" > '+shlex.quote(str(done))
 tm('new-window','-t','primary','-n','admission','-c',str(root),command)
 for _ in range(40):
  if done.exists():break
  time.sleep(.5)
 print(out.read_text() if out.exists() else 'No spawn output')
 print('exit:',done.read_text() if done.exists() else 'timeout')
 assert done.exists() and done.read_text().strip()=='1'
 assert 'Sol ceiling reached' in out.read_text()
 assert not (lab/'state/fifth.meta').exists()
 assert not (lab/'data/fifth/launch-brief.md').exists()
 print('Normal spawn refused fifth dispatch before task publication')
finally:
 tm('kill-server',check=False)
 r=tm('list-sessions',check=False)
 ev.joinpath('lab-cleanup.txt').write_text('Private server stopped: '+str(r.returncode!=0)+'\n'+r.stderr)
 shutil.rmtree(lab)
