import os,subprocess,pathlib
root=pathlib.Path.cwd()
ev=pathlib.Path('/home/art/.no-mistakes/evidence/01M3Y7D8T0561B932DK0JS6M3P')
env=dict(os.environ, VALIDATION_DRIVER_PID=str(os.getpid()),VALIDATION_EVIDENCE=str(ev),VALIDATION_CODEX_AUTH=str(pathlib.Path(os.environ.get('CODEX_HOME') or str(pathlib.Path.home()/'.codex'))/'auth.json'),VALIDATION_PI_AUTH=os.environ.get('PI_CODING_AGENT_DIR') or str(pathlib.Path.home()/'.pi/agent'),TMPDIR=str(root/'.test-validation/tmp'),FM_TEST_SKIP_ORPHAN_REAP='1')
with (ev/'raw-runtime.log').open('w') as log:
 result=subprocess.run(['timeout','-k','5s','160s','bash','.test-validation/raw-runtime.sh'],env=env,stdout=log,stderr=subprocess.STDOUT)
print((ev/'raw-runtime.log').read_text())
print('raw replay exit:',result.returncode)
raise SystemExit(result.returncode)
