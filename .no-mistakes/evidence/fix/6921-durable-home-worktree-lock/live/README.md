# Live validation: durable secondmate homes, owned Git locks, interruption-safe slot return

Every scenario below was driven against the real product code in the gate worktree
(`bin/fm-home-seed.sh`, `bin/fm-teardown.sh`, `bin/fm-home-payload-lib.sh`,
`bin/fm-home-worktree-lock-lib.sh`) and a **real treehouse v2.0.1 pool** plus a
**real tmux server on a private socket**. Nothing stands in for the product: the
pool is created with real `treehouse get --lease` / `treehouse return --force`, the
homes are real Git linked worktrees, the locks are real `git worktree lock`
records, and the interrupts are real signals.

Fixture per scenario (`fm-live-common.sh`): one `mktemp -d` world containing
`fmroot` (a copy of the change's worktree committed as a Git repo),
`pool` (treehouse root pinned by `treehouse.toml` inside the world), `lab` (the
firstmate home with `state/` and `data/`), and `tmux` (a private `TMUX_TMPDIR`).
The gate-lifecycle refusal is bypassed with `FM_GATE_REFUSE_BYPASS=1` — the
documented harness route — because the gate worktree is the only permitted code
root and cloning it would mutate the gate repo. Each world, its pool leases and
its tmux server are removed in the same run.

| scenario | script | log |
| --- | --- | --- |
| A owned lock + real retirement + reusable slot | `scn-a-lock-retire-reuse.sh` | `scn-a-lock-retire-reuse.log` |
| B foreign lock refuses forced retirement | `scn-b-foreign-lock.sh` | `scn-b-foreign-lock.log` |
| C handled SIGTERM restores payload and protection | `scn-c-handled-term.sh` | `scn-c-handled-term.log` |
| D SIGKILL leaves a record; next entry recovers and finishes | `scn-d-sigkill-recovery.sh` | `scn-d-sigkill-recovery.log` |
| E committed return discards staging, slot stays leasable | `scn-e-committed-discards.sh` | `scn-e-committed-discards.log` |
| F unleased slot: failed return restores, success clears | `scn-f-unleased-slot.sh` | `scn-f-unleased-slot.log` |
| G new real process owner blocks payload restoration | `scn-g-process-owner.sh` | `scn-g-process-owner.log` |

Scenario C and D widen only the external tool's latency (`sleep` before the real
`treehouse return`) so a signal can be delivered while the return is in flight;
no product logic is replaced. Scenarios E, F and G call
`fm_home_payload_return` / `fm_home_payload_recover` / `fm_home_payload_finalize`
directly — the shared boundary `bin/fm-teardown.sh` and `bin/fm-home-seed.sh`
call — against the same real pool and real locks.

The change's own focused end-to-end tests were also run:
`tests/fm-home-payload-return.test.sh` (rc=0) and
`tests/fm-secondmate-safety.test.sh` (84 ok, rc=0), plus
`bin/fm-test-run.sh --check-coverage` (rc=0, `serial_unhinted=44`,
`serial_max_ms=1195829` of a 1200000 budget) for the provisional serial hint the
intent requires.

Result: all 7 live scenarios pass (91 assertions), no failures.
