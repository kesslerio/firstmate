# Live validation — session lock vs. a denied `ps` (issue 5238)

Change under test: `fix/5238-session-lock-ps-denial`
Head `bb17a785892dbe8e5ee8e5c95c293b0764d24364`, base `095db3bc7e57b4d50b7e2ac66f9671ba66be692b`.

The invariant the change must keep: a **live or unreadable lock owner blocks reclaim on
every supported platform**, while **proven-dead, reused non-harness, malformed and
zero-valued owners stay reclaimable** — and a host whose `ps` binary refuses to execute
no longer wedges the home read-only.

## Environment

* Host: Linux (x86_64). `python3`, `git`, `jq` present; the real `bin/fm-lock.sh`,
  `bin/fm-inbox.sh` and the hook scripts were executed from the change's worktree.
* Disposable lab: `mktemp -d` home (never the operator home), deleted at the end of the
  run. Every scenario used a private `FM_HOME`, `PATH`, `TMPDIR`.
* Fixtures, and only where this host cannot supply the real surface:
  * a **verified-harness process**: a `bash` symlink named `claude`, so the kernel's exec
    name — the fact `ps -o comm=` and `/proc/<pid>/stat` report — is `claude`;
  * a **denied `ps`**: a `ps` on `PATH` that exits 126 with "Operation not permitted",
    the refused-exec status (EDR-style policy);
  * the repo's documented **Cygwin process-table fixture** (`uname` → `MINGW64`,
    `ps -W` fed by `FM_TEST_WIN_TABLE`, `-o` rejected, `FM_TEST_WIN_PS_FAIL`) for the
    Windows-tagged owner cases, because there is no Cygwin userspace on this host;
  * a **provider root** (`FM_PROC_ROOT_OVERRIDE`, the override the repo's other `/proc`
    readers already honor) of real `/proc` symlinks, used only to make one live owner's
    identity unreadable while the session's own identity stays readable.

## Scenarios (all driven through the real public executables)

| # | Scenario | Result |
|---|----------|--------|
| 1 | `ps` denied: a session acquires its own home lock instead of wedging read-only | pass |
| 2 | `ps` denied: a second session refuses a lock held by a live harness owner, lock untouched, and `fm-lock.sh status` reads `held` | pass |
| 3 | `ps` denied: a lock left by a dead owner is reclaimed | pass |
| 4 | Adversarial: a live owner whose identity cannot be read is refused; the same live owner is reclaimed when readable; a dead owner is reclaimed under the same unreadable provider | pass |
| 5 | Zero-form and malformed records (`''`, whitespace, `0`, `00`, `000`, `0000`, `not-a-pid`, `win:`, `win:7abc`, 21-digit) stay reclaimable | pass |
| 6 | A live numeric harness holder reads `held` on `fm-lock.sh status` and `lock.state=held / live_harness=true` on `fm-inbox.sh ready`; a live non-harness stays fail-closed | pass |
| 7 | Windows-tagged owner: live tagged harness and unreadable Windows table refuse takeover; tagged pid gone, reused by a non-harness, or malformed is reclaimed | pass |
| 8 | Stop auto-arm hook: reclaims a readable non-harness owner (with and without `ps`), stays inert for an unreadable live owner | pass |
| 9 | Cursor turn-end guard (the second moved call site): same two arms | pass |

`results.tsv` holds every individual assertion (72 checks, all pass).

## Pre-fix reproductions (same fixtures, that commit's own executable)

* `095db3bc` (base): `ps` denied, own-lock acquisition →
  `error: cannot locate harness process in ancestry`, no lock written (scenario 1)
  — this is the read-only wedge the change removes.
* `a3a31fca`: `state/.lock` of `00`, `000`, `0000` → `another live firstmate session
  holds the lock (pid 00 …)`, lock kept (scenario 5).
* `1e81e69d`: a genuinely live, verified numeric harness holder →
  `lock: stale (pid N dead or not a harness)` and `lock.state=unknown /
  live_harness=false` (scenario 6); `3c1e4684` (fork point) reports `held` for the same
  holder, so the correction restores the fork-point behaviour.

## Targeted suites

* `tests/fm-session-lock-ps-denied.test.sh` — ALL PASS.
* `tests/fm-inbox.test.sh` — PASS.
* `tests/fm-session-lock-ancestry.test.sh` — one failing assertion,
  `the pty-host was not reparented to init after the daemon ended`. It is **pre-existing
  and environmental**: the identical assertion fails at base `095db3bc`
  (`suite-fm-session-lock-ancestry-BASE-095db3bc.out`), because orphans on this host
  reparent to a nested user `systemd` (pid 1310, a child subreaper) instead of pid 1
  (`logs/pty-host-reparent-environment.txt`). Nothing in this change touches process
  reparenting.
