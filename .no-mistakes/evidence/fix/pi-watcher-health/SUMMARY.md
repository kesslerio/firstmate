# Live validation: fix/pi-watcher-health (9091be84)

Product driven: the real Pi CLI (`pi --no-extensions -e .pi/extensions/fm-primary-pi-watch.ts`)
running as a primary on a private tmux socket, in a disposable marked lab home
(`bin/fm-lab-home.sh create`), arming the real `bin/fm-watch-arm.sh` -> real
`bin/fm-watch.sh` watcher from the gate worktree.

## A. Healthy established watcher (pass)
`live-run1-*`, `live-scenario-B-pane.txt`
- second `/fm-watch-arm-pi` returned `watcher: unchanged - Pi extension verified
  this home's watcher identity and fresh progress; no manual re-arm needed`.
- same watcher pid, same single arm process.

## B. Wedged watcher replaced with no tool call (pass)
`live-scenario-B-wedge-recovery.txt`
- healthy at 16:46:28; then SIGSTOP the watcher (live pid, no beacon progress)
  and backdate the beacon 1200s.
- 16:46:53 (next 30 s monitor tick, no tool call, no model turn) a replacement
  arm appeared; the old arm's ledger row is
  `exit_code=143 signal=TERM reason=arm-interrupted beacon_age=1225`.
- 16:46:54 new watcher 2803347 owned the lock with a fresh beacon; the tool then
  reported `unchanged - ... verified ... fresh progress`; zero `watcher: FAILED`
  wakes in the pane.

## C. Unproved watcher identity is preserved (pass)
`live-scenario-C-unproved-identity.txt`
- wedged watcher + lock `fm-home` rewritten to a sibling path.
- 80 s (2+ monitor ticks): 0 replacement arms, lock pid unchanged, foreign
  `fm-home` byte-identical.
- tool: `watcher: unhealthy - existing arm has no verified home-bound watcher
  with fresh progress; replacement withheld because watcher identity is not
  proved`.

## D. Poll-derived grace, not a fixed 300 s floor (pass)
`live-scenario-D-long-poll-grace.txt`
- `config/watch.env` `FM_POLL=600` (derived grace 660 s): a 400 s-470 s stale
  beacon produced 0 replacements over 70 s.
- beacon backdated to 700 s: replacement arm at the next tick, supervision
  recovered with a fresh beacon.

## E. Pending-reply decision guard through the live watcher (pass)
`live-scenario-E-pending-reply-decision.txt`
- positive control: with no open decision the running watcher's tick recorded
  `recovery_attempted_epoch` on its own.
- with `config/wait-no-turns` and `needs-decision` in the mate's status, 12
  correlated requests stayed `awaiting_report` with no attempt across 40 s.
- after `resolved`: all 12 attempted exactly once, each with its own attempt
  epoch; snapshot dirs named `fm-pending-reply-decisions.<pid>.<rand>` were
  observed during ticks and none were left behind (pid-shaped leftovers after
  teardown: 0).

## Honest residue
- If the wedged process cannot be stopped at all (modelled with SIGSTOP), the
  replacement chain exhausts and supervision stays down; the extension then
  surfaces `watcher: FAILED - Pi extension could not restore watcher continuity
  after 5 retries` instead of staying silent (`live-run2-*`). An
  `anon_pipe_read` wedge is stoppable, so this is out of the reported class.
- The Windows/Git-Bash path-spelling case could not be driven on this Linux
  host (no drive-letter spelling, no symlink in the worktree path); the
  portable spelling split is covered by
  `tests/fm-pi-watch-extension.test.sh` (shell-spelled-root case).
