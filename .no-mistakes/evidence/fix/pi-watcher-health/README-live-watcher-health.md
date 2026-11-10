# Live validation: 30s Pi watcher health monitor (lab-driven)

Two disposable firstmate lab homes (`bin/fm-lab-home.sh create`, private tmux
socket per lab, `FM_HOME` scoped, removed in the same evidence turn) ran the
real `pi` TUI primary from the gate worktree (`pi --approve --no-mcp
--session-dir "$LAB/sessions"`). The extension auto-loaded and armed the real
`bin/fm-watch-arm.sh --restart` -> `bin/fm-watch.sh` watcher. The session lock
was stamped by the launcher with its own pid before `exec pi`, so the live Pi
process owned the lock exactly as `bin/fm-session-start.sh` would make it.

## Lab 1 - control and identity guard (`/tmp/fm-lab.hANpfN`, grace 8s, poll 2s)
- `lab1-control-healthy-no-churn.tsv`: recorded watcher pid 3360957 unchanged
  with a 1-3s beacon across 110s (3+ health ticks), one arm, one watcher.
- `lab1-adversarial-unverified-watcher.txt`: SIGSTOPped watcher plus a foreign
  `.watch.lock/fm-home` for 79s; the recorded pid, the process, and the arm
  count were unchanged and the monitor took no action.
- `lab1-tui-unhealthy-warning.txt`: `/fm-watch-arm-pi` in the live TUI reported
  `watcher: unhealthy - this session cannot take ownership of this home's
  watcher; replacement withheld ...`.
- `lab1-extension.log`: the only retirement lines are from the later owned case.

## Lab 2 - derived grace, automatic replacement, lock-ownership guard (`/tmp/fm-lab.x9UPCz`, `FM_POLL=600`, no explicit grace)
- `lab2-health-monitor-longpoll-grace.txt`
  - beacon aged to 400-442s (stale under a fixed 300s floor, healthy under the
    poll-derived 660s grace): zero retirements over two health ticks, watcher
    3639041 kept the lock, one arm.
  - beacon aged past 660s: `health monitor state=retrying` retired arm 3638718,
    started arm 3699998, watcher 3700069 took the lock with a 2s-old beacon,
    one arm left.
- `lab2-foreign-lock-guard.txt`: with `state/.lock` handed to a different live
  pid for 37s, a 700s-stale watcher was not retired; after the lock returned to
  this session the next tick replaced it (3700069 -> 3749921).
- `lab2-tui-healthy-state.txt` / `lab2-tui-primary-pane.txt`: the live TUI's
  `/fm-watch-arm-pi` reports `watcher: unchanged - Pi extension verified this
  home's watcher identity and fresh progress; no manual re-arm needed`.
- `lab2-extension.log`: the health-monitor retire/restore/confirm rows.

One observation from lab 1, outside this change's contract: a SIGSTOPped (not
TERM-responsive) watcher cannot be evicted by the product's own conservative
stale-lock policy (`bin/fm-watch.sh` never KILLs and never evicts a holder that
does not exit), so a replacement cannot take the lock until that process is
resumed or stopped; the extension recovered as soon as it was. Real wedges stay
TERM-responsive, and lab 2 covers that path end to end.
