import ctypes
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def snapshot():
    output = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,pgid=,stat=,lstart='], text=True,
                                     env=dict(os.environ, LC_ALL='C', TZ='UTC'))
    rows = {int(pid): (int(parent), int(group), state, born.strip()) for line in output.splitlines()
            for pid, parent, group, state, born in [line.split(None, 4)]}
    assert os.getpid() in rows
    return rows


def until(check, message, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.02)
    raise AssertionError(message)


def anchored(root, helper):
    output = subprocess.check_output([sys.executable, str(helper), 'anchors', str(root)], text=True)
    expected = {int(pid): born for line in output.splitlines() for pid, born in [line.split('\t', 1)]}
    rows = snapshot()
    groups = set()
    for pid, born in expected.items():
        assert pid in rows and rows[pid][3] == born and not rows[pid][2].startswith('Z')
        groups.add(rows[pid][1])
    owned = {pid for pid, row in rows.items() if row[1] in groups and not row[2].startswith('Z')}
    while True:
        children = {pid for pid, row in rows.items() if row[0] in owned}
        if children <= owned:
            break
        owned.update(children)
    return {pid: rows[pid][3] for pid in owned}


def register(root, directory):
    directory.mkdir(exist_ok=True)
    info = root.lstat()
    fields = dict(line.split('=', 1) for line in (root / '.fm-live-lab').read_text().splitlines()[1:] if '=' in line)
    data = dict(root=str(root), device=info.st_dev, inode=info.st_ino, nonce=fields['nonce'])
    (directory / (root.name + '.json')).write_text(json.dumps(data))


def recover(record):
    data = json.loads(record.read_text())
    root = Path(data['root'])
    info = root.lstat()
    assert root.resolve() == root and [info.st_dev, info.st_ino] == [data['device'], data['inode']]
    fields = dict(line.split('=', 1) for line in (root / '.fm-live-lab').read_text().splitlines()[1:] if '=' in line)
    assert fields['nonce'] == data['nonce']
    print(root)


def reap():
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if pid == 0:
            return


def original(root, command):
    record = root / os.environ['FM_LAB_LAUNCH_RECORD']
    data = json.loads(record.read_text())
    assert data['child'] == os.getpid()
    row = snapshot()[os.getpid()]
    (root / 'original-command.json').write_text(json.dumps(dict(pid=os.getpid(), start=row[3],
                                                              anchor=record.name, identity=data)))
    os.execvp(command[0], command)


def original_exited(root, helper):
    proof = json.loads((root / 'original-command.json').read_text())
    anchored(root, helper)
    current = json.loads((root / proof['anchor']).read_text())
    assert current == proof['identity'] and current['child'] == proof['pid']
    def absent():
        row = snapshot().get(proof['pid'])
        return not row or row[3] != proof['start'] or row[2].startswith('Z')
    until(absent, 'original launching command did not exit before down')


