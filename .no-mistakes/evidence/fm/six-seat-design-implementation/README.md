# Live validation evidence: opt-in fleet seat pools

Change under test: `fm/six-seat-design-implementation`
(base `e1a7a2f`, target `cf9fc716`)

Every scenario below was driven against the real product in disposable labs built
for this run only: `bin/fm-lab-home.sh` homes, a private loopback `sshd` with a
real `ssh` client and the real `bin/fm-remote-entrypoint.sh` remote job worker,
real seat ledgers, real locks and real holder processes. No live default tmux or
Herdr session, no operator home, and no credentials were touched. All labs,
sshd listeners, holder processes and the worktree-local `state/` scratch
directory were removed in the same run.

| Evidence file | Scenario |
| --- | --- |
| `scenario0-one-pool-primary-local-and-remote.log` | One capacity-2 pool shared by the primary, a local secondmate home, and a remote host supervisor; a launch from the local secondmate is refused at the same count and admitted exactly when the primary releases its generation. |
| `scenario1-shared-capacity-primary-and-local-secondmate.log` | Primary + local secondmate share one ledger and capacity; a real `bin/fm-spawn.sh --secondmate` is refused at the full pool and admitted (then releases exactly its own generation on a prelaunch failure) when the pool has room; terminal generations never revive. |
| `scenario2-prepool-remote-supervisor-counted-once.log` | A supervisor that ran before the pool existed is certified once over real ssh, admits exactly one more launch in a capacity-2 pool, is refused with one row per counted holder afterwards, and keeps all pooled launches refused while its certificate is missing. |
| `scenario3-observing-receipt-model.log` | A launch that found the supervisor already running on another model is recognized by the receipt that observed it: serve certifies instead of refusing "unaccounted occupancy", the parent records the observed generation/model, one more launch fits, and a receipt bound to a model the host does not run is refused. |
| `scenario4-replacement-generation.log` | After a replacement was cancelled before it confirmed a startup, the next replacement replaces the generation the host records (queried over real ssh), not the cancelled candidate; naming the cancelled candidate as the host predecessor is fenced with `generation-mismatch`. |
| `regression-remote-generation.log`, `regression-remote-seat-adoption.log` | Repository regressions for the generation library and the host seat-operation receipt paths. |

## Curated inputs (disclosed)

Two of the artifacts are host-control-plane durable payloads whose production
requires a live Herdr agent pane inside the fixed `fm-remote` Herdr session:

- the host's observing receipt (`parent-route/<id>.seat-operation.<op>`) and the
  `existing` disposition in `scenario3`;
- the pre-pool host supervisor record in every remote scenario.

They are authored as input state in the documented formats; every product
decision after them (serve delivery over real ssh, adoption, counting,
reconciliation, capacity, refusals) ran live. The fixed `fm-remote` Herdr session
name means a real Herdr endpoint relaunch cannot be driven without writing to the
operator's Herdr root, so those scenario steps stop at the generation fence,
which is the decision the change owns.
