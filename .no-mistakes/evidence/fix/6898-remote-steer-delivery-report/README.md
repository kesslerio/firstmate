# Live validation: buffered remote stderr keeps `sent:` ahead of remote notices

Change under test: `bin/fm-send.sh` (buffer the remote leg's stderr until its exit
status is known, then print `sent:` before replaying that stderr, and refuse the
send when the buffer cannot be created) plus `bin/fm-remote-secondmate-control.sh`
(report `steer_record=<path>` on stdout and lead each notice line with the durable
record).

## How the product was stood up

* Disposable lab home minted with `bin/fm-lab-home.sh create` (marked gate lab
  home) plus a throwaway remote secondmate home; both under `mktemp -d` and
  removed in the same turn.
* Real parent CLI: `bin/fm-send.sh rsm "<message>"` from this worktree, as an
  operator runs it.
* Real transport: `FM_SSH_BIN` points at a 10-line wrapper that execs the system
  `ssh`, sending the product's own argument vector to **localhost**. The far side
  really ran `bin/fm-remote-entrypoint.sh` (staged job + remote job worker) and
  `bin/fm-remote-secondmate-control.sh`, which wrote a real steering-inbox record
  into the throwaway remote home. No part of the send/delivery logic was stubbed.
* Two lab-only shims keep the run off the operator's machine: a `tmux`/`hc` pair
  that exits 1 in the remote account's `.local/bin` (so the doorbell cannot reach
  a real fleet pane and reports "doorbell did not reach / agent exited", which is
  the notice under test), and `FM_REMOTE_JOB_STATE_ROOT` pointed into the lab so
  the remote job queue never touches `~/.firstmate`.
* Base-commit tree (`git archive 14d06b0`) served over the same ssh hop for the
  mixed-version and before/after comparisons.

## Scenarios driven

| # | Scenario | Result | Artifact |
|---|----------|--------|----------|
| 1 | A delivered remote steer exits 0, prints one `sent:` naming the far-side record, and that record exists with the steer text | pass | `01-sent-confirmation-and-ordering.log` |
| 2 | `sent:` precedes the remote leg's `notice:` line on delivery | pass | `01-...log`, `05-before-after-ordering.log` |
| 3 | A notice that follows the confirmation leads with the durable record, so no delivered line reads as a refusal | pass | `01-...log` |
| 4 | Adversarial: unusable `TMPDIR` (buffer cannot be created) refuses the send before any remote attempt and cleans the reply expectation | pass | `03-buffer-failure-refuses-send.log` |
| 5 | Adversarial: a real far-side failure is relayed verbatim, prints no `sent:`, exits 1, leaves no record and no pending expectation | pass | `02-remote-failure-stderr-relayed.log` |
| 6 | An older remote leg that reports no `steer_record=` still gets a delivered confirmation (unnamed fallback) | pass | `04-old-remote-leg-still-confirms-delivery.log` |
| 7 | Regression oracle: the base parent prints the notice first and no `sent:` for the same delivered steer | pass (fix confirmed) | `05-before-after-ordering.log` |

Targeted suite: `bash tests/fm-send-remote-delivery.test.sh` (all cases passed).
