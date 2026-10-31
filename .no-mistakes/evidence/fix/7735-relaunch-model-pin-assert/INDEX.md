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
