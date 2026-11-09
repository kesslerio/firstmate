# Live validation — Pi watcher health verification and automatic repair

Change under validation: `.pi/extensions/fm-primary-pi-watch.ts` (branch `fix/pi-watcher-health`,
target `e93068d14`) plus its docs and pending-reply changes.

User intent: verify and automatically repair an unhealthy Pi watcher arm, replacing a watcher
that stops heartbeating so supervision does not stay silently blind.

## Live setup (disposable, inside the gate)

Every run used a throwaway marked lab home and the real `pi` CLI as the primary session command
on the lab's private tmux socket. No real fleet home, default tmux server, or credential store
was touched.

```
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux"
printf 'export FM_POLL=<poll>\n' > "$LAB/config/watch.env"   # scenario tuning only
cat > "$LAB/launch.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p "$FM_HOME/state"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"   # the session lock bin/fm-session-start.sh would own
exec pi -a --no-session
SH
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -c "$PWD" \
    -e FM_HOME="$LAB" -e FM_WATCH_EXTENSION_LOG_KEEP_LINES=200 "bash $LAB/launch.sh"
```

The tmux pane has a real non-zero grid, so the Pi TUI registered and the project extensions
loaded (`.pi-watch-extension-loaded` names the pi pid, generation 1, phase active). The real
`bin/fm-watch-arm.sh --restart` then started a real `bin/fm-watch.sh` watcher in that home.

Fault injection for "stops heartbeating": the watcher's liveness beacon
(`state/.last-watcher-beat`) was aged with `touch -d` while the real watcher process stayed
alive and identity-matched in the lock (pid, `pid-identity`, `fm-home`, `watcher-path`). The
poll cadence was set per lab (`export FM_POLL=300` / `600`) so the published grace derivation
(`max(300, FM_POLL+60)`, `bin/fm-wake-lib.sh:fm_poll_derived_grace`) was exercised for real.

Teardown: `/quit` through the same socket, then `tmux -L fm-lab kill-server` for that lab,
`rm -rf "$LAB"`. No lab process or socket survived.

## Scenarios and observed product behavior

Each directory holds the captured artifacts for one scenario.

1. `s1-auto-repair` — stale heartbeat replaced with no tool call or user action.
   Beacon aged 400 s under `FM_POLL=300` (derived grace 360 s). The next 30 s health tick wrote
   `health monitor state=retrying arm=<old arm>` to `state/.watch-extension.log`, the old arm's
   cycle record shows `exit_code=143 signal=TERM reason=arm-interrupted beacon_age=409`, a
   replacement arm ran, and the extension confirmed a new watcher pid with a fresh beacon
   (`confirm ... watcherPid=<new> result=confirmed`). Main received the
   `FIRSTMATE WATCHER WAKE: check: rearm-resurface` follow-up, i.e. supervision came back and
   told the session instead of staying silently blind.

2. `s2-identity-withheld` — unprovable identity is never retired (adversarial).
   With a foreign `fm-home` record in the lock and a continuously aged beacon, the watcher pid
   stayed unchanged for 80 s across ≥2 health ticks, the watcher stayed alive, the injected
   foreign `fm-home` value was preserved, and no health/cycle records were written. After
   restoring the home record the same fault produced a repair in 8 s with a confirmed new
   watcher, proving the withholding was the identity guard and not a dead monitor.

3. `s3-long-poll-grace` — grace follows the home's poll cadence (boundary).
   `FM_POLL=600` → derived grace 660 s. A 400 s beacon was tolerated for 90 s across ≥2 ticks
   with no replacement, no log row, no cycle record. Raising the same beacon to 700 s produced
   a health-monitor repair in 6 s (`health monitor state=retrying`, old cycle record
   `beacon_age=704`, new watcher confirmed, fresh beacon).

4. `s4-manual-command` — the user-visible repair surface reports verified health.
   Typing `/fm-watch-arm-pi` in the live primary rendered
   `watcher: unchanged - Pi extension verified this home's watcher identity and fresh progress;
   no manual re-arm needed; ...` and the watcher pid was unchanged afterwards (no duplicate arm).
   The same live primary also ran ~2.5 minutes at the default 15 s cadence with no health
   activity before that command.

5. `s5-healthy-not-churned` — a healthy arm is not churned (adversarial).
   After the S3 repair, the healthy watcher (beacon inside the derived grace) kept the same pid
   for 91 s across ~3 health ticks with no new extension-log row and an unchanged cycle ledger
   mtime.
