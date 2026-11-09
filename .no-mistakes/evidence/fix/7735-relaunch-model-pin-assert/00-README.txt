Test evidence for fix/7735-relaunch-model-pin-assert, target commit f3d4cb64a
"fix(tests): compare documented Claude alias/snapshot pairs in both directions"

Files, in the order they were run:

01-selftest.txt
  The guard's documented harness-free entry point:
    FM_MODEL_PIN_READBACK_SELFTEST=1 bash tests/fm-model-pin-readback-live-e2e.test.sh
  exit 0, one ok line, no live opt-in needed.

02-gate-refusal.txt
  Same file with neither FM_MODEL_PIN_READBACK_SELFTEST nor FM_MODEL_PIN_READBACK_LIVE:
  the shared gate still refuses ("skip: live: opt-in; ..."), so the new early-exit
  did not open the live path.

03-selftest-sensitivity-mutants.txt
  The case table is a real oracle, not a vacuous pass. Three copies of a throwaway
  full bin/+tests/ tree: control passes; mutant A (documented alias/snapshot
  normalization removed - the pre-fix comparator the Greptile P2 reports) fails on
  the reverse-direction row; mutant B (eight-digit snapshot-date wildcard made
  bidirectional) fails on the undocumented-reverse-date row.

04-launcher-pin-verdicts.txt
  The real bin/fm-spawn.sh driven in a throwaway full-tree git copy, with
  tests/fm-spawn-dispatch-profile.test.sh's own cases plus a Test-phase case for the
  "never open-ended alias matching" boundary:
  pin=claude-haiku-4-5-20251001 report=claude-haiku-4-5 -> asserted (reverse pair),
  pin=claude-haiku-4-5 report=claude-haiku-4-5-20251001 -> asserted (forward pair),
  undocumented reverse date / other snapshot date / other family -> mismatch.

05-live-gate-suite.txt
  tests/fm-live-gate.test.sh in the worktree: stops on a pre-existing host limitation
  (its run_guard PATH is /usr/bin:/bin, which on this NixOS host has no mkdir/tr).

06-live-gate-base-baseline.txt
  The same suite as it exists at the base commit c8d8fdad, unchanged: identical
  failure, so the limitation is pre-existing and not caused by this change.

07-live-gate-suite-with-new-case.txt
  The target commit's suite in a throwaway tree with that one minimal PATH extended
  by /run/current-system/sw/bin: every case passes, including the new
  "the model-pin readback guard exposes a harness-free comparator selftest".

08-live-guard-e2e.txt   09-live-guard-snapshot-pin.txt
  The opt-in live guard against the real harnesses through bin/fm-test-run.sh:
  pi 1.5.0 resumed gpt-5.6-luna -> gpt-5.6-sol, and claude 2.1.319 read back through
  its own --session-id transcript (pin sonnet -> claude-sonnet-5-5; pin
  claude-haiku-4-5-20251001 -> the same id). The selftest block does not hijack the
  live run.

10-selftest-without-harness-path.txt
  The harness-free entry point with pi and claude shadowed by tripwire shims: the
  shims never run, so the selftest needs no vendor.
