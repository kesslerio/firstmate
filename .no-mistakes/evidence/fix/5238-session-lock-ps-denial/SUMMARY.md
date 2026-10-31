# Test evidence - fix/5238 session-lock ps-denial (head 3b3a9e65)

Change under validation: `3b3a9e65 fix(session-lock): parse /proc stat fields as
stat_fields so rex.sh lints clean` on top of the PR head `6e26ecbf`.

The author's intent is narrow and is what this run tests:

1. the maintainer's `full-ci` **Lint 2** failure must be fixed at its source -
   ShellCheck's source-following made the new `/proc` stat parser's array local
   `fields` clash with `bin/backends/rex.sh`'s own string `fields`
   (SC2178/SC2128), failing that lane on `6e26ecbf` while main's lane passes;
2. **lock behavior must not change**;
3. the PR body must keep its `Closes #5238` line;
4. the corrected head must reach the fork so the maintainer's lanes rerun
   (owned by the outer executor's push/CI phases, not performed here).

Hardware/OS: Linux (NixOS) x86_64, ShellCheck 0.11.0 - the version
`bin/fm-lint.sh` pins (`REQUIRED_SHELLCHECK=0.11.0`).

## The reported failure, reproduced and fixed (`lint-repro.txt`)

`Lint 2` in `.github/workflows/ci.yml` is matrix partition 2, i.e.
`bin/fm-lint.sh --partition 2of2`. A control tree was made by copying the
worktree and restoring only `bin/fm-session-lock-lib.sh` from `6e26ecbf`
(the pre-fix head), so the two trees differ only in this commit.

| invocation | pre-fix lib (`6e26ecbf`) | head (`3b3a9e65`) |
| --- | --- | --- |
| `shellcheck --norc --external-sources bin/backends/rex.sh` | rc=1, SC2178 + SC2128 at rex.sh:1337-1355 | rc=0 |
| `bin/fm-lint.sh bin/backends/rex.sh` (source-following) | rc=1, same diagnostics | rc=0 |
| `bin/fm-lint.sh --partition 2of2` (the CI lane) | - | rc=0, 281 roots, `bin/backends/rex.sh reason=ok rc=0` |
| `bin/fm-lint.sh bin/fm-session-lock-lib.sh` | - | rc=0 |
| `bin/fm-lint.sh bin/fm-lock.sh` | - | rc=0 |

`bin/backends/rex.sh` was not modified by this branch
(`git diff bb3e690..HEAD -- bin/backends/rex.sh` is empty) and still emits its
OSC 7501 record (`rex-status-sequence.txt`). The rename matches the repo's other
`/proc` readers: `bin/fm-remote-job-lib.sh:980` and `bin/fm-teardown.sh:2333`
also use `local -a stat_fields`, and no file uses `stat_fields` as a string.

## Lock behavior unchanged

* `stat-triple-head.txt` vs `stat-triple-prefix.txt`: the real
  `fm_linux_stat_triple` parser (the only function this commit touches) driven
  over 12 `/proc` stat-line cases - comm with spaces, an embedded `)`, valid
  UTF-8 (`José`), collapsed runs of spaces, missing ppid, non-numeric ppid,
  no `(...)` at all - produces byte-identical output on both trees (empty diff).
* `live-matrix-head.txt` vs `live-matrix-prefix.txt`: the real
  `bin/fm-lock.sh` was driven from harness-shaped sessions (a `claude`-named
  executable as the session parent) in disposable marked lab homes
  (`bin/fm-lab-home.sh create`) under a **genuine ps exec denial**
  (`unshare -r -m` + `mount --bind /dev/null "$(command -v ps)"`, `ps -V`
  rc=126). Both trees give the same verdicts (`live-matrix-parity.diff` is
  empty):
  * S1 session A acquires: rc=0, `.lock`=A, `status` = `lock: held by live
    harness pid A`;
  * S2 a second live session is refused: rc=1
    `error: another live firstmate session holds the lock (pid A);
    operate read-only until resolved`, `.lock` unchanged, A still alive;
  * S3 A exits, its stale record stays, the next session reclaims:
    rc=0, `.lock` rewritten to the new harness pid.

## Focused suites (targeted, on this head)

| log | suite | result |
| --- | --- | --- |
| `test-ps-denied.log` | `tests/fm-session-lock-ps-denied.test.sh` | ALL PASS (24 cases, incl. the blocked-ps real-process-tree e2e, the Unicode/live-Cursor verdict case, and route equivalence) |
| `test-windows-consumers.log` | `tests/fm-session-lock-windows-consumers.test.sh` | rc=0 |
| `test-inbox.log` | `tests/fm-inbox.test.sh` | rc=0 |
| `test-ancestry.log` | `tests/fm-session-lock-ancestry.test.sh` | 21 ok, 1 known pre-existing failure: `the pty-host was not reparented to init after the daemon ended`. The same assertion exists on the base commit (`git show bb3e690:tests/fm-session-lock-ancestry.test.sh` line 1135) and asserts the host reparents orphans to pid 1, which this host does not; already reported in earlier rounds, unrelated to this commit. |

## Not performed here

The push of the corrected head to the fork and the maintainer's CI rerun are the
outer executor's push/CI phases; at the time of this run the fork branch and PR
head still pointed at `6e26ecbf`. The PR body was read (not modified) and still
opens with `Closes #5238`.

## Cleanup

The control tree, scratch dirs and lab homes were removed; the worktree is
clean (`git status --short` empty).
