from pathlib import Path
import subprocess,os,shutil
root=Path.cwd();scratch=root/'.test-scratch';e=Path('/home/art/.no-mistakes/evidence/01M3XQ033JEYWZVQ6AHD4N27BN')
s=(root/'tests/fm-remote-secondmate-trace-context.test.sh').read_text()
s=s.replace('. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"', '. "$PWD/tests/lib.sh"')
s=s.replace('. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"', '. "$PWD/tests/remote-herdr-fixture.sh"')
s=s.replace('ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)', 'ROOT="$PWD"')
anchor=') | (cd "$REMOTE_ROOT" && tar -xf -)'
assert s.count(anchor)==1
setup='''
# Disposable deployment adaptation: preserve worker bodies and use host Bash.
export FM_TEST_REMOTE_ACCOUNT_HOME="$TMP_ROOT/remote-account"
mkdir -p "$FM_TEST_REMOTE_ACCOUNT_HOME"
python3 - "$REMOTE_ROOT" <<'FIXTURE_PY'
from pathlib import Path
import sys,shutil,re
root=Path(sys.argv[1])
p=root/'bin/fm-remote-job-worker.sh'
s=p.read_text(); assert s.startswith('#!/bin/bash\\n')
p.write_text('#!'+shutil.which('bash')+'\\n'+s.split('\\n',1)[1])
p=root/'bin/fm-remote-entrypoint.sh'
s=p.read_text()
line='ACCOUNT_HOME=$(CDPATH=\\'\\' cd ~ 2>/dev/null && pwd -P) || die "cannot resolve the remote account home"'
assert s.count(line)==1
p.write_text(s.replace(line,'ACCOUNT_HOME="$FM_TEST_REMOTE_ACCOUNT_HOME"'))
p=root/'bin/fm-remote-job-lib.sh'
p.write_text(re.sub(r'/usr/bin/ps|/bin/ps',lambda _:shutil.which('ps'),p.read_text()))
FIXTURE_PY
'''
s=s.replace(anchor,anchor+setup)
s=s.replace('FM_FAKE_REMOTE_CWD="$TMP_ROOT"', 'FM_FAKE_REMOTE_CWD="$REMOTE_ROOT"')
s=s.replace('remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate >/dev/null 2>&1', 'remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate')
s=s.replace('; fm_test_cleanup\' EXIT', '; if [ -d \"$TMP_ROOT/remote-jobs/logs\" ]; then cp \"$TMP_ROOT/remote-jobs/logs/\"* /home/art/.no-mistakes/evidence/01M3XQ033JEYWZVQ6AHD4N27BN/; fi; fm_test_cleanup\' EXIT')
script=scratch/'remote-fixture.test.sh';script.write_text(s)
env=dict(os.environ,TMPDIR=str(scratch/'data'))
with (e/'remote-trace-adapted-test.log').open('w') as f:
 p=subprocess.run(['timeout','-k','5s','180s','bash',str(script)],env=env,stdout=f,stderr=subprocess.STDOUT)
print('Remote fixture exit:',p.returncode)
raise SystemExit(p.returncode)
