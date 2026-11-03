# Orca send recovery: live validation at fa83b640

## Environment (all disposable, torn down in the same evidence turn)

- Isolated Orca runtime: `HOME=<lab>/fakehome ORCA_USER_DATA_PATH=<lab>/orca orca serve --port 6799 --no-pairing --json`
  reported `state=ready`, `reachable=true`, runtimeId `79b8d66d-...`, version `1.4.232`, terminal daemon
  `state=live` with `selfTest{coverage:"pty-spawn", verdict:"healthy"}`.
  The operator's own Orca runtime on port 6768 was never used, and no Orca repo/worktree was created in
  the operator's `~/orca/workspaces` (the lab's `HOME` redirects Orca's workspace root into the lab).
- Marked disposable fleet home: `bin/fm-lab-home.sh create <lab>/home` plus
  `touch <lab>/home/config/wait-no-turns` for the retry-ring policy.
- Disposable repo and endpoints created by Orca itself: `orca repo add --path <lab>/repo`,
  `orca worktree create --name <w> --setup skip`, `orca terminal create --worktree name:<w> --command ...`.
- Worker stand-in: a small node TUI in each terminal that renders the fleet's bordered agent composer
  (`╭─╮ │ > text │ ╰─╯`), buffers typed input, and on Enter appends the submitted line to a per-endpoint log.
  Before it was trusted, the real classifier (`bin/backends/orca.sh`'s `fm_backend_orca_composer_state`)
  was run against its live pane: idle -> `empty`, with text -> `pending`, and the dialog rendering ->
  `Claude background-task exit picker`. The worker stands in for the *receiving agent* only;
  `fm-send.sh`, `bin/backends/orca.sh`, `bin/fm-composer-lib.sh`, `bin/fm-task-inbox-lib.sh`,
  `bin/fm-watch.sh` and the Orca runtime/terminals are real.

## Scenario results (head fa83b640)

### 1. Typed send to a stale recorded handle reaches the replacement through window=
```
recorded-stale-handle=terminal=term_34817b9a-...      (closed)
live-terminals=term_1d6f3586-...                      (single usable pane, same window)
$ FM_HOME=... fm-send.sh typedA '/status'
exit=0
$ cat typedA.submitted
/status
enters=1   input=[/status]   meta-unchanged=yes
```
The stale id was resolved read-only through `window=`, the literal was typed once and submitted once on the
replacement, and the meta file's checksum was unchanged.

### 2. Inbox steer across the same restart
```
$ FM_HOME=... fm-send.sh typedB 'please check the build'
exit=0
fm-send: doorbell skipped (composer visibly holds pending text); the steer is durably recorded at
  .../state/typedB.inbox/001.msg and the watcher will re-ring
submitted=[: Firstmate instruction waiting: list "$FM_TASK_INBOX"/*.msg in your 'typedB.inbox' steering
  inbox, read and act on each in numeric order, then mv each into their handled/.]
record=.../state/typedB.inbox/001.msg      meta-unchanged=yes
```
The ring is reported deferred (Orca replacement Enter) while the durable record remains.

### 3. Watcher retry mark: retained for a retargeted Orca ring, spent on a healthy endpoint
```
recorded-stale-handle=term_6c78b147-...   live-replacement-handle=term_4fa9d38c-...
stale-due=retry .../typedB.inbox/002.msg
stale-mark=002.msg                         # retained after the deferred replacement ring
healthy-mark=<absent>                      # spent after the ring on the original endpoint
submitted (both)=[: Firstmate instruction waiting: ...]
```
The retry ring delivered in both cases; only the Orca retarget kept its mark, so the deferred ring is
retried rather than spent.

### 4. Typed slash command lost during a restart inside the settle window
The replacement was pre-warmed, the literal was accepted on the original handle, and the recorded terminal
was then closed inside the product's 1.2 s slash settle (`close-ms=995`).
```
$ FM_HOME=... fm-send.sh typedE '/status'
exit=3
fm-send: submission to term_bf18efea-... is unconfirmed because Enter changed terminal endpoints;
  do not retype or blindly resend - inspect the replacement pane for the recorded worktree in Orca's UI
  before deciding whether to resend
original-submitted=[]   replacement-submitted=[]   replacement-input=[]
replacement-enters=1    original-enters=0
```
Exactly the one endpoint-changing Enter reached the replacement; no retype, no further Enter, nothing
submitted, meta unchanged.

### 5. Adversarial refusals around the replacement endpoint
- Replacement holding a foreign draft (inbox plane): `doorbell skipped ... durably recorded ... the watcher
  will re-ring`, exit 0, `pane-input=[]`, nothing submitted, and the live pane still shows
  `│ > my half-typed draft, keep me │`.
- Replacement showing the Claude background-task exit picker (typed plane):
  `error: blocked on a prompt: Claude background-task exit picker` / `error: text not sent ...`, exit 1,
  zero input and zero Enters reached the dialog pane, which still renders only the picker.
- Stale handle with no live replacement: typed plane `error: text not sent ...`, exit 1;
  inbox plane `doorbell did not reach ...; the steer is durably recorded ... , exit 0` with `001.msg` present.
- Stale handle with two live replacements (both connected/writable, `truncated:false`): resolution refused,
  `error: text not sent ...`, exit 1, nothing typed into either pane.

### 6. Healthy endpoint keeps its existing submit budget
A worker that swallows the first Enter:
```
$ FM_HOME=... fm-send.sh typedG '/status'
exit=0
submitted=[/status]   enters=2   input=[/status]   meta-unchanged=yes
```
Typed once, the lost first Enter retried once, delivered once.

### 7. Enter retargeted to a replacement whose dialog guard refuses it
Literal accepted on the original, terminal replaced during the settle with a pane showing the exit picker:
```
recorded-live-handle=term_139bd2e8-...   prewarmed-replacement=term_4bdb4871-...
literal-accepted-on-original=/status    close-ms=1085
exit=3
error: blocked on a prompt: Claude background-task exit picker
fm-send: submission to term_139bd2e8-... is unconfirmed because Enter changed terminal endpoints;
  do not retype or blindly resend - inspect the replacement pane for the recorded worktree in Orca's UI
  before deciding whether to resend
original-submitted=[]   replacement-submitted=[]   replacement-input=[]
replacement-enters=0    original-enters=0
```
The resolved replacement is preserved on the refusal, guidance points at Orca's UI rather than the stale
`fm-peek.sh` handle, and no input or further Enter is attempted.

### 8. Literal retargeted, then Enter never clears the replacement composer
```
$ FM_HOME=... fm-send.sh typedH '/status'      # recorded handle stale, replacement is a shell that queues
exit=3
fm-send: submission to term_8e786c44-... is unconfirmed (verdict=pending-replacement; ...);
  do not retype or blindly resend - inspect the replacement pane for the recorded worktree in Orca's UI ...
submitted=[]   enters=3   input=[/status]
```
Text typed once, the documented Enter budget spent without retyping, and an Orca-UI recovery instruction.

### 9. Enter fails after the text was already accepted
The literal was accepted, then the recorded terminal was destroyed with no replacement before Enter:
```
$ FM_HOME=... fm-send.sh typedI '/status'
exit=3
fm-send: text delivered to term_bf539ab2-... but submission is unconfirmed (verdict=pending; ...);
  do not retype or blindly resend - verify with fm-peek.sh, then re-send '--key Enter' only if the
  composer still holds the text
input=/status (7 chars, typed once)   submitted=[]
```
Never `error: text not sent`; the caller is warned not to resend blindly.

### 10. Shard weight hints are consumed by the real planner
```
$ bin/fm-test-run.sh --check-coverage
FM_TEST_COVERAGE ok total=319 parallel=26 parallel_max_ms=814249 parallel_imbalance_ms=552
  parallel_unhinted=0 serial=277 serial_shards=11 serial_unhinted=36 serial_max_ms=1149814
  serial_budget_ms=1200000 herdr=16
$ bin/fm-test-run.sh --list-scheduled --lane portable-serial-8of11 | head -5
tests/fm-watch-wedge-cap.test.sh
tests/fm-spawn-dispatch-profile.test.sh
tests/fm-secondmate-busy-contract-live-e2e.test.sh
tests/fm-backend-orca.test.sh
tests/fm-claude-stop-autoarm.test.sh
$ ... --lane portable-serial-6of11 | grep orca   -> tests/fm-orca-submit-restart.test.sh
$ ... --lane portable-serial-7of11 | grep orca   -> tests/fm-orca-typed-restart.test.sh
```
All three Orca suites carry a hint (`serial_unhinted` does not include them) and land in the lanes the
hints predict.

## Behaviour suites run at head

```
$ bin/fm-test-run.sh tests/fm-orca-submit-restart.test.sh tests/fm-orca-typed-restart.test.sh \
    tests/fm-composer-lib.test.sh tests/fm-task-inbox.test.sh tests/fm-send-inbox.test.sh tests/fm-inbox.test.sh
FM_TEST_SUMMARY total=6 failed=0 skipped_gate=0 duration_ms=201908
```
`tests/fm-backend-orca.test.sh` also passed (71 assertions) in the first targeted run.

One expectation in `tests/fm-orca-submit-restart.test.sh` was stale against the head behaviour and was
updated in this step: `before-enter/failure` now expects the deferred ring status (1) instead of
`send-failed` (2), because the head change preserves the resolved replacement identity, so a failed Enter
on a replacement is an unconfirmed deferral ("Any inbox Enter on a replacement leaves the ring deferred",
docs/orca-backend.md) and not a proven non-delivery. Every other case in that suite is unchanged and the
suite passes.
