# Live evidence: Sol session ceiling (`config/sol-cap`) on branch `fm/sol61-ceiling-enforcement`

Everything below was driven against the real product in one disposable environment and torn down in the same turn.

## Environment (disposable, built for this run)

```sh
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")      # /tmp/fm-lab.7eK180
bin/fm-lab-home.sh create "$LAB"                      # marked lab home: state/ data/ config/ projects/
mkdir -p "$LAB/tmux"                                  # private tmux socket dir (TMUX_TMPDIR)
# a throwaway project served by the spawn's real git/treehouse path
git init -b main "$LAB/project"; ... git init --bare "$LAB/origin.git"; git push origin main   # origin HEAD -> refs/heads/main
HOME=$LAB/fakehome                                    # keeps the treehouse pool out of the operator's ~/.treehouse
printf 'tmux\n'  > "$LAB/config/backend"              # real tmux session provider
printf 'codex\n' > "$LAB/config/crew-harness"
# real briefs from the shipped scaffolder, then the two dispatch subsections filled:
FM_HOME=$LAB bin/fm-brief.sh <id> demo --mode no-mistakes
# real backlog row: tasks-axi add <id> ... --file $LAB/data/backlog.md (markdown backend)
```

The dispatches run the **real** `bin/fm-spawn.sh` from the run worktree, inside a real tmux pane on the lab's private
socket, so `$TMUX` is authentic and the endpoint the spawn creates is a real tmux window. Workers are launched by the
product's documented raw-launch-command harness (`--harness 'sleep 900'`), so the ceiling decision, the registry, the
task record, the treehouse worktree and the tmux endpoint are all the real ones while no LLM session is consumed.

```
LAB=/tmp/fm-lab.7eK180
TMUX_TMPDIR=$LAB/tmux    # every tmux call below is -L fm-lab on that private socket; the default server is never touched
```

## 1. Under the ceiling: the dispatch is admitted and its slot is claimed

`config/sol-cap` = `max=2` / `models=gpt-6.1-sol`, empty registry, dispatch `solUnder`.

```
spawned solUnder harness=sleep kind=ship mode=no-mistakes yolo=off window=primary:fm-solUnder worktree=/home/art/.treehouse/project-441974/1/project
SPAWN_RC=0

$ cat $LAB/state/sol-sessions.tsv
solUnder	gpt-6.1-sol	1793429734	2388615
$ ps -o pid,args -p 2388615
    PID COMMAND
2388615 sleep 900                      # the reservation was transferred to the worker's own process
```

A real task record (`state/solUnder.meta`) and a real tmux window were published (`logs/endpoint-and-record.txt`).

## 2. At the ceiling: refused before anything is created, naming sessions and ages

`config/sol-cap` = `max=1`, `solUnder` live, dispatch `solOver`.

```
error: Sol ceiling reached: 1 concurrent capped session(s) already active and this ceiling is 1 (declared in config/sol-cap); the dispatch of task solOver (sleep, gpt-6.1-sol) was refused. Active sessions: solUnder (gpt-6.1-sol, age 21s). A session frees its slot when its worker's process ends; the dispatch contract refuses at the ceiling instead of queueing
SPAWN_RC=1

$ tmux list-windows  (diffed before/after)      -> no new worker window
$ git -C $LAB/project worktree list (diffed)    -> no worktree created
$ ls $LAB/state/solOver.meta                    -> (absent)
$ cat $LAB/state/sol-sessions.tsv               -> only the solUnder row
```

## 3. A non-Sol model dispatches while Sol capacity is full

`max=1`, `solUnder` live, dispatch `solGlm` with `--model gpt-5.6-luna`.

```
spawned solGlm harness=sleep kind=ship mode=no-mistakes yolo=off window=primary:fm-solGlm worktree=/home/art/.treehouse/project-441974/2/project
SPAWN_RC=0
$ cat $LAB/state/sol-sessions.tsv        -> solUnder only (no claim for solGlm)
$ grep '^model=' $LAB/state/solGlm.meta  -> model=gpt-5.6-luna
```

## 4. Stale occupancy does not consume capacity

4a. The live worker's process ends (its pane stays open, as a finished worker's does), then a fresh capped dispatch runs:

