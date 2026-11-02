# Live validation evidence — fix/5378-startup-network-wake-receipt

Change: durable status-last startup completion records, per-generation wake
receipts that suppress duplicate enqueue, and recovery through the existing
watcher cycle plus its ordinary acknowledgement. This is a rebase-only re-raise
of the same four commits onto current `origin/main` (9224c902); the branch
carries no new behavior.

How every scenario was driven: a disposable firstmate home under `/tmp`
(`FM_HOME` + a code root whose `bin/` symlinks the run worktree's real
`bin/*.sh`), using the real product scripts — `bin/fm-startup-network.sh`,
`bin/fm-wake-drain.sh`, `bin/fm-watch.sh`, `bin/fm-guard.sh` — with the real
`bin/fm-bootstrap.sh` and the machine's real `gh`. No network sweeper was
stubbed. Where an actionable finding was needed, `gh` was pointed at an empty
disposable `GH_CONFIG_DIR`, so `gh auth status` genuinely reports
`NEEDS_GH_AUTH`; that is the only injected condition. Labs were removed in the
same evidence turn.

| # | Scenario | Result | Log |
|---|----------|--------|-----|
| s1 | Late actionable result retained as `results/<gen>/{report,timings,status}` (status written last), promoted to the shared report, one generation-keyed wake; producer replay does not duplicate it | pass | `s1-late-actionable-retained-and-wakes-once.log` |
| s2 | Real drain + acknowledgement writes `.startup-network-wake-receipts/<gen>`, removes the row, and later producer replay stays silent | pass | `s2-ack-receipt-ends-obligation.log` |
| s2b | Adversarial causality: with the receipt removed the guard re-raises the supervision obligation; restoring it ends it again with no new row | pass | `s2b-receipt-is-what-ends-obligation.log` |
| s3a | A completed result whose shared publication cannot be promoted stays retained and silent, and `report` surfaces the retained findings | pass | `s3-retention-when-publication-target-fails.log` |
| s3b | The existing watcher cycle publishes the retained completion and wakes exactly once, with no rerun of the checks; ordinary acknowledgement completes it | pass | `s3b-watcher-recovers-retained-completion.log` |
| s4 | Adversarial: a superseded generation cannot publish over its successor, cannot re-enqueue, and malformed/traversal generation names are refused | pass | `s4-superseded-generation-cannot-publish-or-enqueue.log` |
| s5 | A clean result stays silent: no wake row, no supervision obligation, still readable on demand | pass | `s5-clean-result-stays-silent.log` |
| s6 | A finding printed inline by the session-start harvest does not also wake; its delivered generation counts as settled | pass | `s6-inline-harvest-suppresses-wake.log` |
| s7 | A session-start claimant that dies before printing cannot lose the finding: the dead claim is reaped, one wake lands, and it is acknowledgable | pass | `s7-dead-claimant-still-wakes.log` |
| s8 | Adversarial: with a real process holding the publication lock, the watcher's recovery attempts are bounded (~4.7s each, under the 5s cap), the watcher does not wedge, and one wake lands after release | pass | `s8-watcher-retries-bounded-under-contention.log` |
| s10 | Adversarial: a torn completion (report without a status boundary) or a symlinked result directory is refused for read, recovery and supervision | pass | `s10-torn-completion-is-refused.log` |
| s9 | Structural rebase check: `git range-diff` matches all four commits (two identical, two differing only in main-context), the added/removed line sets are identical, both conflict sides are kept, and the base equals `origin/main` | pass | `s9-rebase-equivalence.log` |

Targeted automated regression suites (not a substitute for the live drives
above; run because they already drive this surface end to end):

- `t1-fm-startup-network-test-suite.log` — `tests/fm-startup-network.test.sh`, all assertions passed
- `t2-fm-wake-queue-test-suite.log` — `tests/fm-wake-queue.test.sh`, 86 assertions passed, including the new startup receipt cases and the kept `test_branch_grant_requires_lock_acquisition`
- `t3-fm-turnend-guard-test-suite.log` — `tests/fm-turnend-guard.test.sh`
- `t4-fm-claude-stop-autoarm-test-suite.log` — `tests/fm-claude-stop-autoarm.test.sh`
- `t5-fm-cursor-primary-test-suite.log` — `tests/fm-cursor-primary.test.sh`
