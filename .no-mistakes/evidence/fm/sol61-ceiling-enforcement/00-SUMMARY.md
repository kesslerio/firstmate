# Live validation: Sol session ceiling (`fm/sol61-ceiling-enforcement`, head 9083b497)

Everything below was driven against the real product in a disposable lab; nothing
was stubbed. The spawn under test is the repository's own `bin/fm-spawn.sh` and
the guard under test is `bin/fm-sol-cap-lib.sh` on this head.

## Lab

- `LAB=$(mktemp -d ...)`; `bin/fm-lab-home.sh create "$LAB/home"` (marked lab home,
  the only home the gate may drive lifecycle against), plus a second capped home and a
  registered local secondmate home for the shared-ceiling check.
- Two private tmux servers on the lab's own socket directory:
  one with `default-shell` bash, one with `default-shell` fish
  (`/nix/store/djgc45v1n9lq05kr5vvg4z03xjj2yqwd-fish-4.2.1/bin/fish`, fish 4.2.1,
  already present in the store; nothing was installed).
- `HOME` pointed inside the lab, so the Treehouse pool, git config and fish config
  all landed in the lab and the operator's `~/.treehouse` was untouched.
- A local-only fixture project with its own bare origin, registered in
  `data/projects.md`, and a scout brief per task.
- `config/sol-cap`: `max=1` + `models=gpt-6.1-sol` (one home also declared
  `model-pattern=^gpt-.*-sol$`), and one home left with no `config/sol-cap` at all.
- Each dispatch is the product's own `bin/fm-spawn.sh <id> <project> --scout
  --harness '<raw launch command>' --model <model>`; the raw command runs a real
  worker (`sleep`) and records its own argv, pid and inherited exports.

The raw launch commands are the point of the run: each contains syntax only one
pane shell accepts.

```
bash pane: /usr/bin/env bash -c '<worker script>' _ "$(cat <(printf %s bash-pane))"   # process substitution: POSIX sh and fish reject it
fish pane: /usr/bin/env bash -c '<worker script>' _ (printf %s fish-pane)              # fish command substitution: a POSIX shell rejects it
```

## Results

| Scenario | Result |
| --- | --- |
| Capped spawn in a bash pane runs a process-substitution launch unchanged; worker starts; registry row moves to the worker pid | pass |
| Capped spawn in a fish pane runs a fish-substitution launch unchanged; worker starts; registry row moves to the launching shell that owns the worker | pass |
| At `max=1` with one live capped session, another capped dispatch is refused before anything is created, naming the session and its age | pass |
| A live session in a registered local secondmate home is counted against the primary's ceiling and is named in the refusal | pass |
| A non-covered model launches while the Sol ceiling is full | pass |
| With no `config/sol-cap` the guard is inert: capped-model dispatches launch, no registry file is written | pass |
| Occupancy releases when the worker's process ends, and the next capped dispatch is admitted | pass |
| Capped vs uncapped produce the identical worker argv, and the launch line's exports reach the worker (the documented child-shell boundary) | pass |

## Detail worth naming

- Bash pane: the reservation pid in `state/sol-sessions.tsv` is the worker's own
  pid (the launch chain execs in place), e.g. `live-bash2 ... 4191929` with
  `4191929 /bin/bash -> sleep 300`.
- Fish pane: fish forks for the command substitution, so the reservation lands on
  the fish shell that runs the launch line (`live-fish2 ... 70716`), which is the
  direct parent of the worker (`70911 sleep 300`). That shell waits for the worker
  and exits with it, which is what "occupancy releases when the worker exits"
  requires; it was verified by killing the worker and watching both pids disappear
  while the interactive pane stayed open.
- The panes keep fish/bash behaviour after the guard is removed from the path: the
  same fish command in a home with no `config/sol-cap` ran with argv `fish-pane`
  and the same bash command ran with argv `bash-pane`, so only admission changed.
- Documented boundary: the run shows the preserved half directly - the launch line
  runs in a child of the sourcing pane shell, under that same pane shell, with the
  line's exports (`FM_TASK_INBOX`, `COMPACT_ADVISER_DISABLE=1`) reaching the worker.
  The unexported half (pane-local variables, functions, aliases) is the consequence
  of exactly that child boundary and was not separately injected into a task pane.

## Files

- `01-capped-launch-bash-pane.txt` - bash-pane spawn output, staged launch line,
  registry row, worker and ancestry, release after the worker exited.
- `02-capped-launch-fish-pane.txt` - the same for the fish pane.
- `03-ceiling-refusal.txt` - same-home refusal (registry before/after, nothing
  created) and the secondmate-home refusal.
- `04-inert-and-non-sol.txt` - guard-inert dispatch, uncapped control, non-covered
  model under a full ceiling, and the worker log with argv/exports.
- `05-release-and-readmit.txt` - admission after the previous worker exited.
- `06-lab-panes.txt` - the lab panes themselves (bash prompt vs fish prompt).
