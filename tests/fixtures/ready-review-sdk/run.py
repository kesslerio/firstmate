"""Bounded Linux integration owner. Only the explicit test invocation starts runtime."""
import argparse
import importlib.util
import json
import os
import resource
import re
from pathlib import Path
import shlex
import shutil
import stat
import sys
import tempfile
import time

def bound_module(name):
    path=Path(__file__).with_name(name+'.py')
    definition=importlib.util.spec_from_file_location('ready_review_'+name,path)
    module=importlib.util.module_from_spec(definition);definition.loader.exec_module(module)
    return module

owned=bound_module('owned');completion=bound_module('completion')

def require(value,message):
    if not value:raise AssertionError(message)

def all_gone(records,observe):
    for record in records:
        current=observe(record['pid'])
        if current and current['start']==record['start']:return False
    return True

def attempt(faults,label,operation):
    try:return operation()
    except BaseException as error:faults.append(dict(operation=label,error=repr(error)))

def socket_path(spec,scene):
    record=Path(spec['root'])/'homes'/scene/'state/.fm-lab-tmux-dir'
    if not record.exists() and not record.is_symlink():return None
    info=record.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid==os.getuid() and not record.is_symlink(),'Unsafe private socket owner record')
    directory=record.read_text().strip()
    require(re.fullmatch(r'/tmp/fml\.[A-Za-z0-9]{6}',directory),'Foreign private socket directory')
    path=Path(directory);info=path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid==os.getuid() and stat.S_IMODE(info.st_mode)==0o700,'Private socket directory ownership differs')
    return path/'sdk.sock'

