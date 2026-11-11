# Ready-queue dispatch validation at 1827d049 (fm/fm-ready-queue-dispatch-r3)

Change under test: readiness-first heartbeat triage (`bin/fm-ready-queue-lib.sh`
consumed by `bin/fm-watch.sh` and `bin/fm-supervise-daemon.sh`), the away/attended
ready-work dispatch + handoff contract in `bin/fm-branch-prompt.sh`, and the
per-outcome (uncollapsed) captain presentation in `bin/fm-wake-drain.sh`.
Head also carries the CI shard-count change (PORTABLE_SERIAL_SHARDS 12).

All drives used disposable homes (own `state/`, `config/`, `data/`, markdown
backlog via the documented `.tasks.toml`), never the operator's `FM_HOME`, and
were torn down in this turn. Real product scripts executed: `bin/fm-watch.sh`,
`bin/fm-wake-drain.sh`, `bin/fm-tasks-axi.sh`, `bin/fm-captain-hold.sh`,
`bin/fm-branch-outcome.sh`, `bin/fm-supervision-host.sh`,
`bin/fm-branch-prompt.sh`, `bin/fm-test-run.sh`. Stubbed boundaries: `tmux` fleet
scan (lab home has no panes), the tasks-axi CLI only for the unreadable/slow
readiness probes, and the supervision engine (stub engine, as the host suite
documents) — no model/provider call was made.

## Product drive (`t6-drive-ready-queue.sh`, transcript `t6-ready-queue-drive-transcript.log`)

| case | posture | queue | wake reason | streak after | durable wake drained |
|---|---|---|---|---|---|
| away-ready | away | 1 ready unit | heartbeat | **0** (was 3) | heartbeat row |
| away-unreadable | away | probe exits 2 | heartbeat | **0** | heartbeat row |
| away-slow-probe | away | probe hangs 60 s | heartbeat | **0** | heartbeat row (11 s bounded) |
| attended-ready | attended | 1 ready unit | heartbeat | **0** | heartbeat row |
| away-held | away | captain-held unit | heartbeat (afk always emits) | 4 (plain) | heartbeat row |
| away-empty | away | proven empty | heartbeat (afk always emits) | 4 (plain) | heartbeat row |
| attended-empty | attended | proven empty | none, quiet | 4 | empty |
| prefix-away-ready | away | 1 ready unit, **pre-fix watcher (e467ad8bb)** | heartbeat | **4** | heartbeat row |
| prefix-away-empty | away | proven empty, pre-fix | heartbeat | 4 | heartbeat row |

The pre-fix row reproduces the reported defect (ready work doubling the idle
interval); the fixed head resets it to 0 while the empty queue keeps plain
accounting.

## Suites (real CLI paths)

- `bash tests/fm-watch-ready-queue.test.sh` → 20/20 ok, exit 0, 34 s
  (`t1-ready-queue-suite.log`): addressing forms, attended/away ready and
  unreadable heartbeats reset the streak and reach the drain, empty and held
  queues stay quiet, emitted prompt contract, daemon readiness for
  skip=heartbeat and skip=signal plus empty/held/unreadable/failed acknowledgement.
- `bash tests/fm-supervision-host-drain.test.sh` → 19/19 ok, exit 0, 55 s
  (`t2-drain-suite.log`), including the older ready-work handoff, the long
  handoff (700/4500 B), repeated captain outcomes, and unshown-outcome retention.
- `bash tests/fm-branch-supervision.test.sh` → 37/37 ok, exit 0, 43 s
  (`t3-branch-supervision-suite.log`).
- `bash tests/fm-supervision-host.test.sh` → 29/29 ok, exit 0, 357 s
  (`t4-supervision-host-suite.log`) under a clean caller ancestry
  (`bash <- pi <- no-mistakes daemon <- systemd --user <- systemd`; receipt
  `t4-supervision-host-ancestry.txt`), real host/arm/watcher/wake-grant/drain/
  outcome/lease scripts with a stub engine.
- `bin/fm-test-run.sh --check-coverage` → `FM_TEST_COVERAGE ok ... serial_shards=12
  serial_max_ms=1095694 serial_budget_ms=1200000`; `--list-lanes` prints the 12
  serial shard lanes; `--lane portable-serial-1of11` is refused with exit 2
  (`t7-test-runner-coverage.log`).

## Not driven

- Away authorization judgment (S4): emitted prompt bytes and a stubbed engine do
  not prove an agent obeys scope; this is model interpretation, so it stays
  untested rather than promoted from a contract assertion.
- Live harness primary (S6): no product model/provider call is authorized in
  this run, so no primary was launched and no auth store was read.
