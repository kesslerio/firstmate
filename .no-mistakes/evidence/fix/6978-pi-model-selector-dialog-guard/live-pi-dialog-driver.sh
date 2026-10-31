#!/usr/bin/env bash
# Live drive of the Pi model-selector dialog guard (tests, firmware worktree).
# Everything disposable: private tmux socket, throwaway PI_CODING_AGENT_DIR with
# a provider on an unreachable port, no operator state, no credentials.
set -u
ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M68D63AFMC68ZRQERHQ49W6D
EVID=/home/art/.no-mistakes/evidence/01M68D63AFMC68ZRQERHQ49W6D
SOCKET="fm-tstpi-$$"
SESSION="tstpi"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/fm-tstpi.XXXXXX") || exit 1
SHIM=$(mktemp -d "${TMPDIR:-/tmp}/fm-tstpi-shim.XXXXXX") || exit 1
export DISABLE_AUTOUPDATER=1
REAL_TMUX=$(command -v tmux)
PATH_FAIL=0
note() { printf '## %s\n' "$*"; }
ok() { printf 'ok - %s\n' "$*"; }
bad() { printf 'FAIL - %s\n' "$*"; PATH_FAIL=1; }

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$FIX" "$SHIM"
}
trap cleanup EXIT INT TERM

cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM/tmux"
PATH="$SHIM:$PATH"

export FM_ROOT_OVERRIDE="$ROOT"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

# --- fixture: throwaway pi agent dir, provider on a closed port --------------
mkdir -p "$FIX/agent"
cat > "$FIX/agent/models.json" <<'JSON'
{
  "providers": {
    "localfake": {
      "name": "Local Fake",
      "baseUrl": "http://127.0.0.1:9/v1",
      "api": "openai-completions",
      "apiKey": "localfake",
      "models": [
        { "id": "alpha-model-one", "contextWindow": 128000 },
        { "id": "beta-model-two", "contextWindow": 128000 },
        { "id": "gamma-model-three", "contextWindow": 128000 }
      ]
    }
  }
}
JSON

tmux new-session -d -s "$SESSION" -x 100 -y 44 -c "$FIX"
tmux new-window -d -t "$SESSION:" -n pi -c "$FIX" -- \
  env PI_CODING_AGENT_DIR="$FIX/agent" pi
TARGET="$SESSION:pi"

note "pi version: $(pi --version 2>&1 | head -1) ; tmux: $("$REAL_TMUX" -V)"

# --- scenario A: a real idle pi pane is not misread as the selector ----------
i=0
while [ "$i" -lt 60 ]; do
  [ "$(fm_tmux_composer_state "$TARGET")" = empty ] && break
  i=$((i + 1)); sleep 1
done
[ "$i" -lt 60 ] || { bad "pi never reached an idle composer"; tmux capture-pane -p -t "$TARGET" | tail -20 >&2; exit 1; }
tmux capture-pane -p -t "$TARGET" > "$EVID/pi-idle-composer.txt"
idle_screen=$(fm_tmux_composer_capture "$TARGET")
if dialog=$(fm_composer_blocking_dialog "$idle_screen"); then
  bad "a real idle pi composer was named as a dialog: '$dialog'"
else
  ok "a real idle pi pane (cursor in its composer) is not named as a blocking dialog"
fi

# --- scenario B: open /model and require the selector to be named ------------
tmux send-keys -t "$TARGET" -l '/model'
sleep 1
tmux send-keys -t "$TARGET" Enter
i=0; polled=0
while [ "$i" -lt 45 ]; do
  screen=$(fm_tmux_composer_capture "$TARGET" 2>/dev/null) || screen=''
  if dialog=$(fm_composer_blocking_dialog "$screen"); then polled=1; break; fi
  i=$((i + 1)); sleep 1
done
[ "$polled" -eq 1 ] || { bad "the live /model selector was not named"; tmux capture-pane -p -t "$TARGET" | tail -25 >&2; exit 1; }
tmux capture-pane -p -t "$TARGET" > "$EVID/pi-model-selector.txt"
[ "$dialog" = 'Pi model selector' ] || bad "dialog name was '$dialog'"
ok "the live /model selector is named: $dialog"

# Move the highlight off the current model so -> and the check sit on different rows.
tmux send-keys -t "$TARGET" Down
sleep 1
tmux capture-pane -p -t "$TARGET" > "$EVID/pi-model-selector-highlight-moved.txt"
before=$(fm_tmux_composer_capture "$TARGET")
dialog=$(fm_composer_blocking_dialog "$before") || { bad "selector lost after highlight move"; exit 1; }
[ "$dialog" = 'Pi model selector' ] || bad "highlight-moved dialog name was '$dialog'"
ok "with the highlight on a non-current model the selector is still named: $dialog"

# --- scenario C: the real send entry refuses and types nothing --------------
probe='live-guard probe: this text must not reach the selector'
errf="$EVID/pi-blocked-send.stderr"
rc=0
fm_backend_send_text_submit tmux "$TARGET" "$probe" 0 0 0 >/dev/null 2>"$errf" || rc=$?
after=$(fm_tmux_composer_capture "$TARGET")
tmux capture-pane -p -t "$TARGET" > "$EVID/pi-model-selector-after-refused-send.txt"
if [ "$rc" -eq 0 ]; then bad "a send onto the open selector was accepted"; else ok "the send was refused (rc=$rc)"; fi
if grep -F 'blocked on a prompt: Pi model selector' "$errf" >/dev/null; then
  ok "the refusal names the dialog: $(tr '\n' ' ' < "$errf")"
