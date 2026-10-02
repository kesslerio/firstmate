Live validation used Codex 0.159.2, Pi 1.0.0 and real tmux panes at 160x45. No positional model prompt was submitted. Replay stores and intentional fixture writes stayed inside the gate worktree.

The existing folder-trust guard captures Firstmate launch commands through its fake pane fixture, then replays those flags against the real installed runtimes. The observer delegates every tmux operation to the real binary, captures real pane output, and shortens the socket pathname through the running driver's /proc/<pid>/cwd alias to avoid the Unix socket pathname limit. TMPDIR contained a space. The socket still points into the worktree.

Raw commands were likewise captured through the spawn fixture, then executed in real panes with no positional prompt. This proves final launch arguments and store selection, not an entire real Treehouse spawn or agent task completion. The final raw replay applied isolated HOME and PI_CODING_AGENT_DIR to the whole shell command, including its export preamble. Earlier replay setup was corrected before the final evidence was captured.

Manual boundary checks invoke the original bin/fm-codex-trust.sh executable against disposable Git repositories and read back its real config writes and refusal output. No mock consumer is used for those checks.

Portable checks: fm-codex-trust.test.sh and fm-spawn-dispatch-profile.test.sh. Initial in-tree fixtures were refused because secondmate homes cannot be nested under the code root. A git archive of the target was extracted into .test-validation/product, with fixtures as siblings, preserving the worktree boundary. The dispatch check also needs tracked command metadata; a disposable Git index was initialized for that snapshot before its successful rerun. These portable checks are not counted as live runtime evidence.

Other checks: the real Codex features consumer confirmed hooks=false; the real live guard self-skipped both cases against empty disposable credential stores. The genuine pi-signed wrapper is not on PATH and the repository has no executable/distribution from which to build it; portable launch coverage passed for that identity, but a live signed-wrapper run requires that actual wrapper on PATH.

Visual evidence consists of actual tmux terminal captures displayed as monospaced HTML and rasterized with isolated headless Chromium. Both resulting images were inspected. The first Chromium attempt hit host wallet/display integration and was stopped; the successful isolated invocation disabled the display and session bus and used the basic password store.

Final targeted runs passed. No Herdr/default fleet session was used and no pipeline-control, CI, lint or formatter phase was run.

Cleanup complete: test-owned processes stopped, disposable snapshot and fixtures removed, worktree unchanged.
