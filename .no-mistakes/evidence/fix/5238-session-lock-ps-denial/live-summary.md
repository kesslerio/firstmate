# Live validation — fix/5238-session-lock-ps-denial

Change under test: the session lock decides ownership from one shared verdict
(`fm_session_lock_pid_blocks_reclaim` / `fm_session_lock_pid_verdict`), reads
process identity without the `ps` binary when `ps` cannot execute, and keeps the
invariant that **live or unreadable owners block reclaim while dead, reused,
malformed and zero-valued records stay reclaimable**.

Method: the real public executables (`bin/fm-lock.sh`, `bin/fm-inbox.sh ready`)
were driven against disposable `bin/fm-lab-home.sh` lab homes and real process
trees on a Linux host. The three OS conditions the change targets were
reproduced as the environment, not stubbed inside the product:

- `ps` that cannot execute at all (`ps -V` and every read exit 126), the
  EDR-style denial the issue reports;
- a Cygwin/MSYS-family `ps` (refuses `-o`, serves the fixed columns, reads the
  Windows table with `ps -W`) for the tagged `win:<pid>` owner cases;
- a live pid whose identity the ps route cannot read (a non-leader thread id).

Each session under test is a real bash process named like a harness whose parent
is init, so the ancestry walk sees exactly one session and cannot escape into
the agent running the driver.

Driver: `live-driver.sh`. Full transcript: `live-run.log`. Result: 0 failed
checks across 10 scenarios.

| Scenario | Observable result | Log |
| --- | --- | --- |
| S1 ps-denied acquire | `lock acquired: harness pid N`, `.lock` = session pid | `live-s1-denied-ps-acquire.log` |
| S2 live harness owner, ps denied | exit 1, refusal names pid, lock + sidecar untouched | `live-s2-denied-ps-live-owner-refused.log` |
| S3 live owner with unreadable identity | exit 1, refusal names pid, lock untouched | `live-s3-unreadable-owner-refused.log` |
| S4 dead owner, ps denied | reclaimed, `.lock` rewritten | `live-s4-dead-owner-reclaimed.log` |
| S5 reused live non-harness | reclaimed (both routes) | `live-s5-reused-pid-reclaimed.log` |
| S6 `0` `00` `000` `not-a-pid` `win:` `win:7abc` empty whitespace | all reclaimed | `live-s6-reclaimable-records.log` |
| S7 status + `fm-inbox.sh ready` | `held`/`live_harness=true` for a harness holder on both routes, stale/unknown otherwise | `live-s7-status.log`, `live-s7-inbox-ready.log` |
| S8 route identity verdict parity | same verdict for control-byte argv, empty argv elements, comm with space/paren/newline, non-ASCII name, dead pid | `live-s8-route-parity.log` |
| S8b route decision matrix | identical accept/refuse decision on both routes per owner state | `live-s8b-decision-matrix.log` |
| S9 tagged `win:<pid>` owners | live harness and unreadable table refused, absent/reused/malformed reclaimed | `live-s9-windows-tagged.log` |

Byte rendering: the two identity routes agree on the *verdict* for every live
shape, but they render non-printable bytes differently (valid UTF-8 survives
`ps` and becomes `?` through the `/proc` provider; a newline inside the kernel
`comm` becomes `?` through `ps` and a space through the provider). No harness
match flipped in any live case, including a harness-named executable whose name
carries non-ASCII bytes.
