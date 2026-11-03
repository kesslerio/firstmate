# Live validation: startup-network retention pass (fix/5378-startup-network-wake-receipt)

Change under test: `bin/fm-startup-network.sh` (`prune_results`, `cmd_prune`, `report --generation`,
`retain_result`) with `bin/fm-startup-network-lib.sh`, from base `78c69df` to `ded6117`.

Every scenario drove the real product CLI (`bin/fm-startup-network.sh`) against a throwaway
`FM_HOME` created with `mktemp -d`, with the worktree as `FM_ROOT_OVERRIDE`. No operator home,
fleet state, credentials, or default tmux/Herdr session was touched; each lab was removed in the
same run. `s1` injects a 3s delay into the stage's bootstrap child through a throwaway
`root/bin` symlink tree (the same delay-injection shape the owning test suite uses) so the
"start returns while the worker is still running" observation is deterministic. All other
scenarios ran the real `bin/fm-bootstrap.sh`.

| Log | What it shows |
| --- | --- |
| `s1-start-does-not-prune.log` | `start` with 30 settled retentions returns in ~80ms, opens zero per-generation records, leaves all 30 intact, hands the run to the live worker; the worker then prunes to the 3-name window plus its own completion. Start latency with 300 retentions is the same as an empty home (~70-90ms). |
| `s2-bounded-pass.log` | One `prune` of 67 settled generations deletes exactly the 64-entry budget oldest-first (`1000..1063`), a second pass drains to the 3-name look-back, a third is a no-op, and no pass opens a per-generation record. Also shows an unremovable receipt defers the deletion and a later pass retries it. |
| `s3-retention-matrix.log` | Current generation (named older than everything), queued generation, and the newest three names survive; settled, superseded, incomplete, and malformed retired entries are removed with their receipts; a symlinked entry loses only its link; a foreign name is untouched; the queued row is not consumed; `report --generation` reads a kept completion and refuses a pruned one; a symlinked receipt root and a symlinked results root are never followed. |
| `s4-starvation-backlog.log` | 70 newer incomplete completions do not hide 3 older settled ones: pass 1 deletes the old settled generics plus 61 backlog entries oldest-first, pass 2 drains the rest and leaves the 3-name window. |
| `s5-real-run-reservation-prune.log` | Real `start` + real bootstrap: worker finishes `done`, retires 16 of 20 seeded generations down to the bound (keeping a queued generation and its row), retains its own completion, and `report` prints it. `harvest` and `report` alone never scan or prune (30 retentions untouched). |
| `s6-midpass-current-guard.log` | A generation that becomes current *during* the pass (injected via a `sed` shim) is not deleted: the pass re-reads shared status before each remove and keeps 105.1.1 while retiring the rest. |
| `s7-queue-read-once.log` | A pass over 67 entries reads `state/.wake-queue` exactly once, keeps the queued generation, and leaves its row queued. |
| `owning-suite-tap.log` | `bash tests/fm-startup-network.test.sh` - all 35 assertions pass, including the five retention/bounded-pass/starvation cases. |
