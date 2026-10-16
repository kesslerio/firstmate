Live validation scope

- `live-admission.log`: real guard CLI/library, locking, filesystem registries, and process-lifetime wrapper. Payloads were disposable sleep processes, not authenticated Sol model sessions. The admission implementation itself was never replaced.
- `live-spawn-refusal.log`: actual fm-spawn command on a marked lab home and private tmux socket, with four conservative pid-zero delivery rows. No fake backend executable was used. Refusal created no task metadata, launch brief, or terminal window.
- `lab-primary.txt`: real Claude primary launched in a 120x40 private tmux terminal; stopped at workspace trust. No trust response, credential mutation, or global configuration edit was performed.
- `live-local-recovery.log`: real tmux inventory and real reconciliation under the task lifecycle lock. Confirmed agent-free shell releases; missing endpoint without stored socket identity retains occupancy.
- `live-zellij-close.log`: real Zellij 0.44.0 obtained into disposable workspace. Wrong-identity refusal, successful owned closure, fresh absence inventory, and absent-endpoint retry. Headless backend session reported a nonzero 50x50 display. No fake Zellij binary or protocol was used.
- Named Herdr lab provision/status/teardown completed through fm-herdr-lab.sh; default-session tripwire passed. This establishes lab availability, not remote-worker lifecycle correctness.

Supplemental regression tests used fixture backends and are not live lifecycle evidence. Initial relaunch-test attempts exposed absent /bin/sleep, read-only cleanup directories, missing regression config directory, and the product's rejection of secondmate fixtures under its own source root. Test-only portability/setup corrections were applied; final broader relaunch run uses ephemeral /tmp fixtures.

Remaining coverage limits

- Full remote recovery/runtime-switch delivery requires the documented fixed fm-remote session. The gate authorizes Herdr only through fm-herdr-lab.sh with named fm-lab-* sessions; no production remote home or fleet session was used.
- cmux and Orca require macOS GUI applications; this host is Linux. Local Zellij provided an additional real close path but cannot validate those protocols.
- No UI/copy/layout change is present; CLI transcripts are the product evidence. No screenshots were captured.

Final regression result: fm-sol-cap.test.sh, fm-remote-secondmate-relaunch.test.sh, fm-backend-close.test.sh, and the complete focused fm-control-relaunch.test.sh file passed. The corrected model-clearing regression also passed separately with a valid Sol dispatch table.

Additional live boundary: live-remote-switch-refusal.log drives the real parent runtime-switch executable with four conservative claims. It refuses before remote delivery and preserves the existing GLM metadata. This does not establish successful remote launch/recovery or reverse-switch release.

Cleanup completed: disposable payload processes exited; private tmux and Zellij sessions stopped; Herdr lab teardown passed its default-session tripwire; transient workspace fixtures, downloaded Zellij binary and archive, and temporary selector runner removed. Only intentional test-file changes remain.
