# Orca send-recovery: live validation against a real Orca runtime

## Environment (all disposable, torn down in the same turn)

- Isolated Orca server: `ORCA_USER_DATA_PATH=/tmp/fmolive.2401840/orca orca serve --port 6799 --no-pairing --json`
  reported `state=ready`, `runtimeId=6b259ae9-...`, version `1.4.232`, terminal daemon `pty-spawn` self-test healthy.
  The operator's own Orca runtime on port 6768 was never used.
- Marked disposable lab home: `bin/fm-lab-home.sh create $LAB/home` (gate-permitted lifecycle).
- Disposable repo/workspaces created by Orca itself: `orca repo add --path $LAB/repo`, `orca worktree create --name liveN --setup skip`.
- Worker stand-in: a small node TUI in each terminal that renders the fleet's bordered agent composer
  (`╭─╮ │ > text │ ╰─╯`), buffers typed input, and on Enter appends the submitted line to `submitted.log`.
  Before it was trusted, the real classifier was run on its captured pane:
  `fm_backend_orca_composer_state <handle>` -> `empty`; with text in the box -> `pending`;
  the dialog rendering -> `Claude background-task exit picker`.
  The worker stands in for the receiving agent harness only; `fm-send.sh`, `bin/backends/orca.sh`,
  `bin/fm-composer-lib.sh`, `bin/fm-task-inbox-lib.sh`, `bin/fm-watch.sh` and the Orca runtime/terminals are real.

## Scenario results

### 1. Typed slash command across a real terminal restart (window resolution)
Real Orca errors observed for a killed handle: `{"ok":false,"error":{"code":"terminal_not_writable"}}`
and for an unknown handle `terminal_handle_stale` - both inside the change's stale classification.

```
$ orca terminal close --terminal <recorded handle>      # restart
$ orca terminal create --worktree name:live1 ...        # replacement handle, same window
$ FM_HOME=$LAB/home fm-send.sh live1 '/status'
rc=0
$ cat submitted.log
/status
$ sha256sum state/live1.meta   # unchanged before/after
```
The stale recorded id was resolved through `window=` (one usable pane in a non-truncated list),
the literal was typed once into the replacement and Enter submitted there. Metadata was not rewritten.

### 2. Inbox steer across the same restart
```
$ FM_HOME=$LAB/home fm-send.sh live2 'please check the build'
rc=0
fm-send: doorbell skipped (composer visibly holds pending text); the steer is durably recorded at
  state/live2.inbox/001.msg and the watcher will re-ring
$ cat submitted.log
: Firstmate instruction waiting: list "$FM_TASK_INBOX"/*.msg in your 'live2.inbox' steering inbox,
  read and act on each in numeric order, then mv each into its handled/.
```
The doorbell text reached the replacement pane and was submitted once; the ring is reported deferred
(orca replacement Enter) while the durable record remains.

### 3. Watcher retry policy: retained for a retargeted Orca ring, spent on a healthy endpoint
```
# 3a: fire-and-forget record, pane holds the own doorbell, stale recorded handle
$ FM_TASK_INBOX_GRACE_SECS=0 . bin/fm-watch.sh; inbox_steer_check <stale handle> live3
check-rc=0   retry-mark=retained   submitted.log += doorbell line
# 3b: same state on the live recorded endpoint
$ FM_TASK_INBOX_GRACE_SECS=0 . bin/fm-watch.sh; inbox_steer_check <live handle> live4
check-rc=0   retry-mark=cleared    submitted.log += doorbell line (exactly once)
```
The retry ring delivered in both cases; the mark was kept for the Orca retarget and spent on the
original endpoint, matching `bin/fm-task-inbox-lib.sh`'s policy.

### 4. Typed slash command lost during restart -> unconfirmed, exit 3
The worker requested a real restart the instant the literal was fully accepted (`/status`), while
`fm-send` was inside its 1.2 s slash settle; the replacement terminal was created before Enter.
```
$ FM_HOME=$LAB/home fm-send.sh live10 '/status'
rc=3
fm-send: submission to term_0565b467-... is unconfirmed because Enter changed terminal endpoints;
  do not retype or blindly resend - inspect the replacement pane for the recorded worktree in
  Orca's UI before deciding whether to resend
$ cat -A submitted.log
$        # only the single endpoint-changing Enter (empty composer); no "/status"
```
No retype into the replacement (pane capture contains no `/status`), no further Enter attempts,
metadata unchanged.

### 5. Adversarial: unsafe replacements are refused, never typed into
- Replacement holding a foreign draft: `inbox_steer_check <stale> live3` -> `retry-mark=retained`,
  `submitted.log` empty, the draft was left intact.
- Replacement showing the Claude background-task exit picker:
  typed plane -> `error: blocked on a prompt: Claude background-task exit picker`, exit 1;
  inbox plane -> `fm-send: doorbell did not reach <stale>; the steer is durably recorded ...`;
  the dialog pane received no input at all (`dialog-received.log` absent).
- Stale handle with no live replacement (`terminal list name:live12` -> 0 terminals):
  `fm-send: doorbell did not reach ...; the steer is durably recorded`, nothing typed anywhere.
- Stale handle with two live replacements (`truncated: false`, both connected/writable):
  resolution refused, nothing typed into either pane.

### 6. Healthy endpoint keeps the existing submit budget
A worker that swallows the first Enter:
```
$ FM_HOME=$LAB/home fm-send.sh live15 '/status'
rc=0
$ cat submitted.log
/status          # typed once, submitted once, after the product's Enter retry
```

### 7. CI shard weight hints are consumed by the real planner
```
$ bin/fm-test-run.sh --check-coverage
FM_TEST_COVERAGE ok total=319 parallel=26 parallel_max_ms=814249 parallel_imbalance_ms=552
  parallel_unhinted=0 serial=277 serial_shards=11 serial_unhinted=36 serial_max_ms=1149814
  serial_budget_ms=1200000 herdr=16
$ bin/fm-test-run.sh --list-scheduled --lane portable-serial-8of11 | head -4
tests/fm-watch-wedge-cap.test.sh          # 374225 ms hint
tests/fm-spawn-dispatch-profile.test.sh
tests/fm-secondmate-busy-contract-live-e2e.test.sh
tests/fm-backend-orca.test.sh             # scheduled 4th, consistent with its 73062 ms hint outranking the 45000 ms default
$ bin/fm-test-run.sh --list-scheduled --lane portable-serial-6of11 | grep orca
tests/fm-orca-submit-restart.test.sh
$ bin/fm-test-run.sh --list-scheduled --lane portable-serial-7of11 | grep orca
tests/fm-orca-typed-restart.test.sh
```
