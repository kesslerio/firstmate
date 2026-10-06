import base64,json,os,pathlib,shutil,ssl,subprocess,tempfile,threading
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
root=pathlib.Path.cwd(); evidence=pathlib.Path('/home/art/.no-mistakes/evidence/01M46Z789HH26VTFDG91BQ3BY8')
work=pathlib.Path(tempfile.mkdtemp(prefix='.media-https-',dir=root)); servers=[]; requests=[]
png=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2J3gAAAAASUVORK5CYII=')
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*a): pass
 def do_GET(self):
  requests.append({'path':self.path,'host':self.headers.get('Host'),'authorization_present':bool(self.headers.get('Authorization'))})
  mode=self.path.rsplit('/',1)[-1]
  if self.path.startswith('/start/'):
   self.send_response(302); self.send_header('Location',f'https://127.0.0.1:{servers[1].server_port}/next/{mode}')
  elif self.path.startswith('/next/'):
   self.send_response(302); self.send_header('Location',('/next/loop' if mode=='loop' else f'http://127.0.0.1:{servers[1].server_port}/final/downgrade' if mode=='downgrade' else f'/final/{mode}'))
  else:
   body=b'\x00\x00\x00\x18ftypmp42'+b'video bytes' if mode=='video' else png
   self.send_response(404 if mode=='missing' else 200); self.send_header('Content-Length',str(len(body)+100 if mode=='interrupted' else len(body))); self.end_headers()
   self.wfile.write(body[:8] if mode=='interrupted' else body); self.close_connection=True; return
  self.end_headers(); self.close_connection=True
try:
 subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-keyout',str(work/'key.pem'),'-out',str(work/'cert.pem'),'-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost,IP:127.0.0.1'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(work/'cert.pem',work/'key.pem')
 for i in range(2):
  s=ThreadingHTTPServer(('127.0.0.1',0),Handler); s.socket=ctx.wrap_socket(s.socket,server_side=True); servers.append(s); threading.Thread(target=s.serve_forever,daemon=True).start()
 env=os.environ.copy(); env['CURL_CA_BUNDLE']=str(work/'cert.pem'); env['NO_PROXY']='localhost,127.0.0.1'
 with (evidence/'live-https.txt').open('w') as log:
  for mode,expected in [('success',0),('missing',1),('interrupted',1),('loop',1),('downgrade',1),('video',1)]:
   f=work/'body.md'; f.write_text(f'![proof](https://localhost:{servers[0].server_port}/start/{mode})')
   cmd=['bash','bin/fm-pr-media.sh','141','--repo','kunchenguid/firstmate','--body-file',str(f),'--require-embeds']
   r=subprocess.run(cmd,env=env,text=True,capture_output=True,timeout=90)
   log.write(f'CASE {mode}: expected={expected} observed={r.returncode}\n'+r.stdout+r.stderr+'\n'); log.flush(); print(mode,r.returncode,flush=True)
  log.write('Requests: '+json.dumps(requests,indent=2)+'\n')
  log.write('Authorization absent at all external hops: '+str(all(not r['authorization_present'] for r in requests))+'\n')
finally:
 for s in servers: s.shutdown(); s.server_close()
 shutil.rmtree(work)