```
$ kill 2388615 ; ps -p 2388615 -> worker process ended
spawned solDone ... SPAWN_RC=0
$ cat $LAB/state/sol-sessions.tsv
solUnder	gpt-6.1-sol	1793429734	2388615      # dead row: kept as stop evidence, not counted
solDone 	gpt-6.1-sol	1793429799	2566883
```

4b. A registry row naming an id with no task record and a genuinely dead pid is pruned by the next passing spawn:

```
$ cat $LAB/state/sol-sessions.tsv        (before)
solUnder	...	2388615
solDone 	...	2566883
ghost   	...	2581016        # deadpid from an exited shell; no state/ghost.meta
spawned solGhost ... SPAWN_RC=0
$ cat $LAB/state/sol-sessions.tsv        (after: ghost gone, solGhost claimed)
```

## 5. An adopted pre-existing capped worker is charged exactly once

`state/legacyMate.meta` names a capped secondmate (`model=gpt-6.1-sol`) with **no** registry row and a live tmux
endpoint; `max=2`. Dispatch `solLegacy`:

```
spawned solLegacy ... SPAWN_RC=0
$ cat $LAB/state/sol-sessions.tsv
... legacyMate	gpt-6.1-sol	1793429837	-2      # adopted once, as an uncertain claim
... solLegacy 	gpt-6.1-sol	1793429837	2631804
```

Then one more capped dispatch at the same ceiling:

```
error: Sol ceiling reached: 2 concurrent capped session(s) already active and this ceiling is 2 ... Active sessions: solLegacy (gpt-6.1-sol, age 13s); legacyMate (gpt-6.1-sol, age 0s). ...
SPAWN_RC=1   (no solNext record)
```

The adopted worker occupies **one** of the two slots; a double charge would have refused `solLegacy` itself.

## 6. Local Firstmate homes share one ceiling

A second local home registered in `data/secondmates.md` (`home: $LAB/mate2`) declares `max=1` and holds the machine's
only live capped row; the root home declares `max=1` too and has an empty registry. Dispatch `solShared`:

```
error: Sol ceiling reached: 1 concurrent capped session(s) already active and this ceiling is 1 (declared in config/sol-cap); the dispatch of task solShared (sleep, gpt-6.1-sol) was refused. Active sessions: crewmate (gpt-6.1-sol, age 1s) in /tmp/fm-lab.7eK180/mate2/state. ...
SPAWN_RC=1   (no solShared record)
```

## 7. A home that never declared a ceiling dispatches exactly as before

`config/sol-cap` removed, no registry file, dispatch `solPlain` pinned to the capped-looking model `gpt-6.1-sol`:

```
spawned solPlain harness=sleep kind=ship mode=no-mistakes yolo=off window=primary:fm-solPlain worktree=...
SPAWN_RC=0
$ ls $LAB/state/sol-sessions.tsv   -> (no sol registry was created)
$ bin/fm-sol-cap-lib.sh status $LAB/config  -> inert
```

## 8. Declaration inspection and malformed declarations

`logs/cli-declaration.txt` (declared, lowered ceiling, pattern form, inert) and `logs/cli-malformed.txt`
(`ceiling` above `max`, unknown key, no model named, non-integer `max`) show the shipped CLI naming the file and the
problem with rc=1 and no fallback ceiling. A dispatch on a malformed declaration is refused even for a model the
declaration would not have covered:

```
error: Sol ceiling unavailable: /tmp/fm-lab.7eK180/config/sol-cap must declare ceiling as an integer from 1 through 1, not '5'; task solNext with model gpt-5.6-luna was not dispatched rather than launched against an undeclared ceiling
SPAWN_RC=1   (no solNext record, no new window)
```

## 9. Host-side refusal proof (newest commit, host half only)

`logs/host-side-refusal-proof.txt`: `bin/fm-remote-secondmate-control.sh relaunch` prints
`relaunch_refused_before_control=crewmate` on exits that occur before the `fm-control` call (invalid effort, and the
endpoint-record check), which is the proof the parent consumes. The parent half (release of a reservation the switch
created) needs a real remote route and is reported untested.

## Targeted regression suites run alongside

```
bash tests/fm-remote-secondmate-relaunch.test.sh   -> ALL TESTS PASSED (incl. "only a confirmed pre-control refusal releases the reservation a switch created")
bash tests/fm-sol-cap.test.sh                      -> rc=0 (ceiling, adoption, supersede, reconcile, malformed registry/declaration cases)
```
