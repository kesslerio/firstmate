# Live validation - project-capacity gating of the spawn-admitted status line and the relaunch project lock

Target commit: `863ff4c9615f667702972a5c3cddc2a03ff7364f` ("fix(spawn): keep the new default-path pieces opt-in behind a capacity declaration")
Base commit: `b329c27529a686decfd52079f239aae196d86413`
Branch: `fm/project-capacity-done-frees-slot`

## What was driven

The real `bin/fm-spawn.sh` was run from the gate worktree against a disposable, marked lab
home (`bin/fm-lab-home.sh create`), a real project clone with a local bare origin, real
`treehouse get --lease` worktrees for fresh spawns, a real private tmux server
(`bin/fm-lab-home.sh tmux-dir`, `TMUX_TMPDIR=<lab socket dir> tmux -L fm-lab`), and the
machine's real `codex` CLI launched in each spawned pane. Nothing touched the operator's
`FM_HOME`, the default tmux/Herdr session, or any real fleet pane.

The shared project lock was held by a helper that computes the lock path with the product's
own `fm_treehouse_project_lock_path` and takes it with the product's own
`fm_lock_try_acquire`, so "another Treehouse slot allocation or return is in progress" is
the real lock, not a stub.

Fixture: lab home `/tmp/fm-lab.oRK9Cn`, project `/tmp/fm-lab.oRK9Cn/heavysuite`
(origin `heavysuite.origin.git`, so the declaration name is `heavysuite`), task records
with the stock `state/<id>.meta` shape, and a markdown backlog driven by the real
`tasks-axi`.

## Scenarios and observed results

| # | Scenario | Command shape | Result |
|---|----------|---------------|--------|
| 1 | Undeclared home, relaunch while another process holds the project lock | `FM_HOME=$LAB bin/fm-spawn.sh task-a --relaunch` | exit 0, `spawned task-a ...`; holder still owned the lock; no `state/task-a.status` written (`raw/s1-undeclared-heldlock.out`) |
| 2 | Declared home (`heavysuite 1`), relaunch while the project lock is held | same | exit 1, `error: another Treehouse slot allocation or return is in progress for .../heavysuite; refusing to race it`; meta byte-identical; no status/reservation (`raw/s2-declared-heldlock.out`) |
| 3 | Declared home, relaunch of a live scout with the lock free | same | exit 0; status grew by `working [at=...]: spawn admitted` (`raw/s3b-declared-live-relaunch.out`, `raw/lab-state-snapshot.txt`) |
| 4 | Undeclared home, relaunch of a live scout | same | exit 0; status bytes unchanged, no spawn-admitted line, no reservation (`raw/s4-undeclared-live-relaunch.out`) |
| 5 | Declaration caps only an unrelated project (`otherproject 2`), relaunch | same | lock still enforced: exit 1 with the same Treehouse lock error while held; with the lock free it appends `working ...: spawn admitted` (`raw/s5a-otherproject-heldlock.out`, `raw/s5b-otherproject-live-relaunch.out`) |
| 6 | Undeclared home, fresh non-Orca scout spawn while the project lock is held | `bin/fm-spawn.sh task-b $LAB/heavysuite --scout` | exit 1 with the Treehouse lock error; no `state/task-b.meta` created (`raw/s6-undeclared-fresh-heldlock.out`) |
| 7 | Undeclared home, fresh scout spawn with the lock free | same | exit 0 via a real treehouse lease and real codex pane; no status file, so no spawn-admitted line; lock dir gone afterwards (`raw/s7-undeclared-fresh-spawn.out`, `raw/lab-state-snapshot.txt`) |
| 8 | Declared-any home (`otherproject 2`), fresh scout spawn | same for `task-c` | exit 0; `state/task-c.status` is exactly `working [at=...]: spawn admitted` (`raw/s8-declared-fresh-spawn.out`) |
| 9 | Declared home at capacity, then a scout reports `done` | `heavysuite 3` fresh spawns for `task-d` | first exit 75 `deferred:` naming the three holders with no record and the backlog row still `queued`; after `done` on one scout, exit 0 and the task launched (`raw/s9b-capacity-3-full-defer.out`, `raw/s9c-done-frees-slot-admit.out`) |
| 10 | Relaunch of a finished scout reserves the released place; the reservation holds it until the replacement records `working`/`done` | `heavysuite 4`, `done` tail, relaunch then fresh spawns | relaunch exit 0 with status bytes unchanged and `state/task-a.capacity-reservation` = `gen=...`/`status_offset=37`; a fresh spawn deferred naming `task-a` among the holders; after the replacement's own `done` was appended, the same spawn was admitted (`raw/s10a-...`, `raw/s10c-...`, `raw/s10d-...`) |

Every spawned pane was inspected with `tmux -L fm-lab capture-pane`; they show the real
`codex` CLI running in each task worktree (`raw/lab-pane-captures.txt`,
`raw/lab-tmux-windows.txt`).

## Targeted automated check

`tests/fm-project-capacity.test.sh` (the suite that drives the real `bin/fm-spawn.sh`
against a logged fake tmux/treehouse fixture) passes, including
`ok - the default-path pieces stay opt-in behind a capacity declaration` and the
reservation/refusal cases: `raw/targeted-capacity-test.log`.

## Conclusion

Both directions of the requested gate were exercised on a held project lock against the
real product: an undeclared home relaunches without taking the lock and writes no
`spawn admitted` status line (main's behaviour), while a declared home takes the lock,
refuses when it is held, and records `working ...: spawn admitted`. Fresh non-Orca spawns
keep main's lock in an undeclared home, and admission still frees a place when a scout
reports `done`.
