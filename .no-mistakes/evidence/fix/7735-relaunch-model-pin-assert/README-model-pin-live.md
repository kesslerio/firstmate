# Live validation: pinned-model assertion (PR #8019)

All runs used the real `claude` 2.1.322 CLI and the real `bin/fm-spawn.sh` from this
gate worktree, inside a disposable `bin/fm-live-lab.sh` lab (`/tmp/fmlab-pintest`),
torn down with the same helper, which also removed the Claude trust entries it
registered. The one `~/.treehouse/notes-65d578` pool the product created was removed
by hand afterwards.

| # | Scenario | Pin | Observed verdict | spawn exit |
|---|----------|-----|------------------|-----------|
| 1 | pinned worker spawn (lab `up --worker`) | `sonnet` | `model pin asserted: pin 'sonnet' actual 'claude-sonnet-5-5'` | 0 |
| 2 | adversarial: agent reports a different model | `claude-opus-5[1m]` | `model pin mismatch: pin 'claude-opus-5[1m]' but pinned Claude session fc680ac8-... reports 'claude-opus-5'` | 0 |
| 3 | adversarial: agent states no model (vendor 400) | `claude-sonnet-4-5` | `model pin unverified: ... (no session-reported model)` | 0 |

Scenario 1's worker status file held only its own line
`paused [at=...]: waiting for gate file ...`, and no file under the lab's `state/`
contained a `model pin` line, so the verdict never became task state.

`real-transcript-models.log` shows the vendor's own transcripts for the three session
ids above (`claude-sonnet-5-5`, `claude-opus-5`, `<synthetic>`), i.e. the oracle is the
real API-reported model, not a fixture.

`live-guard.log` is the change's opt-in live guard on this host: pi 1.5.2 resumed a
`gpt-5.6-luna` session on `gpt-5.6-sol` and its newest turn reported the resumed pin
while the inherited turn kept the old one; Claude 2.1.322 wrote a pinned launch's
transcript at the session id it was given and reported `claude-sonnet-5-5` for
`sonnet`.
