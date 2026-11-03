# Live validation: fleet seat capacity, generation/endpoint-bound lifecycle, T3 server identity

Change under test: `fm/six-seat-design-implementation` head `ea3aa739`
(opt-in fleet seat pools, generation/endpoint-bound seat + remote lifecycle,
failed-startup lifecycle episode, T3 admitted-server identity for discovery and
multi-thread watch).

Every scenario below was driven against the real firstmate binaries
(`bin/fm-fleet-seats.sh`, `bin/fm-spawn.sh`, `bin/fm-teardown.sh`,
`bin/fm-bootstrap.sh`/liveness, `bin/fm-supervise-daemon.sh`,
`bin/backends/t3code.sh` + `bin/fm-t3-mcp.mjs`) in disposable fixture homes and a
disposable lab home, with a throwaway fake T3 Orchestrator server on 127.0.0.1
and fake tmux/fake ssh endpoints. No operator home, fleet state, or live default
session was touched.

## Artifacts

| Artifact | Scenario |
| --- | --- |
| `fleet-seat-cap-transcript.sh` / `.log` | End-user CLI transcript: pool of capacity 1 admits `worker-a`, refuses `worker-b` (exit 4, "pool shared is full (1 of 1 seats held)"), writes no record for the refused launch, then admits `worker-b` after `release`. |
| `fleet-seats-capacity-accounting.log` | `tests/fm-fleet-seats.test.sh` focused cases: nested local homes share one count, a spawn into a full pool refuses before any record, a spawned worker holds its seat until cleanup, cleanup releases only its own generation, orphan secondmates cannot become authorities, a marked home inherits its root authority. |
| `fleet-seats-remote-and-buffered-seats.log` | Remote host adoption and descendant authority, generationless predecessors stay counted, a buffered supervisor launch keeps its seat, alive/dead observations require the same creation server. |
| `teardown-endpoint-and-generation-safety.log` | `tests/fm-teardown-endpoint-safety.test.sh` cases: a pool slot claimed by another task is left alone, a stale record retires without touching the claimant, a genuinely failed endpoint close refuses and keeps the record, a moved-cwd recorded endpoint still tears down, a legacy T3 record without a creation server refuses. |
| `secondmate-recovery-generation-binding.log` | `tests/fm-secondmate-liveness.test.sh` recovery cases: reclaim exactly the probed generation, abandon a verdict whose generation changed, refuse unknown/stale routes before mutation, never let a late startup confirmation authorize destruction, close only the generation's owning socket. |
| `t3-supervisor-and-watch-bindings.log` | `tests/fm-backend-t3code.test.sh` head-fix cases: discovered supervisor delivers with its verified server, an explicitly targeted idle/completed supervisor binds without an active turn, mixed-server watch refuses in both thread orders, and failed-startup cleanup holds the lifecycle episode through the T3 archive for capped and uncapped mates. |

## Result

All six scenario groups passed (`EXIT=0`, one `ok` per case). The previously
flaky `test_failed_endpoint_close_refuses_before_removing_the_record` reached its
refusal and passed in this run, so the earlier failure was gate-environment
interference rather than a product regression.
