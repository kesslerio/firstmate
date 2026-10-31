# Live validation: pinned-model assertion (bin/fm-spawn.sh)

All runs happened in this gate worktree (`fix/7735-relaunch-model-pin-assert`,
target 9047798e) with real harness binaries: `claude 2.1.314 (Claude Code)`,
`pi 1.4.0`, `herdr` and `tmux` from PATH.

## Live end-to-end launcher runs (real Claude, disposable fm-live-lab lab)

    bin/fm-live-lab.sh up --harness claude --worker --model haiku --effort low \
      --supervision-host off --expect-host no --timeout 420

Then three further real `bin/fm-spawn.sh` worker launches inside the same lab
home (same root, so `fm-live-lab.sh down` owns their Claude trust entries):

    lab FM_HOME=<lab> FM_MODEL_PIN_POLLS=120 bin/fm-spawn.sh <id> <lab>/projects/notes \
      --mode local-only --yolo on --harness claude --model 'sonnet[1m]' --effort low
    lab FM_HOME=<lab> FM_MODEL_PIN_POLLS=24  bin/fm-spawn.sh <id> <lab>/projects/notes \
      --mode local-only --yolo on --harness claude --model 'claude-does-not-exist-9' --effort low
    lab FM_HOME=<lab> FM_MODEL_PIN_POLLS=6   bin/fm-spawn.sh <id> <lab>/projects/notes \
      --mode local-only --yolo on --harness claude

