# Orca restart-channel live checks

Real Orca 1.4.222 ran under a private worktree-local profile and a write sandbox. Real Cursor Agent, Pi, Claude Code, OMP, and OpenCode were attempted; no credentials were copied or changed.

Observed product behavior:

- A human Cursor draft remained intact. `fm-send` reported `doorbell skipped`; its steer was durably recorded as `002.msg`.
- An exact pending own doorbell remained intact, with no duplicate or submission; the real ring interface returned 1.
- A real Cursor `Working` frame received no inbox input; ring returned 1.
- Typed steers, Enter, and C-c reached replacement panes after both real `terminal_handle_stale` and `terminal_not_writable` rejections. Metadata hashes stayed identical.
- Missing and ambiguous native windows refused C-c. Forwarded real CLI logs contain only the rejected original send, with no replacement input.
- Healthy-target base and current adapters emitted identical real CLI commands, stdout, stderr, and exit status.
- A stopped runtime caused a send failure without a window lookup or retry.

Limits: a positive doorbell on a proven-empty replacement composer and Claude's background-work exit picker could not be driven. The current capture interface classified available agent composers as unknown; Pi's current footer and Cursor/OpenCode's plain captures were unrecognized, Claude's headless capture was unreadable, and OMP entered provider setup. Cursor's normal chat persistence also attempted an out-of-worktree write, which the sandbox refused. All unsafe/unknown inbox attempts deferred as intended. A compatible readable real-agent capture or a separately authorized backend compatibility follow-up is needed for the remaining proofs.

The runtime reported `desktopWindowStatus=blocked`; there was no isolated native window to screenshot. Evidence uses real CLI transcripts, native terminal-read responses, persisted inbox state, hashes, and forwarded command records. Shared operator windows were not opened.

Two happy-path test fixtures were corrected to provide an identified empty composer rather than a lone, unidentifiable row. No runtime source code changed.
