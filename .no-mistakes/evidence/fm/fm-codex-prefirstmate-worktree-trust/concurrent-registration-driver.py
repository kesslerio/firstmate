import ctypes
import json
import os
from pathlib import Path
import select
import shutil
import struct
import subprocess
import tomllib

root = Path.cwd()
case = root / '.test-phase/concurrent'
project = case / 'project'
worktree = case / 'pool/slot/repo'
project.mkdir(parents=True)
worktree.parent.mkdir(parents=True)
env = os.environ.copy()
for key in ['GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:
    env.pop(key, None)
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
def git(*args):
    subprocess.run(['git','-C',str(project),*args], env=env, check=True, capture_output=True)
git('init','-q')
(project/'fixture').write_text('fixture\n')
git('add','fixture')
git('-c','user.name=Live Trust Lab','-c','user.email=live@example.invalid','-c','commit.gpgsign=false','commit','-qm','fixture')
git('worktree','add','-q','-b','concurrent',str(worktree))
(case/'pool/treehouse-state.json').write_text('{}\n')
libc = ctypes.CDLL(None, use_errno=True)
base = 'model = "base"\n# ' + ('x' * (32*1024*1024)) + '\n'
for mode in ['distinct-project','settings-change']:
    store = case / mode
    store.mkdir()
    config = store / 'config.toml'
    config.write_text(base)
    operator = store / 'operator-pending.toml'
    if mode == 'distinct-project':
        operator_text = base + '[projects."/operator/other"]\ntrust_level = "untrusted"\n'
    else:
        operator_text = base.replace('model = "base"','model = "operator"')
    operator.write_text(operator_text)
    fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
    assert fd >= 0
    watch = libc.inotify_add_watch(fd, os.fsencode(store), 0x100)
    assert watch >= 0
    process = subprocess.Popen([str(root/'bin/fm-codex-trust.sh'),str(worktree),str(project)], env={**env,'CODEX_HOME':str(store)}, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    injected = False
    for _ in range(40):
        ready, _, _ = select.select([fd],[],[],0.5)
        if not ready:
            if process.poll() is not None:
                break
            continue
        data = os.read(fd,65536)
        offset = 0
        while offset < len(data):
            wd, mask, cookie, length = struct.unpack_from('iIII',data,offset)
            name = data[offset+16:offset+16+length].split(b'\0',1)[0]
            offset += 16 + length
            if name.startswith(b'.config.toml.fm-trust.'):
                os.replace(operator,config)
                injected = True
                break
        if injected:
            break
    os.close(fd)
    output, _ = process.communicate(timeout=30)
    assert injected, 'never observed actual staging file creation'
    print(f'=== Concurrent operator {mode} ===')
    print('An independent writer atomically installed its edit while registration staged its configuration.')
    print(output.strip())
    if mode == 'distinct-project':
        assert process.returncode == 0, output
        parsed = tomllib.loads(config.read_text())
        assert parsed['model'] == 'base'
        assert parsed['projects'] == {'/operator/other':{'trust_level':'untrusted'},str(project):{'trust_level':'trusted'}}, parsed['projects']
        print('Both the operator denial for another project and Firstmate repository trust survived.')
    else:
        assert process.returncode != 0, output
        assert config.read_text() == operator_text
        print('Nonmergeable concurrent setting edit caused refusal and survived byte-for-byte.')
