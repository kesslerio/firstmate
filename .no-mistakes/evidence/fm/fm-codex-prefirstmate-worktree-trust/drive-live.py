import os, pathlib, subprocess, time, html, tempfile, shutil
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/art/.no-mistakes/evidence/01M3YYK7P4G7RPC6D0H6B5QFQS')
temp=pathlib.Path(tempfile.mkdtemp(prefix='fm spaces.',dir='/tmp'))
env=dict(os.environ,TMPDIR=str(temp))
seen={}
with (evidence/'folder-trust-live.log').open('w') as log:
    p=subprocess.Popen(['timeout','-k','5s','180s','bash','tests/fm-folder-trust-live-e2e.test.sh'],env=env,stdout=log,stderr=subprocess.STDOUT)
    while p.poll() is None:
        for socket in temp.glob('fm-folder-trust-live.*/tmux.sock'):
            r=subprocess.run(['tmux','-S',str(socket),'list-sessions','-F','#{session_name}'],capture_output=True,text=True)
            for session in r.stdout.splitlines():
                cap=subprocess.run(['tmux','-S',str(socket),'capture-pane','-p','-t',session],capture_output=True,text=True)
                if cap.returncode==0 and cap.stdout.strip(): seen[session]=cap.stdout
        time.sleep(.15)
for name,cap in seen.items():
    (evidence/(name+'.txt')).write_text(cap)
(evidence/'terminal-captures.html').write_text('<!doctype html><meta charset="utf-8"><title>Live trust terminal captures</title><style>body{background:#111;color:#eee}pre{font:14px monospace;white-space:pre;overflow:auto;border:1px solid #555;padding:16px}</style>'+''.join('<h2>'+html.escape(name)+'</h2><pre>'+html.escape(cap)+'</pre>' for name,cap in seen.items()))
shutil.rmtree(temp)
print('guard exit:',p.returncode,'captured:',', '.join(seen))
raise SystemExit(p.returncode)
