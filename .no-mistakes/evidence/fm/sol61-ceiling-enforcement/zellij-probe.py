import pathlib,os,subprocess,pty,fcntl,termios,struct,time,threading,shutil,signal
root=pathlib.Path.cwd(); e=pathlib.Path('/home/art/.no-mistakes/evidence/01M5416CTFJVDPWBPVA1J6A66S'); h=e/'z';h.mkdir();(h/'s').mkdir();(h/'runtime').mkdir(mode=0o700)
env=os.environ.copy()
for k in ['ZELLIJ','ZELLIJ_SESSION_NAME','TMUX','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE']:env.pop(k,None)
env.update({'HOME':str(h),'FM_HOME':str(h),'XDG_CONFIG_HOME':str(h/'config'),'XDG_DATA_HOME':str(h/'data'),'XDG_CACHE_HOME':str(h/'cache'),'XDG_RUNTIME_DIR':str(h/'runtime'),'ZELLIJ_SOCKET_DIR':str(h/'s'),'PATH':str(e/'zellij-bin')+':'+env['PATH'],'TERM':'xterm-256color','FM_ZELLIJ_SESSION':'fm-lab-sol'})
subprocess.run([str(root/'bin/fm-lab-home.sh'),'create',str(h/'fm')],env=env,check=True);env['FM_HOME']=str(h/'fm')
pid,master=pty.fork()
if pid==0:
 fcntl.ioctl(0,termios.TIOCSWINSZ,struct.pack('HHHH',40,120,0,0))
 os.execvpe('zellij',['zellij','--session','fm-lab-sol'],env)
def drain():
 try:
  while os.read(master,65536):pass
 except OSError:pass
thread=threading.Thread(target=drain,daemon=True);thread.start()
try:
 for i in range(100):
  r=subprocess.run(['zellij','list-sessions','--short','--no-formatting'],env=env,capture_output=True,text=True)
  if 'fm-lab-sol' in r.stdout:break
  time.sleep(.1)
 else:raise RuntimeError('private Zellij session did not register')
 time.sleep(2)
 script='''set -e
. bin/fm-backend.sh
fm_backend_source zellij
pair=$(fm_backend_zellij_create_task fm-lab-sol fm-proof "$PWD")
echo "Created private tab/pane: $pair"
tab=${pair%% *}; pane=${pair##* }
fm_backend_zellij_cli fm-lab-sol action list-tabs --json
fm_backend_zellij_kill "fm-lab-sol:$pane" "$tab" fm-proof
fm_backend_zellij_target_absent fm-lab-sol "$pane" "$tab" fm-proof
echo 'PASS: owned endpoint closed and fresh pane/tab inventories prove absence'
fm_backend_zellij_kill "fm-lab-sol:$pane" "$tab" fm-proof
echo 'PASS: repeated close confirms absence'
if fm_backend_zellij_target_absent fm-lab-sol 0 '' ''; then echo 'Unexpectedly absent keeper pane'; exit 1; fi
echo 'PASS: a still-live pane fails the absence proof'
'''
 r=subprocess.run(['bash','-c',script],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=25);print(r.stdout,flush=True);assert r.returncode==0,r.returncode
finally:
 subprocess.run(['zellij','kill-session','fm-lab-sol'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=8)
 try:os.kill(pid,signal.SIGTERM)
 except ProcessLookupError:pass
 os.waitpid(pid,0);os.close(master)
 r=subprocess.run(['zellij','list-sessions','--short','--no-formatting'],env=env,text=True,capture_output=True)
 print('Owned session absent after cleanup:','fm-lab-sol' not in r.stdout,flush=True)
 shutil.rmtree(h);shutil.rmtree(e/'zellij-bin')
