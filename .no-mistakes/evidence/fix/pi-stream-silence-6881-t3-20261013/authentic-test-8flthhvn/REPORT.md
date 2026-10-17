# Current Test FIX receipt

Tested authentic head `2c1a7e0c5a1f70b190607353b744f1e2c382ce7e` plus the intentional uncommitted test-only identity-forwarding fix.
The later human decision permits selective authentic assigned Git reads and corrects the earlier execution-proof prerequisite; it does not approve, skip, or waive Test.
All older synthetic-Git/writable-source/dropped-marker enclosure passes remain INVALID/INCONCLUSIVE acceptance evidence and are preserved unchanged.

The test SDK invocation cleared gate/managed identity through `env -i`.
`identity-red.log` reproduces the old invocation's failed equality check.
The fix forwards only identity-related exported variables into the otherwise empty SDK environment.
`sdk.log` records equality for all three actual SDK subprocesses and a passing real Pi1.2.0 guard.
No product runtime code changed.

The final launcher is `python3 launch.py <mode>` from the canonical assigned worktree.
It uses unprivileged user/mount/PID/proc/network/IPC namespaces, authentic readonly source and selective backing Git metadata at original paths, a disposable account home, private temp/device/terminal resources, loopback-only networking, closed inherited descriptors, chroot, zero capability sets and no-new-privileges.
Preflight proves authentic source pointer/index/head/common-dir/history and inherited-marker equality, denies source/index writes, protected paths (including both installation-id aliases), remount/unmask attempts and external network access, and permits owned loopback.
Only assigned source, required authentic Git metadata, installed Pi package, system toolchain and this evidence directory are bound into the enclosure.
Initial `/dev/null` setup failure was fixed by making the private device directory non-sticky; raw failure evidence remains in `sdk-setup-failure.log`.
No protected contents were read for preflight.

Commands inside the launcher:

- `live`: `timeout -k 5s 120s bash bin/fm-test-run.sh --json /out/sdk.json tests/fm-pi-worker-stream-live-e2e.test.sh` — exit0, 23803ms test, gate_skip=false.
- `focused`: `FM_WATCH_TRIAGE_CASES='test_pi_stream_silence_uses_inspection_timer test_pi_model_progress_and_legacy_fallback test_pi_stream_publication_lock_revalidation test_pi_stream_uninterrupted_publication' timeout -k 5s 300s bash bin/fm-test-run.sh --jobs 1 --json /out/focused.json tests/fm-busy-state.test.sh tests/fm-busy-adapter-wiring.test.sh tests/fm-watch-triage.test.sh` — exit0, three subjects, 216624ms total, no skips.
- `cli`: `PREP=1 timeout -k 5s 90s bash /cli.sh` — exit0, actual installed Pi1.2.0 CLI with loopback SSE and private tmux.
- `cli-races`: six `timeout -k 5s 45s bash /cli.sh` calls with owned `LOCK_KIND=queue|recovery`, `RACE=close|progress|replace` — all exit0.
- `cli-fallback`: two `timeout -k 5s 45s bash /cli.sh` calls with `OFF=1`, `BOUND=0|invalid` — both exit0.

See `result.json` for all eight scenario dispositions and accurate live-versus-deterministic distinctions.
The genuine signed Pi executable is absent and remains explicitly UNTESTED; no installation or substitution occurred.
All nine sampled owned processes have stopped; private namespace resources disappeared on exit.
Original head, index and `.git` pointer hashes are unchanged; only the intended test source edit remains, with no generated artifacts in the working tree.
No caller or other worktree files were accessed or changed.
The outer executor owns independent review of the new test edit and all subsequent phases; no final approval or publication is implied.
