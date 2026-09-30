# Watcher live validation

Target: `9057ad72f84be95ade65a438bead5190f490ed6b`.
Base watcher: `a774c44869dd35b6ca406ec291912e699973109c`.

The production watcher ran against a real Claude Code terminal on a private `fm-lab` tmux socket. Each scenario used a fresh marked lab home inside the gate worktree. No prompt or model work was submitted. Persisted status logs, observed pane hashes, and elapsed wedge timers model a watcher restarted after its first stale alert. Poll and recheck intervals were shortened; aged declarations used a 2,000-second status timestamp. No backend or crew-state stubs were used in these live scenarios.

The base watcher was executed from a disposable copy of the current helper graph, with `fm-watch.sh` replaced by the exact base version. Its newest Holding note emitted:

```
stale: primary:fm-lane (idle 601s, possible wedge, escalation 1)
```

| Status input / scenario | Observed product result |
| --- | --- |
| holding (round 1) | No wake after multiple stale scans; escalation count 0. [2026-09-29T17:24:16-0700] absorbed non-terminal stale (declared hold explains the quiet, idle 2s): primary:fm-lane |
| on-hold (round 1) | No wake after multiple stale scans; escalation count 0. [2026-09-29T17:24:22-0700] absorbed non-terminal stale (declared hold explains the quiet, idle 2s): primary:fm-lane |
| waiting-on (round 1) | No wake after multiple stale scans; escalation count 0. [2026-09-29T17:24:27-0700] absorbed non-terminal stale (declared hold explains the quiet, idle 1s): primary:fm-lane |
| waiting-for (round 1) | No wake after multiple stale scans; escalation count 0. [2026-09-29T17:24:31-0700] absorbed non-terminal stale (declared hold explains the quiet, idle 1s): primary:fm-lane |
| awaiting (round 1) | No wake after multiple stale scans; escalation count 0. [2026-09-29T17:24:41-0700] absorbed non-terminal stale (declared hold explains the quiet, idle 2s): primary:fm-lane |
| standing-by (round 1) | No wake after multiple stale scans; escalation count 0. [2026-09-29T17:24:49-0700] absorbed non-terminal stale (declared hold explains the quiet, idle 2s): primary:fm-lane |
| blocked (round 1) | No wake after multiple stale scans; escalation count 0. [2026-09-29T17:24:56-0700] absorbed stale (overridden terminal status) (declared blocker explains the quiet, idle 2s): primary:fm-lane |
| decision (round 1) | No wake after multiple stale scans; escalation count 0. [2026-09-29T17:25:02-0700] absorbed stale (overridden terminal status) (declared decision explains the quiet, idle 2s): primary:fm-lane |
| hold-aged (round 1) | stale: primary:fm-lane (idle 601s, waiting 2002s - declared hold, holding per its own newest working: line, rechecked on a long cadence not a wedge; confirm what it is holding for; a holding lane should write paused: or needs-decision:) |
| blocked-aged (round 1) | stale: primary:fm-lane (idle 601s, waiting 2001s - declared blocker, awaiting firstmate - its blocker was already reported, rechecked on a long cadence not a wedge; clear the reported blocker and resolve it with fm-send --resolve-key) |
| decision-aged (round 1) | stale: primary:fm-lane (idle 601s, waiting 2001s - declared decision, awaiting firstmate - its decision was already reported, rechecked on a long cadence not a wedge; answer the reported decision with fm-send --resolve-key) |
| active (round 1) | stale: primary:fm-lane (idle 601s, possible wedge, escalation 1) |
| active (round 2) | stale: primary:fm-lane (idle 600s, possible wedge, escalation 2) |
| active (round 3) | stale: primary:fm-lane (idle 601s, possible wedge, escalation 3, demand-deep-inspection: same pane has wedge-escalated 3 times in a row - do not re-absorb on the run-step/pane state alone) |
| not-a-phrase (round 1) | stale: primary:fm-lane (idle 601s, possible wedge, escalation 1) |
| metadata-after-colon (round 1) | stale: primary:fm-lane (idle 601s, possible wedge, escalation 1) |
| metadata-before-colon (round 1) | stale: primary:fm-lane (idle 602s, possible wedge, escalation 1) |
| identifier-underscore (round 1) | stale: primary:fm-lane (idle 602s, possible wedge, escalation 1) |
| identifier-digit (round 1) | stale: primary:fm-lane (idle 601s, possible wedge, escalation 1) |
| superseded-hold (round 1) | stale: primary:fm-lane (idle 601s, possible wedge, escalation 1) |
| superseded-blocker (round 1) | stale: primary:fm-lane (idle 601s, possible wedge, escalation 1) |
| resolved-decision (round 1) | stale: primary:fm-lane (idle 602s, possible wedge, escalation 1) |

## Deleted-home timing

With a real twelve-second watcher poll, deleting its isolated state directory left the watcher alive at ten seconds. It exited after 11.94 seconds, within the current forty-second test budget. The arm correctly reported an ended cycle with no actionable wake.

```
watcher: started pid=20410 (beacon fresh)
watcher: exiting - state directory no longer exists: /Users/kesslerio/.no-mistakes/worktrees/8036f35f7c08/01M3QTPEXZQCR13W9QA1PV6M34/.live-watch/slow-poll-home/state
watcher: FAILED - watcher cycle exited 1 without an actionable reason
```

The generated worker brief is preserved as `generated-brief.md`. Detailed persisted wake queue, triage, escalation counter and elapsed-time readbacks are in `live-watcher-results.json`. The repeatable drivers are `drive-watcher.py` and `drive-slow-poll.py`. Lab servers and homes were torn down after verification.

## Fixed vocabulary guard

- override-cannot-add: stale: primary:fm-lane (idle 601s, possible wedge, escalation 1)
- override-cannot-remove: No wake after multiple scans; declared hold retained despite a nonmatching environment override.

## Targeted automated checks

`bash tests/fm-watch-arm.test.sh` and `bash tests/fm-watch-triage.test.sh` both completed with exit status 0. Their full transcripts are `watch-arm.log` and `watch-triage.log`. The disposable lab directories were removed, private tmux servers were stopped through their lab socket, and no watcher or helper process from this worktree remained. No permanent source or test files changed. Publication and remote CI are outside this assigned test phase.
