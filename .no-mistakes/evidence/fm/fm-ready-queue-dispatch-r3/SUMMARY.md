# Ready-queue dispatch re-attestation evidence (gate worktree 01M68DFDPBY58KJMCHPEQ7GB3W)

Head under test: `a7243a22` (branch `fm/fm-ready-queue-dispatch-r3`), base `095db3bc`.

## Deterministic drives of the changed product surface

| Command | Result | Log |
| --- | --- | --- |
| `bash tests/fm-watch-ready-queue.test.sh` | 17/17 ok, `FM_TEST_COMPLETE`, rc 0 | `ready-queue-suite.out` |
| `bash tests/fm-supervision-host-drain.test.sh` | 19/19 ok, `FM_TEST_COMPLETE`, rc 0 | `drain-suite.out` |
| three heartbeat cases from `tests/fm-watch-triage.test.sh` (targeted copy) | 3/3 ok, rc 0 | `triage-heartbeat-cases.out` |
| ready-queue suite with the checkout `.tasks.toml` pointed at an absolute disposable "operator" backlog | 17/17 ok, rc 0, sentinel backlog byte-identical | `isolation-suite.out` |

These drive the real `bin/fm-watch.sh`, `bin/fm-supervise-daemon.sh`, `bin/fm-tasks-axi.sh`
backlog consumer, `bin/fm-wake-drain.sh` and `bin/fm-branch-outcome.sh`. No tmux/engine
or model is involved in these three suites; they are the real CLI path.

## Live model drives (disposable lab homes, machine Claude login, torn down)

| Driver | Scenario | Log |
| --- | --- | --- |
| `drivers/attended-live.sh` | attended heartbeat with one dependency-clear ready unit and one captain-held sibling: real branch prompt + real wake prompt through the real Claude engine; durable non-silent captain handoff recorded, held sibling untouched, no worker, wake acknowledged, and the real `fm-wake-drain.sh` presented `BRANCH OUTCOMES` with the `mark-processed --through` target | `attended-live.out` |
| `drivers/away-live.sh` | away record "No dispatch is authorized." with two out-of-scope ready units: both stayed `queued` with a durable stop note naming the retry condition, no worker meta, and a non-silent captain outcome | `away-live.out` |

Both drivers run `bin/fm-supervision-engine-lib.sh`'s real engine turn (Claude, `sonnet`)
against the generated prompt; stubbed boundaries are: the engine binary is wrapped with
`--no-session-persistence`, and the attended drain's primary-harness detection is pinned
with the documented `FM_TEST_SEAM=1 FM_TEST_HARNESS=claude` seam because the driver shell
is not itself a Claude session.

## Live harness primary (disposable `bin/fm-live-lab.sh` lab with mate, gated worker, supervision host)

- `bin/fm-live-lab.sh up --harness claude --mate --worker --source <lab-local source repo> --ref main`
  stood the lab up; every readiness check reported ok except the helper's own
  `treehouse` check, which reported a new `~/.treehouse/notes-e9ace8` entry the helper
  creates itself (log: `lab-up.out`). That entry was removed during teardown.
- Queued unit `lab-ready-9c1` (ship, repo `notes`, dependency-free, brief scaffolded with
  the real `bin/fm-brief.sh`) and backdated `.last-heartbeat`.
- Result (`live-primary-drive.out`, `live-primary-final-state.txt`):
  - the watcher's heartbeat reached the real supervision host, whose real Claude turn
    recorded a durable, non-silent **captain** handoff (outcome store `seq 3`) naming
    `lab-ready-9c1` within 25 s of the forced heartbeat;
  - the host woke MAIN (`to-main branch-outcome: ... store rows 3`);
  - MAIN ran the real `bin/fm-wake-drain.sh`, read `BRANCH OUTCOMES`, inspected the unit
    with `bin/fm-tasks-axi.sh show`, loaded `harness-adapters`, and attempted
    `bin/fm-spawn.sh`;
  - Claude Code's **auto permission mode denied the launch** ("Create Unsafe Agents",
    `live-primary-main-before-relaunch.txt`), so no worker was started. MAIN reported the
    blocker to the captain and deliberately left the handoff unacknowledged, so the unit
    stayed `queued` and the outcome stayed unprocessed (preservation on resurfacing).
- A relaunch with `--permission-mode bypassPermissions` was attempted to get the worker
  launch live, but it stops at an interactive "Yes, I accept" security warning
  (`live-primary-bypass-consent-gap.txt`). That consent was **not** accepted; the pane was
  killed. Worker startup is therefore the one link in the live chain that this host's
  harness policy blocks.
- Teardown: `bin/fm-live-lab.sh down /tmp/fmlab.8iyeGp` (stopped the lab tmux server and
  processes, removed task temps, 3 Claude project trust entries, and the lab root; the
  lab-created `~/.treehouse/notes-e9ace8` and the lab-local source repo were removed
  manually). The worktree is byte-identical (`git status` clean).

## Scenario ledger

1. Ready queued work escapes heartbeat suppression and reaches the durable wake queue — pass, live.
2. A heartbeat with unreadable backlog readiness escalates instead of being absorbed — pass, live.
3. Empty or captain-held queued work stays quiet — pass, live.
4. Attended supervision hands each ready unit to MAIN as a durable captain outcome before acknowledging — pass, live.
5. Away supervision keeps out-of-scope ready units for MAIN with a durable not-ready reason — pass, live.
6. A real harness primary processes a ready-work handoff end to end — pass, live, with the worker launch blocked by harness permission policy.
7. The drain keeps each pending captain outcome and oversized handoff visible until acknowledged — pass, live.
8. Ready-queue regression fixtures never write an operator backlog configured by the checkout `.tasks.toml` — pass, live.
9. Late supervision-host lifecycle group under non-harness caller ancestry — untested (requires a caller outside the agent's process tree; see report).