def cleanup_fixture(spec,owner,result,env,real_tmux):
    faults=[];output=Path(spec['output']);root=Path(spec['root']);terminal=[];sockets={}
    cleanup_deadline=time.monotonic()+45
    for task in spec['workerTasks']:
        attempt(faults,'release '+task,lambda task=task:(output/(task+'.release')).touch())
    def wait_workers():
        until=time.monotonic()+8
        while result and time.monotonic()<until:
            owner.cycle()
            if all_gone([row['child'] for row in result['workers']],owned.identity):return
            time.sleep(.02)
    attempt(faults,'wait released workers',wait_workers)
    for scene in spec['scenes']:
        socket=attempt(faults,'read socket owner '+scene,lambda scene=scene:socket_path(spec,scene))
        if socket is None:continue
        sockets[scene]=socket
        def stop_socket(socket=socket,scene=scene):
            if not socket.exists() and not socket.is_symlink():return
            receipt,_text=owned.capture([real_tmux,'-S',str(socket),'kill-server'],env,root,output,'terminal-cleanup-'+scene,5,owner)
            require(receipt['exit_code']==0,'Exact owned tmux server shutdown refused')
            terminal.append(dict(socket=str(socket),shutdown=receipt))
        attempt(faults,'stop terminal '+scene,stop_socket)
    cleanup_errors=attempt(faults,'owned process cleanup',owner.cleanup)
    faults.extend(dict(operation='owned process cleanup',error=error) for error in (cleanup_errors or []))
    receipt=attempt(faults,'owned final readback',owner.receipt)
    if receipt is None:receipt={'survivors':['owner readback unavailable']}
    if receipt['survivors']:faults.append(dict(operation='owned final readback',error='Owned descendants survived'))
    for scene,socket in sockets.items():
        def remove_socket(socket=socket):
            require(not receipt['survivors'],'Cannot retire sockets before owned processes terminate')
            if socket.exists() or socket.is_symlink():
                info=socket.lstat()
                require(stat.S_ISSOCK(info.st_mode) and info.st_uid==os.getuid() and not socket.is_symlink(),'Unexpected private terminal artifact')
                current=socket.lstat();require((current.st_dev,current.st_ino)==(info.st_dev,info.st_ino),'Private socket identity changed')
                socket.unlink()
            require(not socket.exists() and not socket.is_symlink(),'Owned terminal socket survived cleanup')
        attempt(faults,'retire socket '+scene,remove_socket)
        def retire_directory(scene=scene,socket=socket):
            require(not receipt['survivors'],'Cannot retire lab directory before owned processes terminate')
            remaining_seconds=cleanup_deadline-time.monotonic()
            require(remaining_seconds>0,'Bounded lab-directory cleanup deadline exhausted')
            cleanup_env=dict(env,FM_HOME=str(root/'homes'/scene))
            capture,_text=owned.capture(['bash',str(Path(spec['source'])/'bin/fm-lab-home.sh'),'teardown',str(root/'homes'/scene)],
                cleanup_env,root,output,'lab-directory-cleanup-'+scene,min(5,remaining_seconds),owner)
            require(capture['exit_code']==0,'Lab socket directory owner refused cleanup')
            require(not socket.parent.exists() and not (root/'homes'/scene/'state/.fm-lab-tmux-dir').exists(),'Lab socket owner artifacts remain')
        attempt(faults,'retire directory '+scene,retire_directory)
    if result:
        for worker in result['workers']:
            attempt(faults,'terminal server identity stopped',lambda worker=worker:
                    require(all_gone([worker['terminal_server']],owned.identity),'Owned terminal server identity survived'))
    remaining=[]
    for scene,socket in sockets.items():
        attempt(faults,'final socket readback '+scene,lambda socket=socket:
                remaining.append(str(socket)) if socket.exists() or socket.is_symlink() else None)
    receipt.update(cleanup_faults=faults,terminals=terminal,sockets_remaining=remaining)
    final_errors=attempt(faults,'final owned process cleanup',lambda:owner.cleanup(grace=2))
    faults.extend(dict(operation='final owned process cleanup',error=error) for error in (final_errors or []))
    final=attempt(faults,'final process readback after directory cleanup',owner.receipt)
    if final is not None:
        receipt.update(final)
        if final['survivors']:faults.append(dict(operation='final process readback after directory cleanup',error='Owned process remains'))
    attempt(faults,'write cleanup receipt',lambda:(output/'owned-cleanup.json').write_text(json.dumps(receipt,indent=2)+'\n'))
    return receipt,faults

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--source',type=Path,required=True);parser.add_argument('--sdk-package',type=Path,required=True)
    args=parser.parse_args();source=args.source.resolve(strict=True);package=args.sdk_package.resolve(strict=True)
    require(os.getuid()==1000,'Admitted SDK fixture requires UID1000')
    assets=Path(__file__).resolve().parent
    root=Path(tempfile.mkdtemp(prefix='fm-ready-review-sdk.',dir=os.environ.get('TMPDIR','/tmp'))).resolve()
    root.chmod(0o700)
    output=root/'evidence';output.mkdir(mode=0o700)
    for name in ('user-home','tmp','xdg','agent','bin','worker-sessions'):(root/name).mkdir(mode=0o700)
    real={name:shutil.which(name) for name in ('node','python3','tmux','bash','treehouse')}
    require(all(real.values()),'Actual integration tools are missing')
    scenes=['positive','away','quiet','credential','account','capacity','spend','approval','partial','ack','stale','foreign-a','foreign-b']
    scene_tasks={name:['dependent'] for name in scenes}
    scene_tasks.update(positive=['dependent'],capacity=['capacity-seat','capacity-wait'],spend=['spend-seat','spend-wait'])
    spec=dict(schema=1,kind='private-ready-review-sdk-fixture',root=str(root),output=str(output),source=str(source),assets=str(assets),sdkPackage=str(package),
              python=real['python3'],provider='acceptance-ready-review',nonce='ready-sdk-'+os.urandom(16).hex(),scenes=scenes,
              sceneTasks=scene_tasks,workerTasks=['dependent','capacity-seat','spend-seat'])
    spec_path=root/'spec.json';spec_path.write_text(json.dumps(spec,indent=2)+'\n')
    quote=shlex.quote
    # Transport wrappers delegate every response to the actual selected binary.
    tmux_config=root/'tmux.conf';tmux_config.write_text('set-option -g default-shell '+quote(real['bash'])+'\n'+
        'set-option -g default-command '+quote(real['bash']+' --noprofile --norc')+'\nset-option -g remain-on-exit off\n')
    (root/'bin/tmux').write_text('#!/bin/sh\nset -eu\nsocket_dir=$(cat "$FM_HOME/state/.fm-lab-tmux-dir")\n'+
        'exec '+quote(real['tmux'])+' -S "$socket_dir/sdk.sock" -f '+quote(str(tmux_config))+' "$@"\n')
    cli=package.parent/'bin/pi'
    # A global install's package need not have the staged sibling bin wrapper.
    command=[str(cli)] if cli.is_file() else [real['node'],str(package/'dist/bundle/cli.js')]
    delegate=' '.join(map(quote,command))
    (root/'bin/pi').write_text('#!/bin/sh\ncase "${1:-}" in --help|--version|auth|--list-models) exec '+delegate+' "$@" ;; esac\n'+
        'exec '+delegate+' --print --mode json --approve --no-extensions --no-skills --no-prompt-templates --no-context-files '+
        '--session-dir '+quote(str(root/'worker-sessions'))+' -e '+quote(str(assets/'provider.mjs'))+' "$@"\n')
    for name in ('tmux','pi'):(root/'bin'/name).chmod(0o700)
    env=dict(PATH=str(root/'bin')+':'+os.environ['PATH'],HOME=str(root/'user-home'),USER='fixture',LOGNAME='fixture',
             TMPDIR=str(root/'tmp'),XDG_CONFIG_HOME=str(root/'xdg'),PI_CODING_AGENT_DIR=str(root/'agent'),
             FM_HOME=str(root/'homes/positive'),FM_RR_SPEC=str(spec_path),FM_PI_PACKAGE_DIR=str(package),
             FM_POLL='1',FM_HEARTBEAT='600',FM_HEARTBEAT_MAX='7200',FM_PI_HARNESS='pi',PI_CODING_AGENT='true',
             NO_MISTAKES_GATE='private-ready-review-sdk-fixture',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',
             GIT_CONFIG_COUNT='2',GIT_CONFIG_KEY_0='protocol.file.allow',GIT_CONFIG_VALUE_0='always',
             GIT_CONFIG_KEY_1='maintenance.auto',GIT_CONFIG_VALUE_1='false',SHELL=real['bash'],TERM='xterm-256color',LC_ALL='C.UTF-8')
    (output/'environment-keys.json').write_text(json.dumps(sorted(env))+'\n')
    soft,hard=resource.getrlimit(resource.RLIMIT_FSIZE)
    file_limit=min(64*1024*1024,hard) if hard!=resource.RLIM_INFINITY else 64*1024*1024
    resource.setrlimit(resource.RLIMIT_FSIZE,(file_limit,file_limit))
    owner=owned.Owner();owner.evidence=output;result=None;failure=None;interrupted_status=None;started=time.monotonic();deadline=started+820
    def execute(argv,label,ceiling):
        seconds=min(ceiling,deadline-time.monotonic())
        require(seconds>0,'Fixture aggregate runtime budget exhausted')
        receipt,_text=owned.capture(argv,env,source,output,label,seconds,owner)
        require(receipt['exit_code']==0,'Actual '+label+' failed; see '+str(receipt['logs']))
    try:
        execute([real['python3'],'-B',str(assets/'scenario.py'),'setup'],'setup',150)
        execute([real['node'],str(assets/'driver.mjs')],'sdk-driver',650)
        result=completion.verify(spec,owned.identity)
        (output/'verified-before-cleanup.json').write_text(json.dumps(result,indent=2)+'\n')
    except BaseException as error:
        if isinstance(error, SystemExit):interrupted_status=error.code
        failure=repr(error)
        (output/'failure.txt').write_text(failure+'\n')
    finally:
        receipt,faults=cleanup_fixture(spec,owner,result,env,real['tmux'])
        if faults:failure=(failure or '')+' Cleanup faults: '+repr(faults)
    if failure:
        print('not ok - exact SDK dependency acceptance: '+failure,file=sys.stderr)
        print('private evidence: '+str(output),file=sys.stderr)
        return interrupted_status or 1
    require(result is not None,'No actual completion proof')
    result.update(evidence=str(output),owned_survivors=receipt['survivors'],elapsed_seconds=time.monotonic()-started)
    (output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    for row in result['cases']:print('ok - exact SDK '+row['case'])
    print('FM_READY_REVIEW_SDK_RESULT '+json.dumps(result,sort_keys=True))
    return 0

if __name__=='__main__':sys.exit(main())
