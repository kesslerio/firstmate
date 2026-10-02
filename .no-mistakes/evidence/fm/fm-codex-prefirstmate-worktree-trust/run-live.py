import pathlib,os,subprocess
root=pathlib.Path.cwd()
ev=pathlib.Path('/home/art/.no-mistakes/evidence/01M3Y7D8T0561B932DK0JS6M3P')
tmp=root/'.test-validation/t e'
tmp.mkdir(exist_ok=True)
env=dict(os.environ, TMPDIR=str(tmp), FM_TEST_SKIP_ORPHAN_REAP='1', VALIDATION_EVIDENCE=str(ev), VALIDATION_ROOT=str(root),VALIDATION_DRIVER_PID=str(os.getpid()), PATH=str(root/'.test-validation/bin')+':'+os.environ['PATH'])
with (ev/'live-folder-trust.log').open('w') as log:
 result=subprocess.run(['timeout','-k','5s','240s','bin/fm-test-run.sh','tests/fm-folder-trust-live-e2e.test.sh'],env=env,stdout=log,stderr=subprocess.STDOUT)
print('live guard exit:',result.returncode)
print((ev/'live-folder-trust.log').read_text())
print('fixture directories remaining:',len(list(tmp.iterdir())))
raise SystemExit(result.returncode)