def interrupt(repo, evidence, variant, unknown=False):
    if sys.platform.startswith('linux'):
        assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0
    name = variant + ('-unknown' if unknown else '')
    ready = evidence / (name + '-ready.json')
    registry = evidence / (name + '-children')
    log = evidence / (name + '-child.log')
    env = dict(os.environ, FM_LIVE_LAB_TEST_GROUP='detached-' + variant,
               FM_LIVE_LAB_READINESS_PAUSE=str(ready), FM_TEST_CHILD_REGISTRY=str(registry))
    fault = evidence / (name + '-observer-fail')
    if unknown:
        fakebin = evidence / (name + '-bin')
        fakebin.mkdir()
        real_ps = subprocess.check_output(['bash', '-c', 'command -v ps'], text=True).strip()
        (fakebin / 'ps').write_text('#!/usr/bin/env bash\n[ ! -e "$OBSERVER_FAIL" ] || exit 1\nexec "$REAL_PS" "$@"\n')
        (fakebin / 'ps').chmod(0o755)
        env.update(PATH=str(fakebin) + ':' + env['PATH'], REAL_PS=real_ps, OBSERVER_FAIL=str(fault))
    owned = {}
    root = None
    with log.open('w') as output:
        child = subprocess.Popen(['bash', str(repo / 'tests/fm-live-lab.test.sh')], env=env,
                                 stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            until(lambda: ready.exists(), 'child never reached the readiness boundary', 15)
            boundary = json.loads(ready.read_text())
            root = Path(boundary['root'])
            assert boundary['pid'] == child.pid
            owned = anchored(root, repo / 'bin/fm-lab-launch.py')
            rows = snapshot()
            for line in registry.read_text().splitlines():
                pid, born, _ = line.split('\t')
                pid = int(pid)
                if pid in rows and rows[pid][3] == born.strip():
                    owned[pid] = born.strip()
            while True:
                children = {pid: row[3] for pid, row in rows.items() if row[0] in owned}
                if children.keys() <= owned.keys():
                    break
                owned.update(children)
            (evidence / (name + '-ownership.json')).write_text(json.dumps(owned))
            assert len(owned) >= 3
            if unknown:
                fault.touch()
            child.send_signal(signal.SIGTERM)
            assert child.wait(timeout=15) == (1 if unknown else 143)
            if unknown:
                assert root.exists() and (root / '.fm-live-lab').exists()
                assert 'launch custody recovery failed' in log.read_text()
                assert not Path(str(registry) + '.custody.json').exists()
                rows = snapshot()
                assert all(pid in rows and rows[pid][3] == born for pid, born in owned.items())
                print('UNKNOWN custody observation retains evidence and refuses cleanup before signals')
                return
            def all_absent():
                reap()
                rows = snapshot()
                return all(pid not in rows or rows[pid][3] != born for pid, born in owned.items())
            until(all_absent, 'TERM cleanup left an owned detached generation', 5)
            receipt = json.loads(Path(str(registry) + '.custody.json').read_text())
            assert receipt['cleanup_complete']
            assert all(not Path(item['directory']).exists() for item in receipt['sockets'])
            print(variant + ': readiness TERM retired every captured generation and socket')
        finally:
            if child.poll() is None:
                child.send_signal(signal.SIGTERM)
                child.wait(timeout=15)
            for pid, born in owned.items():
                row = snapshot().get(pid)
                if row and row[3] == born and not row[2].startswith('Z'):
                    os.kill(pid, signal.SIGKILL)
            def absent():
                reap()
                rows = snapshot()
                return all(pid not in rows or rows[pid][3] != born for pid, born in owned.items())
            until(absent, 'controller could not reap owned generations')
            if root and (root / 'home/.fm-lab-home').exists():
                subprocess.run(['bash', str(repo / 'bin/fm-lab-home.sh'), 'teardown', str(root / 'home')], check=True,
                               stdout=subprocess.DEVNULL)
            if registry.exists():
                sockets = [json.loads(line) for line in Path(str(registry) + '.sockets.jsonl').read_text().splitlines()]
                assert all(not Path(item['directory']).exists() for item in sockets)


def locking(repo, root):
    helper = repo / 'bin/fm-lab-launch.py'
    record_name = next(line.partition('=')[2] for line in (root / '.fm-live-lab').read_text().splitlines()
                       if line.startswith('anchor_record='))
    owner = json.loads((root / record_name).read_text())
    env = dict(os.environ, FM_LAB_LAUNCH_ROOT=str(root), FM_LAB_LAUNCH_HELPER=str(helper),
               FM_LAB_LAUNCH_RECORD=record_name, FM_LAB_LAUNCH_TOKEN=owner['retirement_token'])
    def track(process):
        row = snapshot().get(process.pid)
        if row:
            line = str(process.pid) + '\t' + row[3] + '\tkill\n'
            for suffix in ('.history', ''):
                with open(os.environ['FM_TEST_CHILD_REGISTRY'] + suffix, 'a') as stream:
                    stream.write(line)
    hook = root / 'lock-hook'
    hook.mkdir()
    (hook / 'sitecustomize.py').write_text('''import fcntl, os, pathlib
original = fcntl.flock
def observe(fd, operation):
    try:
        return original(fd, operation)
    except BlockingIOError:
        pathlib.Path(os.environ['CONTENTION_PROOF']).touch()
        raise
fcntl.flock = observe
''')
    with (root / '.fm-lab-launch.lock').open('a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        children = []
        for mode in ('launch', 'detached'):
            proof = root / (mode + '-contended')
            with (root / (mode + '-output')).open('w') as output:
                child = subprocess.Popen([sys.executable, str(helper), mode, str(root), 'touch', str(root / (mode + '-executed'))],
                                         env=dict(env, PYTHONPATH=str(hook), CONTENTION_PROOF=str(proof)),
                                         stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            children.append(child)
            track(child)
        until(lambda: all((root / (mode + '-contended')).exists() for mode in ('launch', 'detached')),
              'both launches did not encounter the held lock')
        fcntl.flock(lock, fcntl.LOCK_UN)
        until(lambda: all((root / (mode + '-executed')).exists() for mode in ('launch', 'detached')),
              'ordinary lock contention discarded an allowed launch')
        assert children[1].wait(timeout=5) == 0
    (root / 'home/bin/fm-bootstrap.sh').write_text('#!/usr/bin/env bash\nprintf executed > "$FM_HOME/startup-effect"\n')
    (root / 'home/bin/fm-bootstrap.sh').chmod(0o755)
    def startup(name, seconds=10):
        home = root / name
        home.mkdir()
        proof = root / (name + '-contended')
        with (root / (name + '-output')).open('w') as output:
            process = subprocess.Popen(['bash', str(root / 'home/bin/fm-startup-network.sh'), 'start',
                                        '--locked', '0', '--harvest-pid', '999999999'],
                                       env=dict(env, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(root / 'home'),
                                                FM_STARTUP_NETWORK_TIMEOUT='10', FM_SESSION_START_TIMEOUT=str(seconds),
                                                PYTHONPATH=str(hook), CONTENTION_PROOF=str(proof)),
                                       stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        track(process)
        return home, proof, process
    with (root / '.fm-lab-launch.lock').open('a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        starts = [startup('startup-a'), startup('startup-b')]
        until(lambda: all(proof.exists() for _, proof, _ in starts), 'startup helpers did not contend')
        fcntl.flock(lock, fcntl.LOCK_UN)
        for home, _, process in starts:
            assert process.wait(timeout=5) == 0
            until(lambda: (home / 'startup-effect').exists(), 'confirmed startup did not execute')
    for mode in ('launch', 'startup', 'seal', 'startup-cancel'):
        with (root / '.fm-lab-launch.lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            before = time.monotonic()
            if mode.startswith('startup'):
                home, _, process = startup(mode + '-timeout', 1 if mode == 'startup-cancel' else 10)
                assert process.wait(timeout=7) != 0
                assert not (home / 'startup-effect').exists()
                assert 'did not confirm command entry' in (root / (mode + '-timeout-output')).read_text()
                status = dict(line.split('=', 1) for line in (home / 'state/.startup-network.status').read_text().splitlines())
                assert status.get('worker_started') != '1'
                row = snapshot().get(int(status['pid']))
                assert not row or row[2].startswith('Z')
            else:
                command = [sys.executable, str(helper), mode, str(root)]
                if mode == 'launch': command += ['touch', str(root / 'forbidden')]
                result = subprocess.run(command, capture_output=True, text=True, timeout=7)
                assert result.returncode != 0 and 'lock acquisition timed out' in result.stderr
                assert not (root / 'forbidden').exists() and not (root / '.fm-lab-launch-closed').exists()
            assert time.monotonic() - before < 7
    subprocess.run([sys.executable, str(helper), 'seal', str(root)], check=True, stdout=subprocess.DEVNULL)
    home, _, process = startup('startup-sealed')
    assert process.wait(timeout=5) != 0 and not (home / 'startup-effect').exists()
    print('ordinary, detached and concurrent startup commands execute after release; bounded and sealed launches deny effects and startup success')


if __name__ == '__main__':
    mode = sys.argv[1]
    if mode == 'original':
        original(Path(sys.argv[2]), sys.argv[3:])
    elif mode == 'original-exited':
        original_exited(Path(sys.argv[2]), Path(sys.argv[3]))
    elif mode == 'pause':
        Path(sys.argv[2]).write_text(json.dumps(dict(pid=os.getppid(), root=sys.argv[3])))
    elif mode == 'register':
        register(Path(sys.argv[2]), Path(sys.argv[3]))
    elif mode == 'recover':
        recover(Path(sys.argv[2]))
    elif mode == 'interrupt':
        failures = []
        for variant in ('startup', 'successor'):
            try:
                interrupt(Path(sys.argv[2]), Path(sys.argv[3]), variant)
            except (AssertionError, subprocess.SubprocessError) as error:
                failures.append(variant + ': ' + str(error))
        try:
            interrupt(Path(sys.argv[2]), Path(sys.argv[3]), 'startup', unknown=True)
        except (AssertionError, subprocess.SubprocessError) as error:
            failures.append('UNKNOWN: ' + str(error))
        assert not failures, failures
    elif mode == 'locking':
        locking(Path(sys.argv[2]), Path(sys.argv[3]))
