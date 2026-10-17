This test phase exercised the integrated worktree with no provider calls, real credentials, fleet access, installs, or global configuration changes.

Isolation: unshare user/mount/network/PID namespaces, chroot containing read-only Nix tools and the installed Pi package, a synthetic home and /tmp, the current source worktree, and this evidence directory. Each invocation first checked that real home/auth/trust/config/runtime paths and other checkouts were absent and that network connections were denied. Synthetic Git metadata avoided exposing the gate's bare repository. The final enclosure indexes bin/ so tracked-command validation uses the real consumer against the disposable repository metadata.

Live evidence: the real Pi 1.2.0 SDK resource loader, runtime, agent loop, generated worker extension, real busy writer, and harmless custom tool ran with synthetic transport. Enabled, disabled, held/empty/substantive response, tool, subsequent-request, settlement, background, and bounded stalled-writer cases passed. The direct busy-writer CLI transcript records actual serialized protocol state and refused closed/stale/retired writes.

Portable evidence: real watcher subprocesses ran against simulated terminal endpoints; these are behavioral integration tests, not live harness supervision. Captured watcher output and durable queue rows show the inspection reason. The matrix covers optional-value/version fallback, default/native progress, declared waits, close/progress/replacement during queue and recovery lock waits, and an uninterrupted watcher with no prior recovery marker.

Test repair: the stalled-writer guard's copied toolkit lacked history and was refused by the publication guard. Three lines initialize disposable fixture history; no product authority was weakened. See live-before-fix.txt and the successful live-pi.log.

Enclosure corrections: device mounts, disposable Git history, and the tracked-command index were repaired before final validation. Editing an early evidence driver while it ran caused a shell parse error after its test runner had exited successfully; later invocations use immutable per-invocation driver copies, and the focused suites and watcher evidence check completed successfully. wake-enclosure-before-fix.log retains the missing-index setup failure.

No graphical UI changed, so evidence is headless CLI/state output. pi-signed is absent and was not substituted. Mode-based unreadability cases in the shared queue tests self-skip under the namespace's root UID; no permission-behavior claim is made for those cases. No linters, formatters, static analysis, full repository suite, publication, or pipeline-control phases were run.

Final shared wake-queue rerun: exit 0, gate_skip=false; the simulated unreachable-remote probe passed after indexing bin/. All enclosure invocations ended and the temporary worktree enclosure was removed. The only remaining source diff is the three-line test-fixture repair.
