# Orca terminal-keyed stale wake — live validation

Change under test: `.pi/extensions/lib/fm-branch-dispatch.ts` now indexes a task
record's `terminal=` endpoint (the handle `bin/fm-watch.sh` keys an Orca task's
stale rows by, via `fm_backend_target_of_meta`) next to its `window=` alias, so a
terminal-keyed stale row resolves to its task instead of failing the whole wake
closed to main.

Everything below ran against one disposable lab `FM_HOME`
(`bin/fm-lab-home.sh create`), never the operator's fleet home. Every product
surface is a real firstmate entrypoint: `bin/fm-watch.sh` (producer),
`bin/fm-wake-lib.sh` `fm_wake_append` (durable wake writer),
`bin/fm-branch-dispatch.mjs scope|offer` (dispatch decision),
`bin/fm-wake-grant.sh` + `bin/fm-wake-drain.sh` (claim/consume),
`bin/fm-branch-report.sh` (report scoping), and the real Pi SDK
(`@earendil-works/pi-coding-agent` 0.99.1) loading
`.pi/extensions/fm-branch-supervision.ts` + `fm-primary-pi-watch.ts`.
Only the external Orca app is stood in for by a stub `orca` CLI on `PATH`.

| file | scenario |
| --- | --- |
| `orca-terminal-stale-watcher-producer.sh/.log` | the real watcher queues an Orca stale row keyed by the terminal handle; the branch then claims it; the pre-fix module vetoes the same queue to main |
| `orca-terminal-stale-postfix.log` | routine scan, `offer`, heartbeat scan, unknown-terminal, open-decision, window-alias regression, branch grant+drain |
| `orca-terminal-stale-branch-drain.sh/.log` | branch actor drains and acknowledges the terminal-keyed row: the durable queue ends up empty |
| `orca-terminal-stale-prefix-control.sh/.log` | same fixture against base commit 549e07f: `status=unsafe corrupted=1`, `eligible=0` |
| `orca-terminal-stale-pi-branch-live.sh/.log` | real Pi SDK + real extensions: the branch accepts the terminal-keyed wake (`offerEligible/offerAccepted=true`, project scoped); pre-fix declines it |
| `orca-terminal-stale-report-scope.sh/.log` | after the claim, `fm-branch-report.sh --task orca-task` is recorded; another task stays refused |
| `orca-terminal-stale-alias-edge-cases.log` | both aliases of one record resolve; a record with `terminal=` but no `project=` fails closed; a `terminal_backup=` key is not mistaken for a handle |
| `orca-terminal-stale-decision-cross-reference.log` | an unread decision row on the same Orca task keeps the terminal-keyed trigger on main; another task's decision does not |

## Key result lines

Watcher producer (real `bin/fm-watch.sh`, Orca endpoint, second cycle):

```
stale: term-lab-orca-1
1790846134	3	stale	term-lab-orca-1	stale: term-lab-orca-1
post-fix scope:  status=safe  rows=1 2 3  tasks=orca-task
pre-fix scope:   status=unsafe corrupted=1 rows= tasks=
```

Pi supervision branch (real Pi SDK 0.99.1), one Orca stale wake keyed by
`term-live-orca-1`:

```
post-fix: {"offerEligible":true,"offerAccepted":true,"offerProjects":["orca-probe"],"mainGotWake":true}
pre-fix:  {"offerEligible":false,"offerAccepted":false,"offerProjects":[],"mainGotWake":true}
```

Branch consume (grant + branch-actor drain + ack): the unread queue after the
ack is empty — the branch consumed the terminal-keyed row, so main never sees it.
