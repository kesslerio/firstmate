# Ready-queue dispatch: live validation evidence (head 954c3d9d)

All runs used disposable, contained fixtures: a private `HOME`, `TMPDIR`,
`XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, `XDG_DATA_HOME` under a fresh
`/tmp/fm-live-*` lab, with every inherited `FM_*`/`TASKS_AXI_*`/`HERDR_*`
override unset before the suite started. No operator home, real fleet state,
credential store, or live tmux/herdr session was touched. No product model or
provider call was made; suites use the repository's stub engine and fake
framework. Labs were removed after the logs below were copied here.

## Scenario runs

| Scenario | Command (run from the gate worktree, contained env) | Result |
|---|---|---|
| S1/S2/S3 | `bash tests/fm-watch-ready-queue.test.sh` | 18/18 cases pass (`s1-fm-watch-ready-queue-suite.log`); manual CLI transcript `s1-s3-manual-cli-transcript.log` and `s3-unreadable-manual-cli-transcript.log` |
| S5 | `bash tests/fm-supervision-host-drain.test.sh` | 19/19 cases pass (`s5-fm-supervision-host-drain-suite.log`) |
| change regression/lifecycle | `bash tests/fm-branch-supervision.test.sh` | 37/37 cases pass (`s6-fm-branch-supervision-suite.log`) |
| host lifecycle | `FM_SUPERVISION_HOST_TEST_GROUP=early bash tests/fm-supervision-host.test.sh` (this head has no group split, so the whole suite runs) | 29/29 cases pass (`s7-supervision-host-suite-under-harness-ancestry.log`) |
| S7 | `bash tests/fm-supervision-host-park.test.sh` under harness caller ancestry | 19/19 unrelated cases pass; the tagged-ownership case stands down because the tuned `pi` ancestor is harness-shaped (`s7-park-suite-under-harness-ancestry.log`) |
| S7 (clean ancestry) | the same tagged-ownership test function, run from a `setsid` double-forked runner whose parent chain is `bash -> systemd --user -> systemd` | 1/1 pass (`s7-tagged-ownership-clean-ancestry.log`), ancestry receipt `s7-tagged-ownership-ancestry-receipt.txt` |

## Manual CLI evidence (S1/S3)

The manual transcript drives the real product binaries against a disposable
markdown backlog home:

* landed dependency + stale spending title: `fm-tasks-axi.sh ready` reports
  `count: 1`, and `fm-watch.sh` exits with `heartbeat` and a durable
  `heartbeat` record in `state/.wake-queue`, which `fm-wake-drain.sh` presents.
* empty backlog: watcher reviews (`.heartbeat-streak` advances) but prints
  nothing and creates no wake queue.
* held queued unit: same quiet result.
* unreadable readiness (`tasks-axi` exits 2): watcher emits `heartbeat`; in the
  away daemon `FM_INJECT_SKIP=heartbeat` does not suppress it, and the
  `ready-queue fleet check` escalation replaces the wake record.

## S4/S6 (not live)

S4 (away-scope model judgment) needs a real engine turn, and S6 (live harness
primary) needs an authenticated product model/provider call. The recorded
validation decision forbids product model/provider calls, auth-store access, and
primary launch in this gate, so both remain untested here. The emitted prompt
contracts and the development-only eval `tests/development/ready-queue-away.sh`
were not promoted to live evidence.
