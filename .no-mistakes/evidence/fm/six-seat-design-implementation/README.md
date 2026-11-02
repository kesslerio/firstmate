# Live validation: fleet seat pools (fm/six-seat-design-implementation, e8118e5e)

All live drives used a disposable marked lab home (`bin/fm-lab-home.sh create`) with
`FM_HOME` pointing at it, a throwaway git project, real `bin/fm-spawn.sh`,
`bin/fm-fleet-seats.sh`, `bin/fm-teardown.sh`, and a real private tmux server
(`TMUX_TMPDIR=$LAB/tmux`) launching the machine's real `claude` harness. Every lab was
removed in the same turn; no fleet state or operator home was touched.

| # | Scenario | Result | Artifact |
| --- | --- | --- | --- |
| 1 | Pooled worker spawn into a full pool refuses before any endpoint/worktree/record, naming the holder | pass | `scenario-01-capacity-and-model-refusals.log` |
| 2 | Harness-default model and raw launch command refused while pools are configured | pass | `scenario-01-capacity-and-model-refusals.log` |
| 3 | Real spawned worker holds seat 1 of 1, second pooled launch refused, teardown frees the generation, next launch admitted | pass | `scenario-02-second-launch-refused.log`, `scenario-03-teardown-release.log`, `scenario-04-release-admits-next.log` |
| 4 | A local second mate home's pooled record spends the fleet root's seat | pass | `scenario-05-shared-capacity-remote-and-generations.log` |
| 5 | An unresolved legacy model occupies every declared pool | pass | `scenario-05-shared-capacity-remote-and-generations.log` |
| 6 | A registered remote with no served certificate refuses admission; removing it restores admission | pass | `scenario-05-shared-capacity-remote-and-generations.log` |
| 7 | Released generations never revive; a successor is admitted on the freed seat | pass | `scenario-05-shared-capacity-remote-and-generations.log` |
| 8 | A live primary session lock holds the pooled seat; after it ends the launch is admitted | pass | `scenario-06-primary-seat.log` |
| 9 | Malformed/unreadable pool declaration refuses admission; no declaration leaves launches uncapped | pass | `scenario-07-authority-boundaries.log` |
| 10 | Remote serve/adoption and Rex ownership across a real home | pass (e2e suite) | `suite-fm-fleet-seats.log`, `suite-t3-teardown-remote-seat.log` |
| 11 | A reclaimed pooled T3 generation cannot resume beside its replacement | pass (e2e suite) | `suite-t3-teardown-remote-seat.log` |
| 12 | Lab-session and Rex retirement retry identity | pass (e2e suite) | `suite-fm-remote-secondmate-session.log` |
| 13 | Archive generation naming from `remote_spawn_gen`/`fleet_seat_generation` | pass (e2e suite) | `suite-fm-record-export.log` |
| 14 | Malformed Rex route reply refused at the parent boundary with a host endpoint already recorded (HEAD fixture fix) | untested | `suite-fm-remote-secondmate-lifecycle-e2e.log` |

## Local environment limits observed (reproduced on the base commit or host-specific)

- `tests/fm-teardown-endpoint-safety.test.sh` case
  `teardown reported success after a close that failed` fails identically on the
  unmodified base tree (`git archive 9224c90` in `/tmp`), so it is pre-existing here.
- `tests/fm-backend-t3code.test.sh` case `installed Codex failed the tracked
  configuration guard` fails because it calls `/usr/bin/printenv`, which this host
  does not have (the branch's base tree fails earlier in that suite).
- `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` aborts with exit 127 after the
  unreachable-remote case because its remote-job PATH (`/usr/bin:/bin`) lacks the
  standard toolchain on this host (`/usr/bin` has 2 entries, `/bin` a 12-tool subset),
  so the later Rex-reply section never runs.
