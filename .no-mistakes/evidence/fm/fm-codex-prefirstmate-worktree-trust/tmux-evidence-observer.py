#!/usr/bin/env python3
import os,sys,subprocess,pathlib,html,json
args=sys.argv[1:]
evidence=pathlib.Path(os.environ['VALIDATION_EVIDENCE'])
root=pathlib.Path(os.environ['VALIDATION_ROOT'])
original=None
if '-S' in args:
 i=args.index('-S')+1
 original=pathlib.Path(args[i])
 rel=original.relative_to(root)
 args[i]=f"/proc/{os.environ['VALIDATION_DRIVER_PID']}/cwd/{rel}"
result=subprocess.run(['/run/current-system/sw/bin/tmux',*args],capture_output=True)
sys.stdout.buffer.write(result.stdout)
sys.stderr.buffer.write(result.stderr)
if original and 'capture-pane' in args and result.returncode==0 and result.stdout.strip():
 target=args[args.index('-pt')+1] if '-pt' in args else args[args.index('-t')+1]
 text=result.stdout.decode('utf-8','replace')
 (evidence/(target+'.txt')).write_text(text)
 (evidence/(target+'.html')).write_text('<!doctype html><meta charset="utf-8"><title>'+html.escape(target)+'</title><style>body{background:#17191c;color:#ededed}pre{font:14px/1.35 monospace;white-space:pre}</style><pre>'+html.escape(text)+'</pre>')
if original and 'kill-server' in args:
 base=original.parent/'case'
 state={}
 for path in [base/'codex-home/config.toml',base/'codex-home-above/config.toml']:
  if path.exists(): state[str(path.relative_to(base))]=path.read_text()
 state['pi_trust_store_exists']=(base/'pi-root/trust.json').exists()
 (evidence/'live-persisted-state.json').write_text(json.dumps(state,indent=2))
 (evidence/'live-cleanup.txt').write_text(f'test-owned socket: {original}\nkill-server exit: {result.returncode}\n')
sys.exit(result.returncode)
