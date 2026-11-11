# Round 5 – away readiness heartbeat accounting (31b9a39a4)

Change under test: `bin/fm-watch.sh` heartbeat triage now evaluates
`fm_ready_queue_needs_review` **before** the away/attended posture split, so
ready or unknown backlog readiness uses `wake "heartbeat" actionable` (resets
`.heartbeat-streak`) in every posture, while an afk heartbeat with a
proven-empty queue keeps plain accounting for daemon-owned triage.

## Product-level drive (`drive-heartbeat-accounting.sh`)

Real `bin/fm-watch.sh` and `bin/fm-wake-drain.sh`, disposable `FM_HOME` per case
(own state/config/data, markdown backlog via `.tasks.toml`). Stubbed boundaries:
`tmux` (lab home has no panes) and the `tasks-axi` CLI for the
unreadable/hanging readiness probes only.

| case | posture | queue | watcher exit | wake reason | streak after | durable queue |
|---|---|---|---|---|---|---|
| away-ready | away | 1 ready unit | 0 (4.3 s) | `heartbeat` | **0** | heartbeat row, drained |
| away-unreadable | away | probe exits 2 | 0 (2.9 s) | `heartbeat` | **0** | heartbeat row, drained |
| away-slow-probe | away | probe sleeps 60 s | 0 (14.4 s) | `heartbeat` | **0** | heartbeat row, drained |
| attended-ready | attended | 1 ready unit | 0 (7.0 s) | `heartbeat` | **0** | heartbeat row, drained |
| away-empty | away | proven empty | stopped after accounting | `heartbeat` | 4 | heartbeat row, drained |
| attended-empty | attended | proven empty | stopped, quiet | (none) | 4 | empty |

Pre-fix baseline (`e467ad8bb:bin/fm-watch.sh`, same fixtures):

| case | streak after |
|---|---|
| prefix-away-ready | **4** (backoff doubled with ready work queued) |
| prefix-away-empty | 4 (unchanged, as intended) |

## Suites

- `bash tests/fm-watch-ready-queue.test.sh` at HEAD: 20/20 `ok`, exit 0 –
  including `away ready` and `away unreadable` heartbeat cases plus the daemon
  readiness cases.
- Same suite against `e467ad8bb`'s watcher: `not ok - away ready ready queue
  review doubled idle heartbeat backoff instead of resetting it` – the new
  assertion reproduces the reported regression and passes after the fix.
- `FM_TEST_ONLY=<case> bash tests/fm-watch-triage.test.sh` for the six heartbeat
  cases (absorb, unsurfaced backstop, masked backstop, afk idle accounting, afk
  signal endpoint, afk one-shot handoff): all `ok`.
