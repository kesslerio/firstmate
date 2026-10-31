# Live validation evidence: pinned-model assertion (#7735)

Change under test: `bin/fm-spawn.sh` reads back the model a pinned launch/relaunch
actually runs on and reports `model pin asserted|mismatch|unverified: ...` on stderr,
plus the relays that forward that line (`bin/fm-remote-secondmate-control.sh`,
`bin/fm-secondmate-liveness-lib.sh`, `bin/fm-secondmate-restart.sh`,
`bin/fm-bootstrap.sh`, `bin/fm-watch.sh`).

Everything below was run from the gate worktree with the machine's existing
`claude` 2.1.316, `pi` 1.4.0, `herdr` 0.9.3 and `tmux`, against disposable
`bin/fm-lab-home.sh` homes on a private tmux socket or a named non-default
`fm-lab-*` Herdr session. The operator's real Claude/Pi credential stores were
only read into the temporary stores; no credential was modified, no default
Herdr session was touched, and every lab was removed in the same turn.

## Live verdicts through the real product

`driver-claude-verdicts.sh` -> `live-model-pin-verdicts.log`

| launch | observed stderr |
| --- | --- |
| `--model claude-haiku-4-5` | `model pin asserted: pin 'claude-haiku-4-5' actual 'claude-haiku-4-5-20251001' (pinned Claude session f5e6a93b-...)` |
| `--model claude-opus-4-1` (vendor remaps it to Opus 5.5) | `model pin mismatch: pin 'claude-opus-4-1' but pinned Claude session 6404c777-... reports 'claude-opus-5-5'`, exit 0, worker still live |
| no `--model` | no model-pin line at all |
| `--model claude-3-opus-latest` (retired, no model runs) | `model pin unverified: pin 'claude-3-opus-latest' was not confirmed by pinned Claude session e7ea99c4-... (no session-reported model)` |

Each real launch also shows `--session-id <uuid>` on the live `claude` process and
the transcript at `<CLAUDE_CONFIG_DIR>/projects/.../<uuid>.jsonl` whose assistant
records name that model — the address and field the assertion reads.

`driver-raw-and-worker-status.sh` -> `live-raw-and-worker-status.log`

| launch | observed |
| --- | --- |
| raw `claude --version && sleep 300` with a pin | `model pin unverified: pin 'claude-haiku-4-5' could not be addressed for this raw Claude launch (no session address exists for this path)` after 2518 ms (no 9.5 s probe), and no `--session-id` on the launch |

No status file in any of the six real launches contained a `model pin` line
(`grep -l 'model pin' state/*.status` -> none), so the verdict never became task
state.

## Vendor surfaces the assertion depends on

`live-readback-guard.log` — the opt-in guard run against the installed harnesses:

```
# pi 1.4.0: inherited turn openai-codex/gpt-5.6-luna, resumed turn openai-codex/gpt-5.6-sol in one record
ok - pi 1.4.0: a resumed session's own turn carries the model it was pinned to, over an inherited record naming another
# claude 2.1.316 (Claude Code) reported claude-haiku-4-5-20251001 for pin claude-haiku-4-5
ok - claude 2.1.316 (Claude Code): a pinned launch reads back the model its own session id addresses
```

## Herdr + Pi

`driver-herdr-pi-resume.sh` -> `live-herdr-pi-resume.log`

A real `--backend herdr --harness pi` secondmate launch on a `fm-lab-*` session
reported `model pin unverified: ... has no session record this launcher can read
back for a fresh pi launch` (correct: a fresh launch addresses no session).
Herdr did publish the pane agent session (`agent_session.kind=path`, source
`herdr:pi`), but `bin/fm-control.sh <id> exit` — the documented pre-relaunch step —
removed the pane's agent record (`agent_not_found`), and a relaunch while the agent
is live is refused by design, so the resume branch could not be reached on this
host. The relaunch correctly degraded to the fresh-launch `unverified` verdict
instead of guessing. See `live-herdr-pi-relaunch.log` for the earlier attempts
(missing `.pi/extensions` in the seeded home, then missing provider auth).

## Targeted suites for the relay and T3 branches

- `portable-pin-suites.log` — `tests/fm-control-relaunch.test.sh` passed through
  every case (Pi resume, recreated session, completed-response rule); the
  unchanged parts of `tests/fm-spawn-dispatch-profile.test.sh` abort on this
  NixOS host at a pre-existing case that runs with `PATH=/usr/bin:/bin`, where
  `sed` does not exist.
- `portable-relay-suites.log` — `tests/fm-secondmate-restart.test.sh`,
  `tests/fm-remote-secondmate-trace-context.test.sh`,
  `tests/fm-remote-secondmate-relaunch.test.sh`, `tests/fm-wake-queue.test.sh`
  passed. `tests/fm-secondmate-liveness.test.sh` aborts at its first case for the
  same host reason (`bin/backends/tmux.sh: line 440: grep: command not found`).
  `tests/fm-backend-t3code.test.sh` fails only in its pre-existing live guard that
  execs `/usr/bin/printenv`, which NixOS does not have.
- `t3code-pin-suite.log` — with that pre-existing live guard opted out
  (`FM_T3_CODEX_CONFIG_LIVE=0`), the new T3 case passes:
  `ok - T3 Claude pin is immediately unverified without allocating a launcher session id`.
