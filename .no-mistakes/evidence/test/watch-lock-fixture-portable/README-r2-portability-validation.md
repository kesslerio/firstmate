# watcher-lock fixture portability — round 2 live validation (target 4515263)

Host: NixOS 7.3.1 (zeppola). `/bin` has no `ln`, no `rm`, no `ps` on a
minimised host; `sleep` is coreutils multicall dispatching on `argv[0]`
(`exec -a <name> sleep` → `coreutils: unknown program '<name>'`, rc=1).

All runs drive the real suite (`bin/fm-test-run.sh tests/fm-watcher-lock.test.sh`)
which exercises the real `bin/fm-wake-lib.sh` lock primitives, `bin/fm-watch-arm.sh`
and `bin/fm-watch.sh`, not fixtures standing in for the product.

| # | scenario | command | result |
| --- | --- | --- | --- |
| 1 | target suite on this host (no `/bin/ln`, multicall `sleep`) | `bash bin/fm-test-run.sh tests/fm-watcher-lock.test.sh` | PASS 58/58, `exit=0` — `r2-target-host-suite.log` |
| 2 | target suite on a host whose `/bin` holds only `sh` | `bwrap --dev-bind / / --ro-bind /tmp/minbin.*/bin /bin bash bin/fm-test-run.sh tests/fm-watcher-lock.test.sh` | PASS 58/58, `exit=0` — `r2-target-minbin-suite.log` |
| 3 | regression: base 41a47c0 fixtures on that same "only `sh` in `/bin`" host | same sandbox at base commit | FAIL `not ok - acquirer could not reclaim dead steal owner (rc=8)` from `exec /bin/ln` — `r2-base-minbin-suite.log` |
| 4 | regression: base fixtures where `/bin` supplies `sh ln rm ps` (so the `exec -a` holder is the first thing to break) | same sandbox at base commit | FAIL `not ok - could not identify the fixture holder` (`exec -a "$dir/holder" sleep 300` dies instantly on multicall `sleep`) — `r2-base-exec-a-suite.log` |
| 5 | target suite in that exact `sh ln rm ps` sandbox | same sandbox at target commit | PASS 58/58, `exit=0` — `r2-target-exec-a-suite.log` |
| 6 | adversarial: does the suite still catch a broken lock implementation? | target tree copy with `fm_lock_reap_dead_link() { return 1; }` in `bin/fm-wake-lib.sh` | FAIL `not ok - reaper did not publish its election tombstone`, `exit=1` — `r2-mutation-lockreap-fails.log` |
| 7 | adversarial: is the replacement holder a live, fixture-named process, and is it reaped? | full suite with a 20 ms poll of `pgrep -f 'time\.sleep\(300\)'` | holders observed alive named `<case>/holder` for `lock-identity-mismatch` and `lock-daemon-stale-identity`; `pgrep -af 'time\.sleep\(300\)'` after the run: none — `r2-holder-fastpoll.log`, `r2-target-fastpoll-suite.log` |

Changed fixtures all report `ok` inside the only-`sh`-in-`/bin` sandbox:
`dead steal owner is reclaimed once without a nested steal marker` (ln shim),
`a competing reaper cannot remove the successor's steal mutex` (rm shim),
`lock whose recorded identity no longer recomputes …` and the daemon-holder case
(python holder), `a watcher that cannot publish its identity exits through its
cleanup` (ps shim), `arm defers TERM until startup watcher can run its lock
cleanup`, `arm TERM waits out a stalled singleton claim past the deadline …`
(arm ln shims).

Every run reported `gate_skip=false`, so no case silently skipped.
Throwaway base/target copies, the minimised `/bin` binds, and the mutated copy
were removed after these runs.
