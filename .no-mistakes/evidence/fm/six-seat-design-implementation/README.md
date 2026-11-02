# Live validation evidence: opt-in fleet seat pools

Every driver here drives the real product against disposable lab fixtures; only
ssh itself is replaced (FM_SSH_BIN local-exec shim) so the "remote host" is a
lab home on this machine.  Each driver tears its lab down in the same run.

| Driver | Scenario | Fixture |
| --- | --- | --- |
| live-seats-capacity.sh | primary + local + nested secondmate share one capacity; refusal at capacity; pre-existing agent counted | marked lab homes, real holder processes |
| live-fleet-serve.sh | pre-pool remote supervisor counted exactly once through the real serve pass | real fm-on -> fm-remote-entrypoint -> remote job worker |
| live-cert-generation.sh | certificate-proved generation admitted; unissued claimed generation fails closed | real serve + root admission |
| live-lab-session.sh | lab-session predecessor resolve + relaunch; receipt for a supervisor running on another model | bin/fm-herdr-lab.sh session, real Claude agent, real seed/relaunch/reconcile |
| live-retirement-retry.sh | failed secondmate-home retirement retryable after the fix (with pre-fix negative control) | real bin/fm-home-seed.sh home, real bin/fm-teardown.sh |

Logs in this directory are the verbatim driver output from the run that produced
them.
