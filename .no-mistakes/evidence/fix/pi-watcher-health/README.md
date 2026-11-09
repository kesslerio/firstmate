# Live validation — fix/pi-watcher-health (14d06b0..2ef23d4)

All runs used disposable `fm-lab-home.sh` lab homes under `mktemp -d`, a lab-private `TMPDIR`,
and the tracked product scripts from this worktree. Every lab was removed at the end of its
scenario, and no fleet/home state outside the lab was touched.

## S1 — pending-reply decision snapshots live in a private user root (live, pass)

Driver: `s1-drive.sh`. Real `bin/fm-watch.sh` (FM_POLL=1) against a lab home with
`config/wait-no-turns` and 21 pending-reply records whose own open decision denies the recovery.

Observer evidence: `s1-observer-uniq.log`

```
root mode=700 owner=1000
snapshot-dir .../tmp/fm-pending-reply-1000/fm-pending-reply-decisions.1591550.7rixQq contents=
snapshot-dir .../tmp/fm-pending-reply-1000/fm-pending-reply-decisions.1591550.7rixQq contents=0
snapshot-dir .../tmp/fm-pending-reply-1000/fm-pending-reply-decisions.1591550.7rixQq contents=0 1
```

No `legacy-path-dir` sample was ever taken (0 matches), i.e. nothing was created directly in
`TMPDIR`. Post-run (`s1-post.sh.out`): `TMPDIR` empty, record still `phase=awaiting_report`
with no recovery attempt — the denial still holds.

## S2 — unsafe snapshot paths are never followed or deleted (live, pass)

Driver: `s2-drive.sh`. Real watcher with (a) `$TMPDIR/fm-pending-reply-<uid>` pre-planted as a
symlink to a victim directory, (b) `$TMPDIR/fm-pending-reply-decisions.<watcher-pid>.swap`
as a symlink to a second victim, and (c) a legitimate legacy leftover directory for the
watcher's own pid.

`s2-post.sh.out` shows both victim directories and their file contents intact, both symlink
paths still symlinks and still present, the legitimate legacy leftover directory swept at
exit, `TMPDIR` otherwise empty, and the pending record still denied (`phase=awaiting_report`,
no recovery attempt) — so refusing the unprovable root did not degrade delivery behavior.

## S3 — an interrupted tick's snapshot is removed on watcher exit (live, pass)

Driver: `s3-drive.sh`. A snapshot directory named with the running watcher's pid was planted
under the private root (`s3-before.txt`), then the watcher received TERM. `s3-post.sh.out`
shows `TMPDIR` empty: both the abandoned snapshot directory and the private root are gone.

## S4 — a real Pi primary reports verified watcher health (live, pass)

Driver: interactive real `pi` TUI in a lab-private tmux socket, launched from this worktree
with the tracked `.pi/extensions/fm-primary-pi-watch.ts`, `FM_HOME` = lab home whose
`config/watch.env` exports `FM_POLL=600`.

- First tool call: `watcher: started Pi extension arm child 1` (state `starting`).
- Second call, established arm: `watcher: unchanged - Pi extension verified this home's
  watcher identity and fresh progress` (state `healthy`).
- Watcher is the lab's own process: `bin/fm-watch.sh` from this worktree, lock pid matches,
  `sleep 600` child proves the home's poll cadence reached the arm (`s4-state.txt`).

Transcript: `s4-pi-pane.txt`.

## S5 — poll-derived grace, and the 30-second monitor repairs a stalled watcher (live, pass)

Same live Pi primary, no further tool call needed for the repair.

- Beacon set to 400 s old (past the fixed 300 s floor, inside the derived 660 s grace):
  watcher pid unchanged after 45 s, no extension-log row, next tool call still `healthy`.
- Beacon set to 720 s old (past the derived 660 s grace): with no tool call the monitor
  replaced the watcher — `state/.watch-extension.log` (`s4-extension-log.txt`):

```
health monitor state=retrying arm=1678880
restore attempt=0 predecessor=1716717 start=ok pid=1717167
confirm generation=1678922.1794253493.TjgCSP watcherPid=1717194 result=confirmed
```

  `s4-state.txt` records the new lock pid 1717194 with `sleep 600` and a fresh beacon, and a
  later tool call reports `healthy` for that same pid.

## Targeted suites

- `tests/fm-pending-reply.test.sh` — pass (exit 0), `t-pending-reply.log`.
- `tests/fm-pi-watch-extension.test.sh` — fail at
  `test_pi_confirm_failure_spares_a_newer_arm`, `t-pi-watch-extension.log`.
- Same suite at base `14d06b0` (extracted with `git archive` into a temp dir) — pass, 72 cases,
  `t-pi-watch-extension-base.log`.
- Re-ran the single case in isolation against the target tree: fails; against the base tree:
  passes. First failing extension revision by bisecting the tracked extension file across the
  branch is `2ae2b9393`.
- With a 30 s wait the wake that arrives is
  `watcher: FAILED - Pi extension could not start the successor watcher cycle` +
  `watcher: unhealthy - ... replacement withheld ...` +
  `watcher: FAILED - Pi extension could not restore watcher continuity after 5 retries`,
  never the expected `handling delivery confirmation was rejected`. The restore path now reads
  an existing live arm through the new health verdict (unprovable identity/beacon → `unhealthy`)
  instead of attaching to it, so the delivery-confirmation wake for the stale successor never runs.
