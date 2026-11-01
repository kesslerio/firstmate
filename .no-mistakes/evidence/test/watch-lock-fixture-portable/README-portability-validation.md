# watcher-lock fixture portability - live validation

Host under test: NixOS (Linux 7.3.1), `/bin` holds no `ln`, and `sleep`
resolves to `/run/current-system/sw/bin/sleep` -> `.../coreutils-full-9.11/bin/coreutils`,
a multicall binary that dispatches on `argv[0]`
(`bash -c 'exec -a /tmp/holder sleep 2'` -> `coreutils: unknown program 'holder'`, rc=1).
This is the host class the intent names.

| run | command | result |
| --- | --- | --- |
| before (base 41a47c0 fixtures) | `bash tests/fm-watcher-lock.test.sh` in a throwaway copy at base commit | FAIL `not ok - acquirer could not reclaim dead steal owner (rc=8)` -> `exec /bin/ln` (`base-suite.log`) |
| before, `/bin/ln` only patched to an absolute existing path | same, base fixtures otherwise unchanged | FAIL `not ok - could not identify the fixture holder` -> the `exec -a "$dir/holder" sleep 300` holder dies at once on the multicall `sleep` (`base-suite-ln-fixed.log`) |
| after (target fixtures) | `bash bin/fm-test-run.sh tests/fm-watcher-lock.test.sh` | PASS, 58 cases, `exit=0` (`target-suite.log`) |
| after, simulated "only sh in /bin" host | `bwrap --dev-bind / / --ro-bind <bin-with-only-sh> /bin --chdir $PWD bash bin/fm-test-run.sh tests/fm-watcher-lock.test.sh` | FAIL before the `/bin/rm`-in-a-lock-fixture fix (`target-suite-minbin.log`: `not ok - no reaper acquired the dead steal mutex (rc=1)`); PASS after it (`target-suite-minbin-fixed.log`) |
| after + fixture fix, normal host | `bash bin/fm-test-run.sh tests/fm-watcher-lock.test.sh` | PASS, 58 cases, `exit=0` (`target-suite-fixed-host.log`) |

The `/bin/rm` shim in `test_lock_steal_reap_cannot_remove_successor` (a lock
fixture) and the `/bin/ps` shim in `test_unpublishable_identity_exits_through_cleanup`
were the remaining hardcoded `/bin` execs in this suite; both now resolve the host
tool with `command -v` and hand the path to the shim in `FM_TEST_REAL_RM` /
`FM_TEST_REAL_PS`, matching the pattern this change applied to `FM_TEST_REAL_LN`.
Without that, the suite still could not run on the "only sh in /bin" host the intent names.

`host-portability-probe.log` shows the host facts and the replacement holder
(`python3 -c ... "$dir/holder"`) staying alive with the fixture name in its cmdline.
No stray `time.sleep(300)` holders remained after any full-suite run.
