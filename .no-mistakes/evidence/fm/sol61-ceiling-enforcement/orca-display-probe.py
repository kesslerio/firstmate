import subprocess,pathlib,os,time,signal,shutil
p=pathlib.Path('/home/art/.no-mistakes/evidence/01M5416CTFJVDPWBPVA1J6A66S'); display=p/'x-display'; h=p/'orca-home'; h.mkdir(exist_ok=True)
with display.open('w') as d, (p/'xvfb.log').open('w') as xl:
 x=subprocess.Popen(['Xvfb','-displayfd',str(d.fileno()),'-screen','0','1280x800x24','-nolisten','tcp'],pass_fds=(d.fileno(),),stdout=xl,stderr=xl,start_new_session=True)
 server=None
 try:
  for _ in range(50):
   if display.read_text().strip(): break
   time.sleep(.1)
  number=display.read_text().strip(); assert number, 'Xvfb did not start'
  env=os.environ|{'HOME':str(h),'XDG_CONFIG_HOME':str(h/'config'),'XDG_DATA_HOME':str(h/'data'),'XDG_CACHE_HOME':str(h/'cache'),'DISPLAY':':'+number}
  with (p/'orca-display-serve.log').open('w') as log:
   server=subprocess.Popen(['dbus-run-session','--','orca','serve','--port','37689','--no-pairing','--project-root',str(pathlib.Path.cwd()),'--json'],env=env,stdout=log,stderr=log,start_new_session=True)
   try:server.wait(timeout=30)
   except subprocess.TimeoutExpired:print('Orca server remained running for 30 seconds'); import socket; sock=socket.socket(); sock.settimeout(2); print('Private endpoint connect result:',sock.connect_ex(('127.0.0.1',37689))); sock.close()
   print('Server result:',server.poll())
  print((p/'orca-display-serve.log').read_text()[-6000:])
 finally:
  for c in [server,x]:
   if c:
    try:os.killpg(c.pid,signal.SIGTERM)
    except ProcessLookupError:pass
  for c in [server,x]:
   if c:
    try:c.wait(timeout=4)
    except subprocess.TimeoutExpired:
     os.killpg(c.pid,signal.SIGKILL);c.wait()
  shutil.rmtree(h)
  display.unlink(missing_ok=True)