else
  bad "the refusal did not name the selector: $(tr '\n' ' ' < "$errf")"
fi
if printf '%s' "$after" | grep -F "$probe" >/dev/null; then
  bad "the probe text was typed into the selector"
else
  ok "the probe text was never typed into the selector"
fi
if [ "$before" = "$after" ]; then
  ok "the selector pane is byte-identical before and after the refused send"
else
  bad "the selector pane changed across the refused send"
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -20 >&2
fi
if fm_composer_blocking_dialog "$after" >/dev/null; then
  ok "the selector is still open after the refused send (no Enter was sent to it)"
else
  bad "the refused send closed or answered the selector"
fi

# --- scenario D: a real pi composer still accepts a send after dismissal ----
tmux send-keys -t "$TARGET" Escape
i=0
while [ "$i" -lt 30 ]; do
  s=$(fm_tmux_composer_capture "$TARGET" 2>/dev/null) || s=''
  fm_composer_blocking_dialog "$s" >/dev/null || break
  i=$((i + 1)); sleep 1
done
[ "$i" -lt 30 ] || { bad "selector did not close on Escape"; exit 1; }
tmux capture-pane -p -t "$TARGET" > "$EVID/pi-composer-after-escape.txt"
# Pi's provider is a closed port, so submitting here spends no tokens.
send_rc=0
fm_backend_send_text_submit tmux "$TARGET" 'hello from the live guard' 1 0.5 0.2 >/dev/null 2>"$EVID/pi-accepted-send.stderr" || send_rc=$?
sleep 2
tmux capture-pane -p -t "$TARGET" > "$EVID/pi-composer-after-accepted-send.txt"
if grep -F 'blocked on a prompt' "$EVID/pi-accepted-send.stderr" >/dev/null; then
  bad "a real pi composer was refused as a dialog: $(tr '\n' ' ' < "$EVID/pi-accepted-send.stderr")"
else
  ok "a real pi composer accepts a send (no dialog refusal; send rc=$send_rc)"
fi
if tmux capture-pane -p -t "$TARGET" | grep -F 'hello from the live guard' >/dev/null; then
  ok "the typed text is visible in the real pi pane"
else
  note "typed text no longer visible in the pane (pi redraws after the failed provider call):"
  tmux capture-pane -p -t "$TARGET" | tail -8
fi

# --- scenario E: a quoted selector above a live bare composer is not a dialog
cat > "$FIX/quoted-frame.txt" <<'FRAME'
────────────────────────────────────────────────────────────────────────────

Only showing models from configured providers. Use /login to add providers.

>

  ✓ alpha-model-one [localfake]
→   beta-model-two [localfake]
    gamma-model-three [localfake]

  Model Name: beta-model-two

  Model catalogs refreshed.

  Enter to select · Ctrl+S to set as default · Escape/Ctrl+C to cancel
────────────────────────────────────────────────────────────────────────────
FRAME
tmux new-window -d -t "$SESSION:" -n shell -c "$FIX" -- \
  env PS1='> ' bash --norc --noprofile -i
SH_TARGET="$SESSION:shell"
sleep 2
# The shell pane must show the quoted frame above its own bare `'> '` prompt.
tmux send-keys -t "$SH_TARGET" -l 'cat quoted-frame.txt'
tmux send-keys -t "$SH_TARGET" Enter
sleep 2
tmux capture-pane -p -t "$SH_TARGET" > "$EVID/quoted-selector-above-bare-composer.txt"
qscreen=$(fm_tmux_composer_capture "$SH_TARGET")
if dialog=$(fm_composer_blocking_dialog "$qscreen"); then
  bad "a quoted selector above a live bare '>' composer was named as a dialog: '$dialog'"
else
  ok "a quoted selector above a live bare '>' composer is not named as a dialog"
fi
qrc=0
fm_backend_send_text_submit tmux "$SH_TARGET" 'echo quoted-selector-negative-probe-ok' 1 0.5 0.2 \
  >/dev/null 2>"$EVID/quoted-send.stderr" || qrc=$?
sleep 2
tmux capture-pane -p -t "$SH_TARGET" > "$EVID/quoted-selector-after-send.txt"
if grep -F 'blocked on a prompt' "$EVID/quoted-send.stderr" >/dev/null; then
  bad "the quoted-selector pane refused the send: $(tr '\n' ' ' < "$EVID/quoted-send.stderr")"
else
  ok "the quoted-selector pane accepted the send (send rc=$qrc)"
fi
if tmux capture-pane -p -t "$SH_TARGET" | grep -F 'quoted-selector-negative-probe-ok' >/dev/null; then
  ok "the typed command actually ran in the live pane"
else
  bad "the typed command did not run"
fi

[ "$PATH_FAIL" -eq 0 ] && printf 'ALL LIVE SCENARIOS PASSED\n' || printf 'LIVE SCENARIO FAILURES\n'
exit "$PATH_FAIL"
