# Live validation — round 4 (fix/pi-watcher-health @ 3a7dd8eea)

Disposable `fm-lab-home.sh` labs under `mktemp -d`, lab-private tmux socket
(`TMUX_TMPDIR=$LAB/tmux`, `tmux -L fm-lab`), tracked product scripts from this
worktree. Every lab was removed in the same turn; no fleet state, operator home,
or default tmux server was touched.

## Pi watcher health monitor — live, real `pi` primary (pass)

Driver: `live-pi-drive.sh`. Real `pi` TUI (`pi -a -nc --no-session`, tracked
`.pi/extensions/fm-primary-pi-watch.ts`) in a lab home whose `config/watch.env`
exports `FM_POLL=600`, with `FM_WATCH_EXTENSION_LOG_KEEP_LINES=200` so the
extension's own `state/.watch-extension.log` records monitor decisions.

1. Arm/healthy (`pi-arm-state.txt`, `pi-pane-after-arm.txt`): the extension's own
   arm child (pid parent = the pi process) started
   `bin/fm-watch.sh` from this worktree, lock pid 680892 with a matching
   `watcher-path` and `fm-home`, child `sleep 600` proving the home's poll cadence
   reached the watcher, and the tool reported
   `watcher: unchanged - Pi extension verified this home's watcher identity and fresh progress`.
2. Grace boundary (`pi-grace-inside.txt`, `pi-pane-inside-grace.txt`): beacon
   backdated 400 s — past the fixed 300 s floor but inside the 660 s
   poll-derived grace — left the pid unchanged after 40 s (more than one 30 s
   monitor tick), `monitor_rows=0`, and the tool still reported `unchanged`
   (healthy). No spurious replacement.
3. Automatic repair (`pi-health-replacement.txt`, `pi-final-state.txt`,
   `pi-pane-after-repair.txt`): beacon backdated 700 s (past the 660 s derived
   grace) with no tool call. Within 45 s the extension log recorded

   ```
   health monitor state=retrying arm=680846
   restore attempt=0 predecessor=720302 start=ok pid=720804
   confirm generation=680892.1794271329.nAjM7p result=confirmed
   ```

   The old watcher pid is gone, the new lock pid is 720831 (fresh beacon 32 s,
   child `sleep 600`), exactly one tracked `bin/fm-watch.sh` is running, and a
   later `fm_watch_arm_pi` call reports `unchanged … verified … fresh progress`.

## Interrupted pending-reply tick snapshot (live, pass)

Driver: `s3-drive.sh` (rerun against this commit). Real `bin/fm-watch.sh` in a
lab home; a snapshot dir named with the watcher's own pid planted under the
private decision-cache root (`s3-before.txt` shows the dir and its payload), then
TERM. `s3-post.sh.out` shows the lab `TMPDIR` empty afterwards: both the
abandoned snapshot and the private root were removed by the watcher's exit
cleanup.

## Targeted suites

- `tests/fm-pi-watch-extension.test.sh` — pass, 83 cases, no `not ok`
  (`/tmp/piwatch-suite.log`), including
  `ok - Pi retries an unready health replacement that failed during wake delivery once that delivery settles`
  and `ok - Pi confirm failure for a stale successor spares the newer arm`.
- `tests/fm-pending-reply.test.sh` — pass, 55 cases, `all pending-reply tests passed`.

## Not driven live

The held-branch-delivery variant (a health replacement's successor exiting before
readiness *while* a wake delivery is in flight) needs a supervision-branch wake
that holds its settlement across a real branch model turn; only that keeps the
extension's `delivering` guard true long enough to intersect an arm close.
Reported as untested, with the focused suite case above as the only coverage.
