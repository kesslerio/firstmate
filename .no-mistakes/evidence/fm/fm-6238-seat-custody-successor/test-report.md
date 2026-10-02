# Seat custody product verification

Target: `764dd3fb8dc291c2a6f73a3df78d6c4bccc29af9`.

The real host-control and fleet-seat CLI entrypoints preserved prior operation evidence after early launch and relaunch refusals. Disposable lab homes and synthetic receipt data were used; no endpoint provider was simulated in these direct checks, and no agent startup or remote Herdr lifecycle is claimed.

| Action | Observed target behavior | Evidence |
| --- | --- | --- |
| Retry launch and relaunch with invalid home or blocked directory preparation, retaining received, dispatched, started, prelaunch, dead-after-start, or cancelled receipt | Receipt bytes, metadata and control journal unchanged; token-bound unknown; parent generation reserved and capacity still unavailable | live-custody.log |
| Refuse a genuinely fresh operation | Candidate released; predecessor retained without any incarnation change | live-cli-bounds.log |
| Replay a settled same-token refusal | Original disposition replayed; receipt and immutable reservation bytes unchanged | live-custody.log |
| Retry with missing, foreign or duplicate-field evidence | Unknown, no receipt reopening, immutable reservation unchanged, parent still counted | live-custody.log |
| Hold verified owner's real writer at an instrumented copy barrier and attempt early retries or unrelated/stale carrier writes | Retry and unauthorized writes leave original bytes intact; original owner publishes dispatched route after release | live-custody.log; live-dispatched-receipt.txt |
| Attempt launch and relaunch while lifecycle mutex is held | Unknown, parent remains reserved | live-custody.log |
| Use a verified descendant writer and attempt submitted-to-prelaunch downgrade | Descendant can publish started; prelaunch downgrade refused | live-custody.log |
| Fill a six-seat pool, then retry the pending operation with an invalid home | Original pending generation remains reserved; seventh holder refused with 6 of 6 seats held | live-six-seat.log |
| Trace actual early refusals for each verb and failure type | No tmux, Herdr, harness, spawn or control executable invoked | exec-launch-home.log; exec-launch-directories.log; exec-relaunch-home.log; exec-relaunch-directories.log |

Exact complete executable files from original head `5333e1bc2a211fea55db51d85611feb088ee8cee` reproduced the defect for both verbs: dispatched became prelaunch and the parent generation was released. Those are expected pre-fix failures, not failures of the target. See live-cli-bounds.log.

The targeted remote secondmate relaunch suite passed unchanged. The control relaunch suite first failed because its temporary homes were placed inside the repository; the standard temp-directory rerun then failed because this NixOS host has no /bin/sleep. A disposable copy replacing only those seven absolute sleep paths with the existing /run/current-system/sw/bin/sleep passed in full. Native, unmodified control-suite success is not claimed. Logs and timing files retain all three attempts. No production or permanent test files were modified.

No UI changes are present, so screenshot QA is not applicable. All disposable homes, old-head executable copies, barrier instrumentation and temporary test files were removed. No broad suite, linter, formatter, pipeline-control, push or PR operation was run.
