# Live validation - Sol session ceiling, capped-launch path (run-launch + pane-shell detection)

Branch: `fm/sol61-ceiling-enforcement` at `f9bbd726`.
Driven on this head by `drive-sol-cap-live.sh` (same directory), which stands up a
disposable marked lab home (`bin/fm-lab-home.sh create`), a disposable git project
with a local origin, and a REAL tmux server on the private socket
`$LAB/tmux` (never the operator's default server).

Every scenario runs the real `bin/fm-spawn.sh` from a pane of that lab, so the
whole product path is live: spawn -> treehouse worktree -> endpoint window ->
admission -> staged launch handoff -> pane shell -> worker.

The worker each launch starts is a lab-local probe process (`$LAB/bin/worker`).
It exists because the lab home is fully isolated: the operator's real home,
credentials, and treehouse pool are never used, so no real agent login is
available inside the lab. The probe records the argv it was handed and the
interpreter that ran it, then stays alive like a worker (`exec sleep 600`). What
it proves is exactly the contract under test - which shell parsed the launch
line, which bytes reached the worker, and which process holds the reservation -
and every fact in the transcripts below is runtime output from the real product.

## Result: all six live scenarios pass

### 1. bash pane, capped dispatch with bash-only process substitution
Launch line: `<lab>/bin/worker --brief "$(cat <(printf %s pane-syntax-bash))"`.
Process substitution is rejected outright by POSIX `sh`, so a worker that ran at
all was parsed by the pane's own bash.
- `bash-capped.worker.log`: `argv=--brief pane-syntax-bash`, `shell=bash`,
  `pid=1432055`
- `bash-capped.registry.tsv`: `task-a  probe-sol  1793448014  1432055`
- `bash-capped.row-pid-ps.txt`: pid 1432055 is the live worker process
- `bash-capped.staged-launch.txt`: the staged line is
  `FM_HOME=... bash .../fm-sol-cap-lib.sh run-launch 'task-a' <state> '<launch line>'`
- `bash-capped.task-pane.txt`: the pane sourced that handoff
- `bash-capped.spawn.log`: `spawned task-a ... SPAWNRC=0`

### 2. fish pane, capped dispatch with fish-only command substitution
Launch line: `<lab>/bin/worker --brief (printf %s fish-pane)`. `( ... )`
command substitution is fish-only; bash/sh rejects a parenthesized argument, so a
worker that ran was parsed by fish, found from the process tree because fish has
no `$0`.
- `fish-capped.worker.log`: `argv=--brief fish-pane`, `shell=fish`, `pid=1476747`
- `fish-capped.registry.tsv`: `task-a  probe-sol  ...  1476418`, the launching
  `fish -c` process, which is the worker's parent (`fish-capped.row-pid-ps.txt`)
- `fish-capped.task-pane.txt`: fish sourced the handoff in the worktree pane
- `fish-capped.spawn.log`: `spawned task-a ... SPAWNRC=0`

### 3. ceiling refusal (adversarial, max=1 with one live worker)
- `ceiling-refused.spawn.log`: `error: Sol ceiling reached: 1 concurrent capped
  session(s) already active and this ceiling is 1 ... Active sessions: task-a
  (probe-sol, age 6s) ... SPAWNRC=1`
- `ceiling-refused.registry-before.tsv` vs `ceiling-refused.registry-after.tsv`:
  byte-identical, no claim taken
- `ceiling-refused.untouched.txt`: no `task-b.meta`, no new treehouse pool entry

### 4. non-declared model under a full ceiling
- `ceiling-other-model.spawn.log`: `spawned task-b ... SPAWNRC=0`
- `ceiling-other-model.registry.tsv`: still only the task-a row, so the non-Sol
  dispatch took no slot while the Sol guard left it alone

### 5. release and re-admit
- The capped worker's process was terminated; the next capped dispatch of
  `task-c` was admitted: `readmit.spawn.log` `SPAWNRC=0`, and
  `readmit.registry.tsv` carries the `task-c` row (the ended `task-a` row keeps
  its dead pid and claims no slot).

### 6. no `config/sol-cap`: the guard stays inert
- `inert.staged-launch.txt`: the staged line has no `run-launch` handoff at all
- `inert.row-pid-ps.txt`: no Sol registry row exists
- `inert.worker.log`: the same `--brief pane-syntax-bash` invocation under bash

## Repo focused suite, with real fish available
`PATH=/tmp/fishlab/bin:$PATH bash tests/fm-sol-cap.test.sh` -> 44 ok, 0 not-ok,
no skips; the fish-pane case now executes for real
(`ok - a capped launch runs the uncapped command unchanged in a fish pane`).
Transcript: `repo-fm-sol-cap-test-with-fish.txt`.

## Teardown
Each lab is removed in the same run (`tmux kill-server` on the lab socket, then
`rm -rf` of the lab home), so no lab home, tmux server, or worker process survives
the run. The fish interpreter used by the fish-pane scenarios was unpacked into a
throwaway `/tmp/fishlab` directory (no system install, no package manager) and is
removed after the run.