Teardown in the same turn: `bin/fm-live-lab.sh down <lab>` (removed the lab tmux
server, task temp dirs, the lab's two Claude project entries, and the lab root).

| artifact | shows |
| --- | --- |
| `live-pin-verdicts.txt` | the four `state/<id>.status` pin notes a real launcher wrote against real Claude transcripts: `asserted` (pin `sonnet` → `claude-sonnet-5-5`), `mismatch` (pin `sonnet[1m]` → `claude-sonnet-5-5`), `unverified` (pin `claude-does-not-exist-9`, no model ran), and an unpinned launch with no `--session-id` and no pin note |
| `live-worker-pane.txt` | the gated crewmate's pane: real `Claude Code v2.1.314 / Sonnet 5.5 with low effort`, its turn, and the pause line it wrote |
| `live-decorated-pin-pane.txt` | the mismatching (`sonnet[1m]`) worker really ran a turn on the same claude binary |
| `live-spawn-decorated-pin.log` | the mismatch warning on stderr plus `spawned ... harness=claude` (spawn still exit 0) |
| `live-spawn-invalid-pin.log` | `spawned ... harness=claude` for a pin that never ran a model (unverified, not a failure) |
| `live-spawn-unpinned.log` | an unpinned launch still spawns |
| `live-lab-claude-worker.log` | lab bring-up: the worker spawn line, `ok worker: ... parked on <gate>`, readiness checks |
| `live-lab-down.log` | teardown: lab removed, lab Claude store entries removed |

## Real-vendor facts the assertion reads

    FM_MODEL_PIN_READBACK_LIVE=1 bin/fm-test-run.sh tests/fm-model-pin-readback-live-e2e.test.sh

| artifact | shows |
| --- | --- |
| `model-pin-readback-live.log` | pi 1.4.0 resumed onto another model reports the pinned model on its own turn while the inherited turn keeps the old one; claude 2.1.314 reported `claude-haiku-4-5-20251001` for a pin of `claude-haiku-4-5` at the session id the launch addressed |
| `pi-error-record-live.txt` | a real pi resumed session whose request was rejected persists an assistant record naming the *requested* model with `stopReason: "error"` — the record class the launcher must not count as evidence |

## Repository checks (targeted)

    bin/fm-test-run.sh tests/fm-control-relaunch.test.sh          # full file, pass
    bin/fm-test-run.sh tests/fm-control-herdr-smoke.test.sh       # real herdr, pass
    bin/fm-test-run.sh tests/fm-model-pin-readback-live-e2e.test.sh  # opt-in live guard, pass
    bin/fm-test-run.sh tests/zz-transient-model-pin-focus.test.sh # transient trim: the five Claude pin tests only, pass
    bin/fm-test-run.sh --list --changed --base 095db3bc

`spawn-dispatch-profile.log` is the whole-file attempt: it aborts on the
pre-existing `test_launch_environment_allowlist` case, which forces
`PATH=/usr/bin:/bin` and therefore cannot find `sed` on this NixOS host, so
`bin/fm-git-strip-ai-trailers.sh` (unchanged by this change) returns no
`hooksPath`. That test is untouched by this change; the five pin tests were run
through the temporary trimmed copy, which was deleted afterwards.

---

# Round at target 456ffd6e (recreated Pi sessions, selected live-guard pair)

Every run below was made in this gate worktree at target
`456ffd6ed70af05095235e18a51bf5a8090e189e` with the host's existing logins:
`pi 1.4.0`, `claude 2.1.316 (Claude Code)`.

## Live vendor + real launcher: a registered Pi session that does not exist yet

`live-drive-scratch.log` — a temporary driver (deleted after the run) built from
`tests/fm-control-relaunch.test.sh`'s own fixture helpers, run against real
`bin/fm-spawn.sh --relaunch --harness pi`. Its last case registers an absolute
session path that is absent, then starts a real `pi 1.4.0` process on that exact
path (`--session <path> --model openai-codex/gpt-5.6-sol`) while the launcher is
polling. The launcher kept the registered path on the launch line, waited for the
vendor to create the file, and recorded
`model pin asserted: pin 'openai-codex/gpt-5.6-sol' actual 'openai-codex/gpt-5.6-sol'`
from the real turn it read. The same log shows the two boundaries: an absolute
path that never appears ends `unverified` after the bounded probe (launch exit 0),
and a reference neither present nor resolvable through the Pi session root ends
`unverified` with the launch intact.

`prefix-revert-control.log` — the same driver with only the five-line
`spawn_pi_session_file` hunk reverted: the recreated-session case reports
`model pin unverified: pin 'anthropic/claude-opus-5-5' has no session record ...`
and fails, so the new behavior is what the case measures.

## Live opt-in guard (real models, selected pair)

`FM_MODEL_PIN_READBACK_LIVE=1 bin/fm-test-run.sh tests/fm-model-pin-readback-live-e2e.test.sh`

| artifact | shows |
| --- | --- |
| `live-model-pin-readback-guard.log` | pi 1.4.0 ran a first turn on `openai-codex/gpt-5.6-luna` and resumed the same record on `openai-codex/gpt-5.6-sol`: the inherited turn keeps luna, the resumed turn reports sol. claude 2.1.316 reported `claude-haiku-4-5-20251001` for a launch pinned to `claude-haiku-4-5` at its own `--session-id` transcript. |
| `live-guard-bad-start-model.log` | `FM_MODEL_PIN_READBACK_PI_MODEL=openai-codex/no-such-model` fails directly: `pi 1.4.0 could not start on '...'; select an available model with FM_MODEL_PIN_READBACK_PI_MODEL` |
| `live-guard-bad-resume-model.log` | `FM_MODEL_PIN_READBACK_PI_RESUME_MODEL=openai-codex/no-such-resume-model` fails directly naming the resume variable |
| `live-guard-same-model-pair.log` | identical start and resume models are refused before any run, naming both variables |

## Targeted repository checks

    bin/fm-test-run.sh tests/fm-control-relaunch.test.sh             # 95 cases, pass
    bin/fm-test-run.sh tests/fm-secondmate-restart.test.sh           # pass
    bin/fm-test-run.sh tests/fm-remote-secondmate-relaunch.test.sh   # pass
    bin/fm-test-run.sh tests/fm-remote-secondmate-trace-context.test.sh # pass
    bin/fm-test-run.sh tests/fm-wake-queue.test.sh                   # pass
    FM_TEST_BASE_PATH="$PATH" bin/fm-test-run.sh tests/fm-secondmate-liveness.test.sh  # pass with the host PATH

| artifact | shows |
| --- | --- |
| `control-relaunch.log` | the relaunch suite, including `ok - Pi and pi-signed relaunches read model evidence from recreated sessions` and the completed-response/unverified boundaries |
| `claude-pin-cases.log` | the nine Claude pin cases from `tests/fm-spawn-dispatch-profile.test.sh`, run through a temporary trimmed copy (deleted) so the host's `/usr/bin:/bin` environment case does not abort the file |
| `fm-secondmate-restart.log`, `fm-remote-secondmate-relaunch.log`, `fm-remote-secondmate-trace-context.log`, `fm-wake-queue.log`, `fm-secondmate-liveness.log` | a mismatch/unverified verdict reaches every capturing boundary, including automatic second-mate recovery |

`fm-spawn-dispatch-profile.log` and `fm-backend-t3code.log` are whole-file
attempts that stop on pre-existing, change-independent NixOS limitations: the
allowlist case forces `PATH=/usr/bin:/bin` (no `sed`/`grep` there), and the
installed-Codex T3 case executes `/usr/bin/printenv`, which this host does not
have. Their relevant cases are covered by the logs above.
