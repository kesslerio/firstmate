import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root = Path.cwd()
scratch = root / '.live-watch'
evidence = Path('/Users/kesslerio/.no-mistakes/evidence/01M3QTPEXZQCR13W9QA1PV6M34')
socket_dir = (scratch / 'home/state/.fm-lab-tmux-dir').read_text().strip()
env = os.environ.copy()
for key in ['FM_GATE_REFUSE_BYPASS', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE',
            'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE',
            'FM_CREW_STATE_BIN', 'FM_CLASSIFY_HOLD_RE']:
    env.pop(key, None)
env['TMUX_TMPDIR'] = socket_dir

def tmux(*args):
    return subprocess.check_output(['tmux', '-L', 'fm-lab', *args], env=env, text=True)

tmux('set-window-option', '-t', 'primary:fm-lane', 'automatic-rename', 'off')
tmux('set-window-option', '-t', 'primary:fm-lane', 'allow-rename', 'off')
env['TMUX'] = tmux('display-message', '-p', '-t', 'primary:fm-lane',
                   '#{socket_path},#{pid},#{pane_id}').strip()
pane = tmux('capture-pane', '-p', '-t', 'primary:fm-lane', '-S', '-40')
(evidence / 'live-claude-pane.txt').write_text(pane)
window = 'primary:fm-lane'
key = 'primary_fm-lane'
cases = [
    ('holding', 'working [at=1]: Holding the build per 002: tell me which PR', 'absorb', 'declared hold'),
    ('on-hold', 'working: on hold for review', 'absorb', 'declared hold'),
    ('waiting-on', 'working: waiting on the third PR', 'absorb', 'declared hold'),
    ('waiting-for', 'working: waiting for the build', 'absorb', 'declared hold'),
    ('awaiting', 'working: awaiting a decision', 'absorb', 'declared hold'),
    ('standing-by', 'working: standing by for release', 'absorb', 'declared hold'),
    ('blocked', 'blocked [key=signing]: signing host refuses upload', 'absorb', 'declared blocker'),
    ('decision', 'needs-decision [key=release]: option A or B', 'absorb', 'declared decision'),
    ('hold-aged', 'working: Holding the build for the third PR', 'recheck', 'declared hold'),
    ('blocked-aged', 'blocked [key=signing]: signing host refuses upload', 'recheck', 'declared blocker'),
    ('decision-aged', 'needs-decision [key=release]: option A or B', 'recheck', 'declared decision'),
    ('active', 'working: still compiling the release build', 'wedge', ''),
    ('not-a-phrase', 'working: still parked at that gate', 'wedge', ''),
    ('metadata-after-colon', 'working: [key=holding] compiling the release build', 'wedge', ''),
    ('metadata-before-colon', 'working [at=holding]: compiling the release build', 'wedge', ''),
    ('identifier-underscore', 'working: editing holding_lease', 'wedge', ''),
    ('identifier-digit', 'working: editing holding2 lease', 'wedge', ''),
    ('superseded-hold', 'working: Holding the build for the third PR\nworking: third PR landed, building now', 'wedge', ''),
    ('superseded-blocker', 'blocked [key=release]: unavailable\nworking: compiling again', 'wedge', ''),
    ('resolved-decision', 'needs-decision [key=release]: choose A or B\nresolved [key=release]: selected A', 'wedge', ''),
]
watch_binary = root / 'bin/fm-watch.sh'
report_file = evidence / 'live-watcher-results.json'
if '--baseline' in sys.argv:
    watch_binary = scratch / 'baseline-bin/fm-watch.sh'
    report_file = evidence / 'live-watcher-baseline.json'
    cases = [('holding-before-fix', 'working [at=1]: Holding the build per 002: tell me which PR', 'wedge', '')]
if '--fixed-vocabulary' in sys.argv:
    report_file = evidence / 'live-fixed-vocabulary.json'
    cases = [('override-cannot-add', 'working: compiling the release', 'wedge', ''),
             ('override-cannot-remove', 'working: Holding the release', 'absorb', 'declared hold')]
records = []
live_processes = []

