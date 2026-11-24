# Live validation: watcher liveness beacon tracks cycle progress

Branch: `fix/watcher-beacon-progress` (target `6129fae8`, base `68918448`).
All runs below were executed from the gate worktree against disposable lab
homes (`bin/fm-lab-home.sh create`, removed in the same run) or the repository's
own real-process regression suite. No operator home, fleet state, or credential
store was touched.

## Scenario 1 + 2: a working long cycle stays fresh, raises no banner, accepts a successor

`manual-live-run.log`, `manual-live-evidence/m1-*.out`, `midcycle-proof.log`

- Lab home, three registered checks that each `sleep 2.5`, `FM_GUARD_GRACE=4`,
  `FM_POLL=1`, real `bin/fm-watch.sh` on that home.
- Over the observation window the beacon age never exceeded 3s against a 4s
  grace (`max_beacon_age_over_14s=3s`), and during one *unfinished* cycle
  (`cycle_changes=0` for the whole 9s sample, four 3s checks = a >=13s cycle)
  the beacon advanced 2 times mid-cycle with age staying <=3s
  (`total_mid_cycle_beacon_advances=2 cycle_marker_changes=0`). A top-of-cycle
  touch would have aged with the cycle and passed the 4s grace.
- Real `bin/fm-guard.sh` on that home printed no `WATCHER DOWN` banner
  (`GUARD_BANNER=no`, exit 0).
- Real `bin/fm-watch-arm.sh` attached to the working watcher instead of
  refusing it: `watcher: attached pid=3799745 (beacon 1s)`.

## Scenario 3 (adversarial): a frozen watcher with a still-working child ages and alarms

`manual-live-run.log`, `manual-live-evidence/m2-guard-frozen.out`

- `kill -STOP` on the real watcher PID mid-sweep. The in-flight check child kept
  working after the parent froze (`done_lines_before=4` -> `done_lines_after_freeze=5`).
- The beacon still aged past the grace (`beacon_age_while_frozen=7s`, grace 4s)
  and the real guard printed the banner:
  `WATCHER DOWN - SUPERVISION IS OFF ... (last beat: 8s ago, grace 4s)`.
- After `SIGCONT` the beacon refreshed again (`beacon_age_after_CONT=1s`).

## Scenario 4 (adversarial): only the watcher process may refresh the beacon

`beacon-progress-suite.log` (real processes, `tests/fm-watch-beacon-progress.test.sh`)

- `ok - progress refresh is inert outside a watcher, so no library invents liveness`
- `ok - child processes update the progress marker and cannot touch the beacon directly`
- `ok - signal scan progress keeps only a running watcher healthy` (a slow scan
  via an external `od` boundary shim keeps a *running* watcher fresh, and a
  frozen parent's scan refreshes nothing)
- `ok - a watcher frozen with SIGSTOP during a display sweep trips the guard`
- `ok - a genuinely stalled holder is still evicted and replaced past the hard bound`
- `ok - explicit short and long FM_HEARTBEAT cadences govern scheduled heartbeats`

19 assertions, 16 cases, `FM_TEST_COMPLETE`, exit 0, 42.7s.

## Scenario 5: long-poll home derives its grace instead of the flat 300s default

`manual-live-run.log`, `manual-live-evidence/m3-*.out`

- Lab home with `config/watch.env` containing `FM_POLL=300`, a live
  identity-matched lock holder, and a beacon backdated 320s (past the historical
  300s default).
- Real `bin/fm-guard.sh` with **no** explicit grace judged it healthy:
  `GUARD_BANNER_DERIVED=no` (derived grace 360s = max(300, poll + 60), the
  documented formula).
- Control: the same beacon with an explicit `FM_GUARD_GRACE=300` produced
  `GUARD_BANNER_300=yes`, proving the pre-fix flat default would have alarmed.

## Scenario 6: refreshed duration hint is what the shard packer consumes

`check-coverage.log`, `shard-packing-hint-evidence.txt`, `fm-test-run-suite.log`

- Committed row `tests/fm-watch-beacon-progress.test.sh	40213` and the matching
  provenance sentence in `docs/fm-test-portable-shards.md`.
- `bin/fm-test-run.sh --check-coverage` -> exit 0:
  `FM_TEST_COVERAGE ok total=344 ... serial_unhinted=0 serial_max_ms=940120
  serial_budget_ms=900000` (the over-budget shard is the single-script shard 1;
  every multi-script shard models 885311-885467 ms, inside the 900000 ms target).
- `bin/fm-test-run.sh --list-scheduled --lane portable-serial-7of19` orders the
  shard strictly by the committed hints, with the beacon row in its 40213 ms
  position between 59223 ms and 29000 ms.
- `tests/fm-test-run.test.sh` (real runner, sub-suites): the packing-relevant
  cases passed — `portable parallel lanes are fully hinted and packed within 5%
  of each other`, `portable serial shards are a deterministic disjoint cover`,
  `coverage guard bounds the unmeasured share and serial packing within fifteen
  minutes`, `serial packing accepts the exact budget, keeps an indivisible
  overflow, and refuses a multi-script overflow`. The file was then stopped by
  this run's own 620s timeout inside an unrelated `--jobs 2` scheduler case
  (`exit=124`); no packing case failed.
