# Live validation log - fix/5378-startup-network-wake-receipt

Driver: disposable `bin/fm-lab-home.sh create` lab homes under /tmp, driven with the
real `bin/fm-startup-network.sh` (start/run/harvest/report/prune/recover),
`bin/fm-wake-drain.sh`, and `bin/fm-guard.sh` from this worktree. The only stand-in is
the external `gh` network client on PATH; bootstrap is the real `bin/fm-bootstrap.sh`
run in its `FM_BOOTSTRAP_NETWORK=only` probe phase.

## Scenario A - a late actionable startup check still reaches supervision

Fixture: disposable `gh` sleeps 8s then fails (`gh: authentication required`), so the
deferred gh-auth probe finishes AFTER the session-start drain.

1. `bin/fm-startup-network.sh start --locked 0 --harvest-pid 999999999` returned 0
   immediately; status recorded `state=running`.
2. The drain ran while the check was still in flight (`harvest --pid 999999999`):
IN PROGRESS - the deferred network checks have not finished yet.
NOT yet confirmed: GitHub authentication.
Started 0s ago, bounded at 120s.
Only a FAILED or otherwise actionable result arrives as a `check: startup-network:<generation>` wake; a clean success stays silent.
The durable result is readable on demand with {run-worktree}/bin/fm-startup-network.sh report; until it finishes, treat none of it as confirmed.

3. On completion, the retained result, the generation-scoped wake row and its receipt:
   - `state/.startup-network-results/<generation>/{report,status}` retained
   - `.wake-queue` row: `check  startup-network:<generation>`
   - `state/.startup-network-wake-receipts/<generation>`
4. `report --generation <generation>` (on demand, after the drain):
completed off the startup path in 8s: GitHub authentication.
NEEDS_GH_AUTH
These ran AFTER the sections above were composed, so re-read any record a line here names.
TIMINGS - where the deferred network checks spent their time (ms):
  phase       gh-auth                                    start=+92      elapsed=8007
  stage       network-checks probe                       start=+29      elapsed=8079
  slowest: stage network-checks probe 8079ms, phase gh-auth 8007ms

5. Supervision was told the home still needs watching while that result was undelivered
   (`bin/fm-guard.sh`, needed=true because of the startup obligation):
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
●  WATCHER DOWN - SUPERVISION IS OFF
●  X-mode relay polling needs supervision, but no watcher has a fresh beacon (last beat: never, grace 300s).
●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
●  This is a supervision warning only; the guarded operation WILL still run.
●  After draining queued wakes, repair a missing or failed watcher cycle with the Pi tool fm_watch_arm_pi, or restart Pi with -e {run-worktree}/.pi/extensions/fm-primary-turnend-guard.ts -e {run-worktree}/.pi/extensions/fm-primary-pi-watch.ts if the extensions are not loaded.
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.

6. The durable drain presented the generation-scoped wake to the session:
1794694864	1	check	startup-network:1794694856.3463441.999999999	check: startup-network: deferred startup network checks finished (done); read them with {run-worktree}/bin/fm-startup-network.sh report --generation 1794694856.3463441.999999999
WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 3464134.1794694864.J74j5u
WARNING: watcher still down (same stale episode; last beat: never, grace 300s) - full banner already printed this episode.
WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.

7. Acknowledging consumed the row; a repeated `recover`, `prune`, and second `drain`
   re-enqueued nothing (the receipt suppresses producer replay) and the current
   generation's result stayed retained. The guard then printed no supervision need.

## Scenario B - a late clean success stays silent but is retained

Disposable `gh` sleeps 6s then succeeds silently. Mid-flight drain:
IN PROGRESS - the deferred network checks have not finished yet.
NOT yet confirmed: GitHub authentication.
Started 0s ago, bounded at 120s.
Only a FAILED or otherwise actionable result arrives as a `check: startup-network:<generation>` wake; a clean success stays silent.
The durable result is readable on demand with {run-worktree}/bin/fm-startup-network.sh report; until it finishes, treat none of it as confirmed.

After completion: no `.wake-queue` file at all, no receipt, result retained with a
`clean:<generation>` settled marker, guard silent. `report`:
completed off the startup path in 6s: GitHub authentication.
(silent - no problems found)
TIMINGS - where the deferred network checks spent their time (ms):
  phase       gh-auth                                    start=+111     elapsed=6006
  stage       network-checks probe                       start=+40      elapsed=6089
  slowest: stage network-checks probe 6089ms, phase gh-auth 6006ms

## Scenario C - retention keeps the current, queued, and look-back generations

Seeded into the delivered lab home: settled generations 1000..1900, a queued generation
1200.1.1 with its receipt and queue row, an incomplete 0600.1.1, a symlink 0500.1.1 to a
directory outside the results root, and a foreign `not-a-generation` name.
`bin/fm-startup-network.sh prune` then:

before:
0500.1.1
0600.1.1
1000.1.1
1100.1.1
1200.1.1
1300.1.1
1400.1.1
1500.1.1
1600.1.1
1700.1.1
1794694856.3463441.999999999
1800.1.1
1900.1.1
not-a-generation
after:
1200.1.1
1794694856.3463441.999999999
1800.1.1
1900.1.1
not-a-generation
receipts after (current, queued, look-back kept; deleted generations' receipts removed):
1200.1.1
1794694856.3463441.999999999
1800.1.1
queue after (queued row untouched):
golden	1	check	startup-network:1200.1.1	check: startup-network: deferred checks finished
The symlinked entry's link is gone while its target still holds `DETACHED TARGET CONTENT`;
the foreign name and the incomplete-record rules match the approved contract, and a second
pass changed nothing. The queued generation stays readable for its consumer:
completed off the startup path in 1s: the deferred network checks.
ACTIONABLE_1200
These ran AFTER the sections above were composed, so re-read any record a line here names.

## Scenario D - incomplete backlog never starves older results, and each pass is bounded

Seeded 70 newer incomplete completion directories plus 3 older settled ones (100/200/300).
Pass 1: `old_settled_present=0` (all three old settled results deleted on the first pass),
74 entries -> 10. Pass 2: 10 -> 3. Pass 3: unchanged 3 (look-back window only):
1794694901.3497779.999999998
2068.1.1
2069.1.1

## Focused suites run as the change's own regression evidence

- tests/fm-startup-network.test.sh (all assertions passed, incl. retention matrix,
  bounded-pass, start-never-scans, return-without-holding-stdout, watcher recovery)
- tests/fm-wake-queue.test.sh (startup receipt ownership, interruption, clean-refusal)
- tests/fm-turnend-guard.test.sh (startup obligation survives receipt until ack)
- tests/fm-claude-stop-autoarm.test.sh, tests/fm-cursor-primary.test.sh
