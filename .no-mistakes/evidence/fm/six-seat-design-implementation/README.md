# Live validation evidence - fleet seat pools (fm/six-seat-design-implementation)

All runs are from the gate worktree at HEAD 38d61765 (base a4bf5f86). Nothing
outside a disposable `/tmp` lab, fixture directory, or this evidence directory
was written.

## Manual lab drives (no test harness, real product entrypoints)

| File | What it shows |
| --- | --- |
| `lab-local-pools.log` | Disposable lab primary (`bin/fm-lab-home.sh create`) with `config/fleet-seats` capacity 2 and a registered local secondmate home. A pre-pool worker record in the mate is counted once (`reserved ... used=2 capacity=2`), the secondmate's own reserve sees the primary's holder (shared capacity), a real `bin/fm-spawn.sh` ship launch is refused with the holder list and publishes no task record, and releasing the primary's seat grants the secondmate's launch. |
| `lab-session-relaunch.log` | A remote secondmate recorded under `remote_herdr_session=fm-lab-relaunch-proof` driven through the real `bin/fm-remote-secondmate-relaunch.sh`. The parent calls its route lookup with `--herdr-session fm-lab-relaunch-proof`, resolves the host-recorded predecessor (`expect=host-old`), relaunches on that same session, and republishes the parent route with the same session. SSH here is the disposable remote-host boundary fixture. |
| `repro-endpoint-refusal.log` | Failure repro: a remote launch whose recorded endpoint does not validate should refuse as `prelaunch`. The host controller instead aborts with `line 706: REMOTE_ENDPOINT_BACKEND: unbound variable`, leaves the receipt at `phase=received`, and the primary reads back `disposition=unknown`, so the candidate seat stays counted. |

## Executable suites (real `bin/` scripts and state, disposable fixtures)

| File | Result |
| --- | --- |
| `fleet-seats-suite.log` | `tests/fm-fleet-seats.test.sh` - 55 cases pass, including shared one-capacity across homes, remote adoption of a pre-pool host supervisor, the observing-receipt/model proof, and the certificate-vs-ledger-history exemption. |
| `remote-seat-adoption-suite.log` | `tests/fm-remote-seat-adoption.test.sh` - host-side adoption, receipt and generation fencing. |
| `remote-generation-suite.log` | `tests/fm-remote-generation.test.sh` - predecessor resolution, lab-session forwarding. |
| `remote-secondmate-session-suite.log` | `tests/fm-remote-secondmate-session.test.sh` - lab-session route/retire APIs and lab retirement evidence replay. |
| `remote-secondmate-relaunch-suite.log` | `tests/fm-remote-secondmate-relaunch.test.sh` - FAILS at `fresh refusal remained unknown: refusal.launch.endpoint` (see `repro-endpoint-refusal.log`). Cases after it do not run. |
| `retirement-retry-cases.log` | The four retirement cases of `tests/fm-teardown-endpoint-safety.test.sh`, run alone (the suite aborts earlier on a host-specific case, see below). |
| `remote-finalization-suite.log` | `tests/fm-teardown-remote-finalization.test.sh`. |
| `teardown-endpoint-safety-suite.log` | Full `tests/fm-teardown-endpoint-safety.test.sh`: fails at `teardown reported success after a close that failed`. |
| `teardown-endpoint-safety-base-comparison.log` | The same suite extracted from base `a4bf5f86` fails at the identical case, so that failure is host-specific and predates this change. |
