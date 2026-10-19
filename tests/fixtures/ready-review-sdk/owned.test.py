import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

MODULE = Path(__file__).with_name('owned.py').resolve()
spec = importlib.util.spec_from_file_location('fixture_owned', MODULE)
owned = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owned)
SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT)


class SignalCleanup(unittest.TestCase):
    def test_detached_children_on_failure_and_signals(self):
        script = '''
import importlib.util, json, pathlib, signal, sys
spec=importlib.util.spec_from_file_location('fixture_owned',sys.argv[1])
owned=importlib.util.module_from_spec(spec);spec.loader.exec_module(owned)
owner=owned.Owner()
directory=pathlib.Path(sys.argv[2])
child_script="""
import os, pathlib, signal, sys, time
path=pathlib.Path(sys.argv[1])
def stopped(sig, frame):
    (path/('handled-'+str(os.getpid()))).write_text(str(sig))
    sys.exit(0)
for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP,signal.SIGQUIT): signal.signal(sig,stopped)
os.fork()
(path/('pid-'+str(os.getpid()))).write_text(str(os.getpid()))
time.sleep(30)
"""
try:
    owned.capture([sys.executable,'-c',child_script,str(directory)],dict(__import__('os').environ),
                  directory,directory,'child',.5 if sys.argv[3]=='failure' else 20,owner)
finally:
    owner.cleanup(grace=.5)
    (directory/'receipt').write_text(json.dumps(owner.receipt()))
'''
        for mode, sig, code in [('failure', None, 1), ('TERM', signal.SIGTERM, 143),
                                ('INT', signal.SIGINT, 130), ('HUP', signal.SIGHUP, 129),
                                ('QUIT', signal.SIGQUIT, 131), ('assertion', None, None),
                                ('communicate-timeout', None, None)]:
            with self.subTest(mode=mode):
                path = Path(tempfile.mkdtemp())
                guardian = owned.Owner()
                process = None
                try:
                    blocked = signal.pthread_sigmask(signal.SIG_BLOCK, SIGNALS)
                    try:
                        process = subprocess.Popen([sys.executable, '-c', script, str(MODULE), str(path), mode],
                                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                                   start_new_session=True,
                                                   preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, blocked))
                        guardian.register(process)
                    finally:
                        signal.pthread_sigmask(signal.SIG_SETMASK, blocked)
                    deadline = time.monotonic() + 5
                    while len(list(path.glob('pid-*'))) != 2:
                        self.assertLess(time.monotonic(), deadline)
                        guardian.cycle()
                        time.sleep(.02)
                    guardian.cycle()
                    if mode == 'assertion':
                        self.fail('forced assertion failure after detached launch')
                    elif mode == 'communicate-timeout':
                        process.communicate(timeout=.01)
                    else:
                        if sig is not None:
                            process.send_signal(sig)
                        _, error = process.communicate(timeout=8)
                        self.assertEqual(process.returncode, code, error)
                        receipt = json.loads((path / 'receipt').read_text())
                        self.assertEqual(receipt['survivors'], [])
                        self.assertTrue(receipt['signals'])
                        self.assertNotIn(signal.SIGKILL, [r['signal'] for r in receipt['signals']])
                except AssertionError as error:
                    if mode != 'assertion' or str(error) != 'forced assertion failure after detached launch':
                        raise
                except subprocess.TimeoutExpired:
                    if mode != 'communicate-timeout':
                        raise
                finally:
                    if process is not None and process.poll() is None:
                        process.terminate()
                        try:
                            process.communicate(timeout=5)
                        except subprocess.TimeoutExpired:
                            pass
                    faults = guardian.cleanup(grace=.5)
                    survivors = guardian.survivors()
                    if not survivors:
                        shutil.rmtree(path)
                    self.assertEqual(faults, [])
                    self.assertEqual(survivors, [], f'owned evidence retained at {path}')

    def test_child_receives_each_original_unblocked_signal(self):
        for sig in SIGNALS:
            with self.subTest(signal=sig):
                directory = tempfile.mkdtemp()
                path = Path(directory)
                class Sender(owned.Owner):
                    def register(self, process):
                        record = super().register(process)
                        deadline = time.monotonic() + 5
                        while not (path / 'ready').exists():
                            if time.monotonic() >= deadline:
                                raise TimeoutError('cooperative child did not start')
                            time.sleep(.01)
                        owned.signal_identity(record, sig, self.signals)
                        return record
                owner = Sender()
                try:
                    receipt, _ = owned.capture([sys.executable, '-c',
                        'import pathlib,signal,sys,time; p=pathlib.Path(sys.argv[1]); '
                        '[signal.signal(s,lambda n,f: (p.joinpath("handled").write_text(str(n)),sys.exit(0))) '
                        'for s in (signal.SIGTERM,signal.SIGINT,signal.SIGHUP,signal.SIGQUIT)]; '
                        'p.joinpath("ready").touch(); time.sleep(20)', directory],
                        dict(os.environ), path, path, 'cooperative', 2, owner)
                    self.assertEqual(receipt['exit_code'], 0)
                    self.assertEqual((path / 'handled').read_text(), str(sig))
                    self.assertNotIn(signal.SIGKILL, [r['signal'] for r in receipt['signals']])
                finally:
                    faults = owner.cleanup(grace=.5)
                    survivors = owner.survivors()
                    if not survivors:
                        shutil.rmtree(path)
                    self.assertEqual(faults, [])
                    self.assertEqual(survivors, [], f'owned evidence retained at {path}')


if __name__ == '__main__':
    unittest.main()
