"""Independent read-only completion verification; no SDK/FM imports or subprocesses."""
import hashlib
import json
import os
import stat
from pathlib import Path

CASES={'permitted-start-with-held-sibling','away-denied','credential-denied','account-denied',
       'capacity-denied','spend-denied','approval-denied','partial-dependency',
       'ack-without-disposition-denied','duplicate-no-relaunch','stale-generation-denied','owner-home-isolation'}

def require(value,message):
    if not value:raise AssertionError(message)

def lines(path):return [json.loads(line) for line in Path(path).read_text().splitlines() if line]

def messages(path):return [row['message'] for row in lines(path) if row.get('type')=='message']

def digest(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def owned_socket(path):
    path=Path(path);info=path.lstat()
    return stat.S_ISSOCK(info.st_mode) and info.st_uid==os.getuid() and not path.is_symlink()

def verify(spec,identity):
    output=Path(spec['output']);home=Path(spec['root'])/'homes/positive'
    seed=json.loads((output/'private-seed.json').read_text())
    admitted_path=Path('/opt/sdk-guest/git-seeds/receipt.json')
    admitted=json.loads(admitted_path.read_text())['seeds']['accounting']
    require(seed['mode']=='admitted-guest-existing-public-head' and seed['receipt_sha256']==digest(admitted_path),
            'Disposable origin used a different admitted seed receipt')
    require(all(seed[key]==admitted[key] for key in ('base_head','pack_sha256','pack_bytes','shallow_sha256')),
            'Disposable origin seed identity differs')
    require(seed['wrapper_sha256']==digest(Path(spec['source'])/'bin/fm-sessionstart-run.sh'),'Disposable origin wrapper differs')
    completed=json.loads((output/'scenario-completed.json').read_text())
    rows=completed['cases']
    require(len(rows)==len(CASES) and {row['case'] for row in rows}==CASES,'Exactly twelve distinct actual cases required')
    require(all(row['status']=='passed' for row in rows),'Failed actual scenario case')
    require(not (output/'extension-errors.jsonl').exists(),'Actual SDK extension errors occurred')
    driver=json.loads((output/'driver-completed.json').read_text())
    require(driver['accepted']>=1,'Actual main/branch SDK dispatch absent')
    dispatch=lines(output/'dispatch-events.jsonl')
    require(any(row.get('accepted') is True for row in dispatch) and any(row.get('settled') is True for row in dispatch),
            'Actual branch offer did not settle')
    require(not any('failed' in row for row in dispatch),'Actual branch dispatch failed')
    require(any(row.get('accepted') is True and row.get('message','').startswith('heartbeat') for row in dispatch),
            'Actual watcher did not route its dependency heartbeat to the branch')
    main=messages(driver['session_file'])
    result=[row for row in main if row.get('role')=='toolResult' and row.get('toolName')=='fm_branch_processed']
    require(len(result)==2 and result[0].get('isError') is True and not result[1].get('isError'),
            'Real MAIN tool did not refuse premature acknowledgment then accept after processing')
    require('unhandled ready review' in json.dumps(result[0]),'Premature acknowledgment refused outside the ready-review owner')
    main_entries=lines(driver['session_file'])
    requests=[index for index,row in enumerate(main_entries) if row.get('type')=='custom_message' and
              row.get('customType')=='fm-branch-process' and isinstance(row.get('content'),str) and
              row['content'].startswith('\u2063FIRSTMATE_OP: v1 branch-outcome: ') and
              'fm_branch_processed with through=1 exactly once' in row['content'] and '[seq 1, recorded ' in row['content']]
    first_ack=next(index for index,row in enumerate(main_entries) if row.get('type')=='message' and row.get('message')==result[0])
    require(requests and requests[0]<first_ack,'Actual typed MAIN processing request did not precede acknowledgment')
    main_calls=[part for row in main if row.get('role')=='assistant' for part in row.get('content',[]) if part.get('type')=='toolCall']
    require(any(part['name']=='fm_watch_arm_pi' for part in main_calls) and any(part['name']=='bash' for part in main_calls),
            'Actual MAIN watcher/bash tool loop absent')
    branch_path=Path((home/'state/.branch-session').read_text().strip())
    branch=messages(branch_path)
    branch_results=[row for row in branch if row.get('role')=='toolResult' and row.get('toolName')=='fm_branch_report']
    require(len(branch_results)>=2 and branch_results[0].get('isError') is True and not branch_results[1].get('isError'),
            'Real branch report did not refuse unresolved routine then durably hand off')
    require('ready work has no processing proof' in json.dumps(branch_results[0]),'Routine report did not reach ready-review owner')
    outcomes=lines(home/'state/branch-outcomes.jsonl')
    require(outcomes and outcomes[0]['seq']==1 and outcomes[0]['verdict']=='captain' and outcomes[0]['readyReview']['candidates'],
            'Actual typed MAIN handoff absent')
    require((home/'state/.branch-outcomes-processed').read_text().strip()=='1','Actual processed cursor differs')
    require(not (home/'state/.wake-queue').read_text().strip(),'Actual owned wake remains unacknowledged')
    workers=[];worker_identities=set()
    for task,scene in (('dependent','positive'),('capacity-seat','capacity'),('spend-seat','spend')):
        proof=json.loads((output/f'{task}-proof.json').read_text())
        ident=identity(proof['child']['pid'])
        require(ident and ident['start']==proof['child']['start'] and ident['state']!='Z','Actual processing child no longer alive')
        key=(ident['pid'],ident['start']);require(key not in worker_identities,'Different tasks reused one child identity');worker_identities.add(key)
        require(Path(f'/proc/{ident["pid"]}').stat().st_uid==os.getuid(),'Actual child UID differs')
        primary=json.loads((output/'primary-owner.json').read_text())
        require(Path(f'/proc/{ident["pid"]}/exe').resolve()==Path(primary['exec_path']).resolve()==Path(proof['exec_path']).resolve(),
                'Actual child executable differs from exact selected runtime')
        require(proof['sdk_package']==spec['sdkPackage'] and proof['argv_entry']==str(Path(spec['sdkPackage'])/'dist/bundle/cli.js'),
                'Actual child CLI belongs to a different SDK package')
        h=Path(spec['root'])/'homes'/scene
        raw=(h/'state'/f'{task}.meta').read_text()
        meta=dict(line.split('=',1) for line in raw.splitlines() if '=' in line)
        require(meta['spawn_gen']==proof['spawn_gen'] and meta['endpoint_task_id']==task,'Actual current incarnation changed')
        worktree=Path(meta['worktree']).resolve()
        require(Path(f'/proc/{ident["pid"]}/cwd').resolve()==worktree and
                worktree not in (h.resolve(),(h/'projects'/('project-'+scene)).resolve(),Path(spec['source']).resolve()),
                'Actual child is outside its owned isolated worktree')
        ledger=json.loads((h/'state/.ready-review.json').read_text())['candidates'][task]
        require(ledger['launch']==proof['launch'] and ledger['generation']==proof['candidate_generation'],'Actual launch provenance changed')
        require(digest(h/'data'/task/'launch-brief.md')==proof['brief_sha256'],'Exact received brief changed')
        child=messages(proof['session_file'])
        require(any(m.get('role')=='user' and spec['nonce'] in json.dumps(m) for m in child),'Actual child brief not persisted')
        require(any(m.get('role')=='toolResult' and m.get('toolName')=='read' and not m.get('isError') and spec['nonce'] in json.dumps(m) for m in child),
                'Actual child did not read its brief through SDK tool execution')
        require(any(m.get('role')=='toolResult' and m.get('toolCallId')==proof['processing_result_id'] and not m.get('isError') and
                    'WORKER_PROCESSED '+spec['nonce'] in json.dumps(m) for m in child),'Actual child processing tool result absent')
        matching=[]
        for path in output.glob('provider-*.jsonl'):
            matching += [row for row in lines(path) if row.get('event')=='worker-holding' and row.get('task')==task and row.get('home')==str(h)]
        require(len(matching)==1 and matching[0]['pid']==ident['pid'] and matching[0]['start']==ident['start'],
                'Worker was duplicated or lacks its actual provider processing barrier')
        require(not (output/f'{task}.release').exists(),'Worker was released before acknowledgment verification')
        server=identity(proof['terminal_server']['pid'])
        require(server and server['start']==proof['terminal_server']['start'] and server['state']!='Z','Owned terminal server identity not live')
        expected_socket=str(Path((h/'state/.fm-lab-tmux-dir').read_text().strip())/'sdk.sock')
        require(proof['socket_path']==expected_socket and owned_socket(expected_socket),'Actual terminal socket ownership differs')
        require(proof['actual_owner_state'].startswith('state: working · source: ') and
                ('source: pane ·' in proof['actual_owner_state'] or 'source: run-step ·' in proof['actual_owner_state']),
                'Actual fm-crew-state owner did not establish processing')
        workers.append(proof)
    require(not (home/'state/held.meta').exists(),'Explicit held sibling acquired a worker')
    return dict(schema=1,status='actual-sdk-positive-and-twelve-cases-verified',cases=rows,workers=workers,private_seed=seed,
                main_session_sha256=digest(driver['session_file']),branch_session_sha256=digest(branch_path),
                main_processed=1,queue_empty=True,
                boundary='Synthetic deterministic model; natural-language away grants remain supervisor policy, with actual owner stops and separate machine actor refusals.')
