import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


class SignalCleanup(unittest.TestCase):
    def test_detached_children_on_failure_and_signals(self):
        module = Path(__file__).with_name('owned.py').resolve()
        script = '''
import importlib.util, json, pathlib, signal, sys
spec=importlib.util.spec_from_file_location('fixture_owned',sys.argv[1])
owned=importlib.util.module_from_spec(spec);spec.loader.exec_module(owned)
owner=owned.Owner()
directory=pathlib.Path(sys.argv[2])
try:
    owned.capture([sys.executable,'-c',
        "import os,sys,time; child=os.fork(); open(sys.argv[1]+str(os.getpid()),'w').write(str(os.getpid())); time.sleep(30)",
        str(directory/'pid-')],dict(__import__('os').environ),directory,directory,'child',
        .5 if sys.argv[3]=='failure' else 20,owner)
finally:
    owner.cleanup(grace=.5)
    (directory/'receipt').write_text(json.dumps(owner.receipt()))
'''
        for mode, sig, code in [('failure', None, 1), ('TERM', signal.SIGTERM, 143),
                                ('INT', signal.SIGINT, 130), ('HUP', signal.SIGHUP, 129),
                                ('QUIT', signal.SIGQUIT, 131)]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                path = Path(directory)
                process = subprocess.Popen([sys.executable, '-c', script, str(module), directory, mode],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                           start_new_session=True)
                try:
                    deadline = time.monotonic() + 5
                    while len(list(path.glob('pid-*'))) != 2:
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(.02)
                    if sig is not None:
                        process.send_signal(sig)
                    _, error = process.communicate(timeout=8)
                    self.assertEqual(process.returncode, code, error)
                    receipt = json.loads((path / 'receipt').read_text())
                    self.assertEqual(receipt['survivors'], [])
                    self.assertTrue(receipt['signals'])
                    for record in receipt['observed']:
                        self.assertFalse(Path('/proc', str(record['pid'])).exists())
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()


if __name__ == '__main__':
    unittest.main()
