import os,sys,json,subprocess
from pathlib import Path
p=Path(__file__).parent
expected=json.loads((p/'expected.json').read_text())
env={'PATH':'/tools/bin:/run/current-system/sw/bin:/bin:/usr/bin','HOME':'/synthetic-home','TMPDIR':'/tmp','XDG_CONFIG_HOME':'/synthetic-home/config','XDG_CACHE_HOME':'/synthetic-home/cache','XDG_STATE_HOME':'/synthetic-home/state','XDG_RUNTIME_DIR':'/tmp/runtime','PI_CODING_AGENT_DIR':'/synthetic-home/pi','TMUX_TMPDIR':'/tmp/tmux','USER':'root','LOGNAME':'root','LANG':'C.UTF-8','EVID':str(p),'WORK':os.getcwd()}
env.update(expected['markers'])
if dict((k,os.environ.get(k)) for k in expected['markers'])!=expected['markers']:raise SystemExit('inherited marker changed')
os.closerange(3,65536)
os.execve('/run/current-system/sw/bin/unshare',['unshare','--user','--map-root-user','--mount','--pid','--fork','--kill-child=KILL','--net','--ipc','/bin/bash',str(p/'enclose.sh'),*sys.argv[1:]],env)
