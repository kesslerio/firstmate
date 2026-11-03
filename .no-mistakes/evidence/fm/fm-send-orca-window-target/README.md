# Live Orca validation evidence - stale-handle send retargeting

Environment: Linux host, Orca CLI/IDE 1.4.232 with a **disposable headless runtime**
(`HOME=/tmp/oc1 orca serve --no-pairing --port 7700`, runtimeId a77bcb2b-e517-405c-b66f-e5e6a4890a83),
a throwaway git repo (`/tmp/fmrepo`) and Orca worktrees (`fm-live-*`) created by the real
`orca worktree create` / `orca terminal create`, driven by the branch's real
`bin/fm-send.sh`, `bin/fm-task-inbox-lib.sh` and `bin/fm-watch.sh` against a marked lab home
(`bin/fm-lab-home.sh create`). The operator's Orca runtime, fleet home and credentials were not used.

`live-agent-stub.py` is the disposable pane occupant only (a box composer that records
submitted lines plus the blocking Claude picker shape). It is not the product under test;
every Orca CLI call, terminal, selector, send, read and firstmate script is the real thing.

Each `s*.log` records the scenario setup (worktree, stale handle, replacement handle),
the real `orca terminal ...` inventory/rejection, `fm-send.sh` exit status, and the pane's
submitted lines/rendered tail after the run.

| file | scenario |
| --- | --- |
| `s1-*.log` | stale recorded `terminal=` resolves the one live pane through `window=` and the typed `/status` lands there; meta bytes unchanged |
| `s2a-*.log` | adversarial: recorded window has no live pane; an unrelated live pane elsewhere is never touched, send fails |
| `s2b-*.log` | adversarial: two live panes in the recorded window are ambiguous; nothing is typed, send fails |
| `s3-before-*.log` | inbox ring to a stale handle: replacement holds a foreign draft, no doorbell text and no Enter |
| `s3-empty-*.log` | inbox ring to a stale handle: empty replacement receives the doorbell once and exactly one Enter, ring deferral message |
| `s45-before-normal-*.log` | hand restart before typing: replacement resolved and `/status` delivered |
| `s45-settle-normal-*.log` | hand restart during the slash settle after the text was typed: exit 3 with Orca-UI replacement-pane guidance, text not retyped, one bare Enter on the replacement |
| `s45-settle-dialog-*.log` | same restart with a blocking picker on the replacement: Enter refused ("blocked on a prompt"), exit 3 with the same guidance |
| `s6-origtyped-*.log` | healthy original handle: typed `/status` delivered, exit 0 |
| `s6-originbox-*.log` | healthy original handle: inbox doorbell with the first Enter swallowed is retried and submitted exactly once |
| `s7-*.log` | text accepted then Enter fails (pane exits): exit 3 "delivered but unconfirmed", never "text not sent" |
| `s8-*.log` | real `bin/fm-watch.sh` poll with a fire-and-forget retry mark on a stale Orca handle: ring deferred (`result=1`) and the retry mark survives |
| `s9-*.log` | adversarial: replacement composer replaced by a foreign draft during the settle; pre-Enter gate refuses, nothing submitted |
| `s10-*.log` | adversarial: replacement composer emptied during the settle; no bare inbox Enter |
