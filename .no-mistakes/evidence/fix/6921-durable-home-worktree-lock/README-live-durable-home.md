# Live validation — durable secondmate homes and clean pool return (PR #7607 / #6921)

Everything below was driven against the real product binaries from commit
`052425a0e` in a disposable fixture, with a real `treehouse` v2.0.1 pool and real
Git worktrees. No fake tmux, no fake treehouse, no source reading.

## Fixture (disposable, removed at the end of the run)

* `$FIX/root` — a real git clone of the change worktree at `052425a0e` with its own
  `treehouse.toml` pool, so every worktree lived under `$FIX/home/.treehouse/`.
* `$FIX/lab` — an `bin/fm-lab-home.sh create` marked lab home, used as `FM_HOME`
  (the gate agent's authorized disposable home).
* `HOME=$FIX/home` for every fixture command, so the pool and tool state stayed
  inside the fixture.
* A private `tmux` server on `TMUX_TMPDIR=$FIX/tmux -L fm-lab` holding a real
  `firstmate:fm-<id>` window for each mate, so `fm-teardown.sh` closed a real
  endpoint.
* A realistic `state/<id>.meta` record (`kind=secondmate`, `home=`, `worktree=`,
  `spawn_gen=`) — the record `bin/fm-spawn.sh` writes — created as setup data.

## Scenarios and results

| # | Scenario | Result | Log |
|---|----------|--------|-----|
| 1 | Seed a durable home into a real pool slot: Git worktree lock + `firstmate-home-lock` receipt, plain `git worktree remove` refuses | pass | `sc1-seed-and-durability.log` |
| 2 | `bin/fm-teardown.sh <id>` retires the pooled home: slot back in the pool, payload cleared, lock released, receipt forgotten | pass | `sc2-teardown-clean-slot.log` |
| 3 | The next mate seeds into the just-returned slot through the real `treehouse get --lease` path, with its own identity and protection | pass | `sc3-seed-via-lease.log` |
| 4 | Adversarial foreign Git worktree lock: `fm-teardown.sh --force` refuses, foreign lock and records untouched | pass | `sc3-foreign-lock-refusal.log` |
| 5 | Adversarial ordering: a teardown refusal (missing identity marker) wins over the durable-home lock check that would itself refuse | pass | `sc4-refusal-ordering.log` |
| 6 | Failed pool return (real fresh `index.lock`): home payload, identity, owned lock, receipt, task record and route are preserved for retry | pass | `sc5-failed-return-retryable.log` |
| 7 | Handled TERM inside the payload move: home restored (identity, payload, owned lock, receipt, record, lease) and the retried teardown then returns a clean slot | pass | `sc6-interrupt-restores-home.log` |

## Observation (not a failure of this change)

`treehouse return --force <slot>` in v2.0.1 does not consult Git's worktree lock:
it re-marked the protected slot `available` in the pool while the home kept its
payload, identity and owned lock (the worktree itself was not removed). The change
promises that *ordinary Git removal* refuses a protected home, which held
(`git worktree remove` → `fatal: cannot remove a locked working tree, lock reason:
Firstmate durable home mate2 [...]`). `docs/t3code-backend.md` already tells an
operator to clear payload and release the owned lock before such a return, so this
is out of scope for the change; recorded here so a reviewer knows the durability
boundary is Git-level, not a defence against a forced pool return.
