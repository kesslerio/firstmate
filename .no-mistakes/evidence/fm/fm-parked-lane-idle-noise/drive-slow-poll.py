import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

root = Path.cwd()
home = root / '.live-watch/slow-poll-home'
evidence = Path('/Users/kesslerio/.no-mistakes/evidence/01M3QTPEXZQCR13W9QA1PV6M34')
env = os.environ.copy()
for key in ['FM_GATE_REFUSE_BYPASS', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'TMUX', 'TMUX_TMPDIR']:
    env.pop(key, None)
subprocess.run(['bin/fm-lab-home.sh', 'create', str(home)], check=True, capture_output=True)
env.update(FM_HOME=str(home), FM_POLL='12', FM_HEARTBEAT='999999', FM_CHECK_INTERVAL='999999', FM_HOME_SUMMARY_INTERVAL='999999')

def is_alive(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], text=True, capture_output=True)
    return result.returncode == 0 and not result.stdout.strip().startswith('Z')

with (evidence / 'live-slow-poll.log').open('w') as log:
    arm = subprocess.Popen(['bin/fm-watch-arm.sh'], env=env, cwd=root, stdout=log, stderr=log, start_new_session=True)
    try:
        deadline = time.monotonic() + 40
        watcher = None
        sleeping = False
        while time.monotonic() < deadline and arm.poll() is None:
            pidfile = home / 'state/.watch.lock/pid'
            if pidfile.exists():
                watcher = int(pidfile.read_text())
                children = subprocess.run(['pgrep', '-P', str(watcher)], text=True, capture_output=True).stdout.split()
                for child in children:
                    command = subprocess.run(['ps', '-p', child, '-o', 'command='], text=True, capture_output=True).stdout.strip()
                    if command == 'sleep 12':
                        sleeping = True
                        break
            if sleeping:
                break
            time.sleep(.1)
        assert sleeping, 'could not observe real watcher in its twelve-second poll sleep'
        shutil.rmtree(home / 'state')
        removed = time.monotonic()
        time.sleep(10)
        alive_at_10 = is_alive(watcher)
        while is_alive(watcher) and time.monotonic() - removed < 40:
            time.sleep(.1)
        elapsed = time.monotonic() - removed
        gone = not is_alive(watcher)
        arm.wait(timeout=15)
    finally:
        if arm.poll() is None:
            arm.send_signal(signal.SIGTERM)
            arm.wait(timeout=20)
text = (evidence / 'live-slow-poll.log').read_text()
result = {'poll_seconds': 12, 'alive_at_old_ten_second_budget': alive_at_10,
          'gone_within_current_forty_second_budget': gone, 'exit_after_seconds': round(elapsed, 2),
          'arm_exit': arm.returncode, 'product_output': text,
          'result': 'pass' if alive_at_10 and gone and 'watcher: exiting - state directory' in text else 'fail'}
(evidence / 'live-slow-poll.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result), flush=True)
assert result['result'] == 'pass'