def run_round(case_env, state, name, expected, phrase, number=1):
    # Persisted state represents a watcher restarted at an already elapsed
    # wedge threshold. Capture comes from the real Claude terminal endpoint.
    current = tmux('capture-pane', '-p', '-t', window, '-S', '-40').rstrip('\n')
    digest = hashlib.md5(current.encode()).hexdigest()
    for prefix in ['.hash-', '.stale-']:
        (state / (prefix + key)).write_text(digest)
    (state / ('.count-' + key)).write_text('1\n')
    (state / ('.stale-since-' + key)).write_text(str(int(time.time()) - 600) + '\n')
    for marker in ['.watcher-down', '.watch-handling', '.watch-recovery']:
        p = state / marker
        if p.is_file():
            p.unlink()
    case_env['FM_WATCH_HANDLING_SUCCESSOR'] = '1'
    log = evidence / f'live-{name}-{number}.log'
    started = time.monotonic()
    with log.open('w') as output:
        proc = subprocess.Popen([str(watch_binary)], cwd=root,
                                env=case_env, stdout=output, stderr=output,
                                start_new_session=True)
        live_processes.append(proc)
        if expected == 'absorb':
            # Require multiple real stale scans, rather than only a live PID.
            limit = time.monotonic() + 30
            observed = False
            while time.monotonic() < limit and proc.poll() is None:
                count = state / ('.count-' + key)
                if count.exists() and int(count.read_text()) >= 5:
                    observed = True
                    break
                time.sleep(.15)
            success = observed and proc.poll() is None
            if proc.poll() is None:
                proc.send_signal(signal.SIGTERM)
            proc.wait(timeout=25)
        else:
            try:
                proc.wait(timeout=30)
                success = proc.returncode == 0
            except subprocess.TimeoutExpired:
                success = False
                proc.send_signal(signal.SIGTERM)
                proc.wait(timeout=25)
    text = log.read_text()
    queue = (state / '.wake-queue').read_text() if (state / '.wake-queue').exists() else ''
    counter = (state / ('.wedge-escalations-' + key)).read_text().strip() if (state / ('.wedge-escalations-' + key)).exists() else '0'
    triage = (state / '.watch-triage.log').read_text() if (state / '.watch-triage.log').exists() else ''
    if expected == 'absorb':
        success = success and not queue and counter == '0' and phrase in triage
    elif expected == 'recheck':
        success = success and phrase in text and 'rechecked on a long cadence not a wedge' in text and 'possible wedge' not in text and counter == '0'
    else:
        success = success and f'possible wedge, escalation {number}' in text and counter == str(number)
        if number == 3:
            success = success and 'demand-deep-inspection' in text
    result = {'case': name, 'round': number, 'status': (state / 'lane.status').read_text().strip(),
              'expected': expected, 'result': 'pass' if success else 'fail',
              'elapsed_seconds': round(time.monotonic() - started, 2), 'exit': proc.returncode,
              'watcher_output': text.strip(), 'wake_queue': queue.strip(),
              'escalation_count': counter, 'triage': triage.strip(), 'evidence': str(log)}
    records.append(result)
    report_file.write_text(json.dumps(records, indent=2))
    print(json.dumps({k: result[k] for k in ['case', 'round', 'expected', 'result', 'elapsed_seconds', 'watcher_output']}), flush=True)
    return success

try:
    for name, status, expected, phrase in cases:
        home = scratch / name
        subprocess.run([str(root / 'bin/fm-lab-home.sh'), 'create', str(home)], check=True, capture_output=True, env=env)
        state = home / 'state'
        case_env = env | {'FM_HOME': str(home), 'FM_POLL': '1', 'FM_SIGNAL_GRACE': '1',
                          'FM_CHECK_INTERVAL': '999999', 'FM_HEARTBEAT': '999999',
                          'FM_PAUSE_RESURFACE_SECS': '240', 'FM_STALE_ESCALATE_SECS': '1',
                          'FM_SECONDMATE_LIVENESS_SECS': '99999999', 'FM_HOME_SUMMARY_INTERVAL': '999999'}
        if name.startswith('override-cannot-'):
            case_env['FM_CLASSIFY_HOLD_RE'] = 'compiling' if name.endswith('add') else 'never-matches-this-note'
        (state / 'lane.meta').write_text(f'window={window}\nkind=ship\nharness=claude\nbackend=tmux\n')
        (state / 'lane.status').write_text(status + '\n')
        if expected == 'recheck':
            os.utime(state / 'lane.status', (time.time() - 2000, time.time() - 2000))
        subprocess.run(['bash', '-c', '. bin/fm-wake-lib.sh; fm_wake_status_mark_current "$FM_HOME/state" "$FM_HOME/state/lane.status"'], env=case_env, cwd=root, check=True, capture_output=True)
        success = run_round(case_env, state, name, expected, phrase)
        if not success:
            print('FAILED CASE: ' + name, flush=True)
            break
        if name == 'active':
            for number in [2, 3]:
                for path in state.glob('.wake-queue*'):
                    if path.is_file():
                        path.unlink()
                if not run_round(case_env, state, name, expected, phrase, number):
                    raise RuntimeError('active escalation ladder failed')
finally:
    for proc in live_processes:
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            proc.wait(timeout=25)
    tmux('kill-server')
    subprocess.run([str(root / 'bin/fm-lab-home.sh'), 'teardown', str(scratch / 'home')], env=env, check=True)

if len(records) != len(cases) + (2 if any(c[0] == 'active' for c in cases) else 0) or any(r['result'] != 'pass' for r in records):
    raise SystemExit(1)
