# Live validation: ps-denied session-lock identity (fix/5238-session-lock-ps-denial @ 6060cdf0)

Host: Linux (zeppola) 7.3.1. Everything below ran in a disposable lab home minted with
`bin/fm-lab-home.sh create` and removed in the same turn; no operator fleet state touched.

## How the product was driven

`ps` denial is produced exactly as an EDR policy presents it: a `ps` on PATH that prints
"Operation not permitted" and exits 126 for every call, including `ps -V` (the shape
`bin/fm-session-lock-lib.sh` requires before it routes identity off ps). The process tree,
the `/proc` provider, and the CLI are real:

- harness = a copy of bash at `<lab>/bin/claude` (kernel comm `claude`)
- Cursor harness = copy of bash at `<lab>~/.local/share/cursor-agent/versions/test/agent`,
  launched through the legacy alias symlink `<lab>~/.local/bin/agent` (comm `agent`,
  argv0 carries the non-ASCII path)
- CLI = `bin/fm-lock.sh` from this worktree, `FM_HOME=<lab>`

Driver: `live-drive.sh` (this directory). Transcript: `live-drive-transcript.log`.

## Scenarios and results

| # | Scenario | Result |
|---|----------|--------|
| S1 | A primary acquires the lock while ps is denied | PASS — `lock acquired: harness pid N`, exit 0, `state/.lock` = N |
| S2 | A second primary cannot take a live owner's lock while ps is denied | PASS — refused with `another live firstmate session holds the lock (pid OWNER)`, exit 1, lock unchanged |
| S3 | A dead owner's lock is still reclaimable while ps is denied | PASS — reclaim succeeded, exit 0, `state/.lock` rewritten to the new pid |
| S4 | `fm-lock.sh status` agrees with the lock verdict while ps is denied | PASS — `held by live harness pid N` while alive, `stale` after the owner exits |
| S5 | A live Cursor owner behind a non-ASCII (`José`) alias path keeps its lock | PASS — ps and /proc routes report byte-identical comm/args, `José` preserved, harness verdict `alive` on both routes, contender refused, lock unchanged |

## What could not be driven here

`bin/fm-procinfo.py` is the Darwin-only identity provider (sysctl KERN_PROCARGS2 /
KERN_PROC_PID). This host is Linux, so only the `/proc` provider could be exercised live; the
suite's own `fm-procinfo.py` cases report "macOS-only, skipped" here as well. Re-running
`tests/fm-session-lock-ps-denied.test.sh` (its e2e blocked-ps case) on a macOS host exercises
the sysctl route.

## Focused suites

- `tests/fm-session-lock-ps-denied.test.sh` — ALL PASS (`suite-ps-denied.log`)
- `tests/fm-session-lock-windows-consumers.test.sh` — pass (`suite-windows-consumers.log`)
- `tests/fm-inbox.test.sh` — pass (`suite-inbox.log`)
- `tests/fm-session-lock-ancestry.test.sh` — 21 ok, 1 pre-existing failure
  `the pty-host was not reparented to init after the daemon ended` (pid-1 reparent assertion,
  already reported in earlier rounds; unrelated to this change) (`suite-ancestry.log`)
