# Live validation round 2 - fleet seat pools after the endpoint-refusal fix

All runs are from the gate worktree at HEAD 5703a686. Bases and expectations are
the user intent on branch `fm/six-seat-design-implementation`. Nothing outside a
disposable `/tmp` fixture, a disposable lab home, or this evidence directory was
written.

Round 1's single live failure (an invalid recorded endpoint aborting on an
unbound `REMOTE_ENDPOINT_BACKEND` instead of refusing before launch) is fixed by
5703a686. It is re-driven here, and every adjacent behavior that fix could reach
is re-run.

## Manual live drives (real `bin/` entrypoints, disposable fixtures/labs)

| File | What it shows |
| --- | --- |
| `repro-endpoint-refusal-after-fix.log` | Adversarial rerun of the round-1 failure: the real `bin/fm-remote-secondmate-control.sh` gets a recorded endpoint whose `backend=` record does not validate. It now exits 1 with `remote secondmate ios endpoint metadata is invalid; refusing access until it is explicitly migrated`, keeps the receipt at `phase=prelaunch`, and the primary reads back `disposition=prelaunch` instead of `unknown`, so the candidate seat is released rather than held. |
| `lab-local-pools-after-fix.log` | Disposable lab primary (`bin/fm-lab-home.sh`) with `config/fleet-seats` capacity 2 and a registered local secondmate home. A pre-pool worker record in the mate is counted once (`used=2 capacity=2`), the mate shares the primary's capacity and refuses while naming both holders, a real `bin/fm-spawn.sh` launch is refused with no task record published, and releasing the primary's seat grants the mate's reservation. |
| `lab-session-relaunch-after-fix.log` | A remote secondmate recorded under `remote_herdr_session=fm-lab-relaunch-proof` driven through the real `bin/fm-remote-secondmate-relaunch.sh`: the route lookup carries `--herdr-session fm-lab-relaunch-proof`, resolves the host predecessor (`expect=host-old`), relaunches on that same session, and republishes the parent route with the same session. The SSH boundary is the disposable remote-host fixture. |

## Executable behavior suites (real `bin/` scripts and state, disposable fixtures)

| File | Result |
| --- | --- |
| `remote-secondmate-relaunch-suite-after-fix.log` | `tests/fm-remote-secondmate-relaunch.test.sh` - now ALL TESTS PASSED. The round-1 abort at `fresh refusal remained unknown: refusal.launch.endpoint` is gone, and every case after it runs, including prelaunch-refusal seat accounting, cancelled-before-startup replacement, pooled refusal, and retirement-blocked relaunch. |
| `fleet-seats-suite-after-fix.log` | `tests/fm-fleet-seats.test.sh` - 55 cases pass: shared primary/local/remote capacity, pre-existing-agent counting, observed-generation adoption on another model, certificate-vs-ledger authority, and recon reconciliation. |
| `remote-generation-suite-after-fix.log` | `tests/fm-remote-generation.test.sh` - predecessor resolution and lab-session forwarding. |
| `remote-secondmate-session-suite-after-fix.log` | `tests/fm-remote-secondmate-session.test.sh` - lab-session route/retire APIs and retirement evidence replay. |
| `retirement-retry-cases-after-fix.log` | The four retirement cases of `tests/fm-teardown-endpoint-safety.test.sh` via `FM_TEST_ONLY`, run alone because the full file aborts earlier on a host-specific pre-existing case (round-1 base comparison). |
| `remote-finalization-suite-after-fix.log` | `tests/fm-teardown-remote-finalization.test.sh` - interrupted retirement finalization retry. |
