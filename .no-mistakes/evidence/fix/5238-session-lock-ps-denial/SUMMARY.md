# Live validation - fix/5238 session lock ps-denial (head a5b0e0a4)

Host: Linux (NixOS), x86_64. Worktree: no-mistakes gate worktree for the branch.
Change under test: ps-free process identity for the firstmate session lock
(`bin/fm-session-lock-lib.sh`, `bin/fm-procinfo.py`) plus the shared verdict
consumers (`bin/fm-lock.sh`, `bin/fm-inbox.sh`, `bin/fm-claude-stop-autoarm.sh`,
both turn-end guards) and docs.

## How the ps denial was made real
Every denied-ps run executed inside `unshare -r -m --propagation private`, where
`mount --bind /dev/null "$(command -v ps)"` removes the ps binary's ability to
exec. The OS then refuses the exec exactly as the intent describes:

    ps -V            -> "Permission denied", rc=126
    ps -o comm= -p 1 -> "Permission denied", rc=126

This is the same status `fm_proc_info` uses to route a read to the ps-free
provider; nothing in the product was stubbed, patched, or bypassed. Sessions were
real long-lived processes whose `comm`/`args` are harness-shaped (a `claude`-named
executable), started as parents of a real shell that ran the real product
scripts. Homes were disposable `bin/fm-lab-home.sh create` labs, removed after
each run; no operator home, fleet state, or credential was touched.

## Logs in this directory
| file | what it shows |
| --- | --- |
| `01-ps-denied-suite.log` | `tests/fm-session-lock-ps-denied.test.sh` - ALL PASS |
| `02-windows-consumers-suite.log` | `tests/fm-session-lock-windows-consumers.test.sh` - exit 0 |
| `03-inbox-suite.log` | `tests/fm-inbox.test.sh` - exit 0 |
| `04-ancestry-suite.log` | `tests/fm-session-lock-ancestry.test.sh` - 21 ok, 1 known pre-existing failure (`the pty-host was not reparented to init after the daemon ended`, an environment/reparent assumption already reported in earlier rounds) |
| `05-live-denied-ps-matrix.log` | live accept/refuse matrix under a genuine ps exec denial |
| `06-live-ps-available-baseline.log` | the same matrix with ps working, for regression |
| `07-live-guard-denied-ps.log` | the Cursor turn-end guard driven live under denied ps: live owner -> no takeover, dead owner -> reclaim |
| `08-live-stop-autoarm-denied-ps.log` | the Claude Stop auto-arm driven live under denied ps: live owner -> inert, dead owner -> reclaim |
| `09-live-claude-guard-denied-ps.log` | the Claude turn-end guard driven live under denied ps: live owner -> the "owned by another live session" systemMessage, dead owner -> the blind-supervision path |

## Live matrix result (05, 06)
Both runs produce the same verdicts; only the identity route differs.

| step | denied ps (05) | ps available (06) |
| --- | --- | --- |
| route equivalence for the same live pids | identical comm/args/ppid | identical |
| session A acquires | rc=0, `.lock`=A, `status` = held by live harness, `inbox ready` = held/live_harness=true | same |
| session B (second live harness) | rc=1, "another live firstmate session holds the lock (pid A)", `.lock` unchanged, A alive | same |
| stale record naming a live NON-harness pid | reclaimed, `.lock` rewritten | reclaimed |
| live owner whose identity is unreadable (`/proc/<pid>` hidden) | rc=1, `.lock` unchanged, inbox = unknown/live_harness=null | same |
| A exits | next session reclaims, rc=0 | same |
| dead / `0` / empty / non-numeric record | reclaimed, rc=0 | same |

Stop auto-arm (08): with A live and a supervision need staged, the auto-arm fired
from a second real harness exits 0 and leaves `.lock`=A. With A dead and its
record left in place the same auto-arm reclaims the lock (`.lock` becomes the new
session's harness pid) and then reaches its normal arming path, which refuses to
arm from a disposable validation checkout - the environment guard for labs, not a
lock verdict.

Claude turn-end guard (09): with A live the guard emits
`{"systemMessage":"FIRSTMATE SUPERVISION IS OWNED BY ANOTHER LIVE SESSION ... (lock owner pid <A>)"}`
and exits 0 with the lock untouched; with A dead it instead takes the
blind-supervision block path (rc=2). The different outcomes on the same home
show the guard's branch is driven by the shared live-owner verdict.

Cursor turn-end guard (07): with A live, the Cursor turn-end guard run from a second real harness
exits 0 and leaves `.lock`=A (no takeover). With A dead and its record left in
place, the same guard reclaims through `bin/fm-lock.sh` and `.lock` becomes the new
session's harness pid - so the recovery caller is neither wedged nor a takeover
path on the ps-free route.
