# Live validation: durable secondmate home protection + payload clearing on slot return

Change under test: `fix/6921-durable-home-worktree-lock` (HEAD 0eb61557b).

## Fixture (all disposable, removed in the same evidence turn)

- `LAB=/tmp/fm-lab.CY8K6e` — marked disposable firstmate home minted with
  `bin/fm-lab-home.sh create`, so the gate-refuse boundary permits lifecycle
  calls against it. Private tmux socket dir from `bin/fm-lab-home.sh tmux-dir`
  (never the default tmux server).
- `LAB/firstmate-root` — real `git clone` of the run worktree at the target
  commit; the code root the product ran from. `treehouse.toml` pointed
  `root` at a throwaway pool, so real `treehouse` v2.0.1 maintained the pool.
- `/tmp/fm-pool.gDphVb` — the real treehouse pool (one slot, real
  `treehouse-state.json`).
- `LAB/homes -> /tmp/fm-homes.yEoErj` — unpooled linked worktree home for the
  unlock-failure scenario.
- Real `tmux -L fm-lab` session `firstmate` with real windows `fm-mate`,
  `fm-next`, `fm-third`, `fm-spacer`; retirement ran inside `fm-firstmate`, so
  the product's own `kill-window` really closed the mate's window.

## Scenarios driven

1. `scenario1-protection.txt` — seeded home (real `fm-home-seed.sh` into a real
   `treehouse get --lease` slot) is git-locked with the mate's ownership
   receipt; with **zero live processes** on the home, `git worktree remove
   --force` refuses ("cannot remove a locked working tree") and `git worktree
   prune` skips it. Payload intact.
2. `scenario2-retirement.txt` — real `bin/fm-teardown.sh mate --force` from the
   code root: returns the lease, removes the home's window, and leaves the pool
   slot `available` with `data state config projects .fm-secondmate-home
   .fm-secondmate-parent` **absent**; the owned lock and receipt are gone and
   the parent record/registry entry are removed. No staging left in
   `state/`.
3. `scenario3-next-seed.txt` — the next real `fm-home-seed.sh next -` leased
   **the same slot path** (the previously retired home) and published a fresh
   identity `next`, fresh charter, and its own owned lock. The old failure mode
   ("already marked for mate") does not occur.
4. `scenario4-foreign-lock.txt` — a foreign session replaced the worktree lock
   reason; `fm-teardown.sh next --force` refused
   (`REFUSED: foreign Git worktree lock`), leaving the home, payload, lease,
   lock, record, registry entry, and tmux window untouched. After the owned
   reason was restored the same forced retirement succeeded and cleared the
   payload.
5. `scenario5-interrupted-retry.txt` — a retirement was SIGKILLed while
   `treehouse return` was blocked (hanging wrapper reproducing an interruption
   after staging, before the return succeeded): the home was stripped and the
   payload staged in `state/.home-return.*`, lease still held. Re-running the
   real `fm-teardown.sh third --force` printed
   `warning: recovering the interrupted return ...` and completed the
   retirement: payload gone, slot `available`, staging finalized, lock clean,
   records removed.
6. `scenario6-failed-unlock.txt` — an unpooled linked home (worktree of another
   repo, seeded by the product) with a real `state/procevent` registration and
   a real `git worktree unlock` failure (read-only worktree gitdir): forced
   retirement refused, preserved the home, its payload, its owned lock and
   receipt, its parent record, and **restored the wiped registration file
   byte-for-byte**. A retry after clearing the obstacle completed the removal.
   The `TEARDOWN_RC=4` rearm error in that transcript comes from the synthetic
   `adapter=lavish` registration (lavish is not installed here: `reconcile`
   reports `failed=1`); the registration file itself was restored and the
   recovery backup path was reported as designed.

Cleanup: lab home, private tmux socket dir, treehouse pool, and the unpooled
home root were removed with `rm -rf` after `tmux -L fm-lab kill-server`; the run
worktree is clean (`git status --porcelain` empty).
