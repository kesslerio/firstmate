# Live Orca restart-delivery validation (head 1f8ddf21)

Setup for every artifact below:

* An **isolated headless Orca 1.4.232 runtime** (`orca serve --port 0 --no-pairing`) with
  `ORCA_USER_DATA` / `ORCA_USER_DATA_PATH` pointed inside a throwaway `mktemp -d` lab, so the
  operator's running Orca service (`orca-serve.service`, ~/.config/orca) was never contacted or mutated.
* Real Orca worktrees and terminals (`orca worktree create`, `orca terminal create/close/send/read`)
  over a throwaway `git init` repo inside the lab; panes ran real `claude` 2.1.316 (the machine's normal
  login, no sign-in) or a plain shell.
* firstmate itself ran from the gate worktree with a **marked lab FM_HOME**
  (`bin/fm-lab-home.sh create <lab>/home`), so `bin/fm-send.sh` / `bin/fm-watch.sh` are the real product.
* A "hand restart" is a real `orca terminal close` of the recorded handle plus `orca terminal create`
  in the same worktree (the window alias `fm-liveN` survives), which makes the recorded handle return
  `error.code=terminal_not_writable`.

| Artifact | What it shows |
| --- | --- |
| `sweep1-typed-stale-to-live-replacement.out`, `sweep1-replacement-pane.txt` | `fm-send.sh live2 /status` with a stale recorded terminal typed the slash command once into the live replacement resolved from `window=`, and real claude executed it (`Settings Status ...` panel). Exit 1 with `verdict=unknown` is the pre-existing composer-read limitation, not a failed send. |
| `sweep2-missing-replacement.out` | Recorded window with no live terminal: `orca send failed`, exit 1, nothing typed anywhere. |
| `sweep3-ambiguous-replacement.out`, `sweep3-ambiguous-live-panes.txt` | Six live panes behind the recorded window: refused, exit 1, no pane received the text. |
| `sweep3b-conflicting-window-alias.out` | Two metas claiming the same stale terminal with different `window=` aliases: refused, exit 1, no guessing. |
| `sweep4-inbox-defer.out`, `sweep4-replacement-pane-after-ring.txt` | Inbox steer to a stale handle: durable record written, replacement gate read the composer as unproven, so no doorbell text and no Enter reached the pane; exit 0 (record is the delivery). |
| `sweep5-endpoint-changed.out`, `sweep5-replacement-pane.txt` | Deterministic restart **between typing and Enter** (`dd` captured the typed bytes on the original endpoint, then the terminal was closed and a new one created inside the 1.2 s settle): `fm-send.sh` exited 3 with the `endpoint-changed` unconfirmed message, retyped nothing, and pressed no further Enter. |
| `sweep5b-double-restart-unresolvable-pending.out`, `sweep5b-replacement-pane.txt` | Harder variant: the second restart leaves no window alias for the intermediate handle, so the Enter retarget cannot resolve at all; `fm-send.sh` still exits 3 (`pending-replacement`) instead of claiming success or retyping. |
| `sweep6-retry-mark.txt`, `sweep6-watcher-triage-log.txt` | `bin/fm-watch.sh` `inbox_steer_check` driven live: a deferred Orca retry ring (`result=1`) keeps `.retry-ring`; a retry whose doorbell reaches the live endpoint (`result=0`) spends it (`due action after: quiet`, mark gone). |
| `sweep7-healthy-original-endpoint.out`, `sweep7-healthy-original-pane.txt` | Control: a healthy recorded handle is not retargeted; `/status` was typed once and Entered in place and real claude executed it (exit 1, `verdict=unknown`, unchanged behaviour). |
| `t-orca-suites.txt` | `bin/fm-test-run.sh tests/fm-backend-orca.test.sh tests/fm-orca-submit-restart.test.sh tests/fm-orca-typed-restart.test.sh` — all green (64179 / 17695 / 7891 ms locally). |
| `t-inbox-suites.txt` | `tests/fm-task-inbox.test.sh`, `tests/fm-watch-inbox-meta.test.sh`, `tests/fm-send-inbox.test.sh` green; `tests/fm-backend.test.sh` fails on a pre-existing, environment-dependent `hc` app-terminal case that reproduces identically at base commit 9224c902. |
| `t-shard-coverage.txt` | `bin/fm-test-run.sh --check-coverage`: `serial_max_ms=1149814` under `serial_budget_ms=1200000` with the refreshed Orca weight hints, 0 unhinted parallel members. |

Teardown: the isolated Orca server, its data root, every Orca worktree/terminal created for these runs,
and the marked lab home were removed at the end of this evidence turn; the operator's Orca runtime,
operator FM_HOME, and git state outside this worktree were left untouched.
