#!/usr/bin/env bash
# Live validation driver for the Pi model-selector composer guard.
set -u
ROOT={run-worktree}
EV=~/.no-mistakes/evidence/01M7212W0FFTKW4SJ3J5D9TQDK
BASE=913bb7a7b6e68a107c2d0ee755ee29c6f9e7b208
PREGT=85d33c40e
REAL_TMUX=$(command -v tmux)
FAILED=0
ok()   { printf 'ok - %s\n' "$1"; }
bad()  { printf 'not ok - %s\n' "$1"; FAILED=1; }
note() { printf '# %s\n' "$1"; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-pilab.XXXXXX")
SHIM=$(mktemp -d "${TMPDIR:-/tmp}/fm-pishim.XXXXXX")
SHIM2=$(mktemp -d "${TMPDIR:-/tmp}/fm-shshim.XXXXXX")
PREFIX=$(mktemp -d "${TMPDIR:-/tmp}/fm-prefixbin.XXXXXX")
SOCK1=fm-pilab-$$
SOCK2=fm-shelllab-$$
cleanup() {
  "$REAL_TMUX" -L "$SOCK1" kill-server 2>/dev/null || true
  "$REAL_TMUX" -L "$SOCK2" kill-server 2>/dev/null || true
  rm -rf "$LAB" "$SHIM" "$SHIM2" "$PREFIX"
}
trap cleanup EXIT
printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$REAL_TMUX" "$SOCK1" > "$SHIM/tmux"
printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$REAL_TMUX" "$SOCK2" > "$SHIM2/tmux"
chmod +x "$SHIM/tmux" "$SHIM2/tmux"

mkdir -p "$LAB/agent" "$LAB/work"
cat > "$LAB/agent/models.json" <<'JSON'
{"providers":{"localfake":{"name":"Local Fake","baseUrl":"http://127.0.0.1:9/v1","api":"openai-completions","apiKey":"localfake","models":[{"id":"alpha-model-one","contextWindow":128000},{"id":"beta-model-two","contextWindow":128000},{"id":"gamma-model-three","contextWindow":128000}]}}}
JSON
# Quoted transcript text: the recorded selector rows plus a pane-wide rule.
printf '%s\n' \
  '  ✓ alpha-model-one [localfake]' \
  '→   beta-model-two [localfake]' \
  '    gamma-model-three [localfake]' \
  '  Enter to select · Ctrl+S to set as default · Escape/Ctrl+C to cancel' \
  "$(printf '─%.0s' $(seq 1 96))" > "$LAB/work/quoted.txt"
git -C "$ROOT" show "$BASE":bin/fm-composer-lib.sh > "$LAB/base-composer-lib.sh"
git -C "$ROOT" show "$PREGT":bin/fm-composer-lib.sh > "$LAB/pregt-composer-lib.sh"
cp -a "$ROOT/bin" "$PREFIX/bin"
cp "$LAB/pregt-composer-lib.sh" "$PREFIX/bin/fm-composer-lib.sh"

matcher_from() {  # <lib|base|pregt> <screenfile>
  local which=$1 file=$2 lib
  case "$which" in
    head) lib="$ROOT/bin/fm-composer-lib.sh" ;;
    base) lib="$LAB/base-composer-lib.sh" ;;
    pregt) lib="$LAB/pregt-composer-lib.sh" ;;
  esac
  ( . "$lib"; fm_composer_blocking_dialog "$(cat "$file")" 2>/dev/null )
}

# ============================ Section 1: real pi pane =======================
PATH="$SHIM:$PATH"
cd "$ROOT"
. bin/fm-tmux-lib.sh
. bin/fm-backend.sh
"$REAL_TMUX" -L "$SOCK1" new-session -d -s lab -x 100 -y 60 -c "$LAB/work"
"$REAL_TMUX" -L "$SOCK1" new-window -d -t lab: -n pi -c "$LAB/work" \
  -- env PI_CODING_AGENT_DIR="$LAB/agent" pi
i=0; st=unknown
while [ "$i" -lt 60 ]; do
  st=$(fm_tmux_composer_state lab:pi 2>/dev/null); st=${st:-unknown}
  [ "$st" = empty ] && break
  i=$((i + 1)); sleep 1
done
[ "$st" = empty ] && ok "pi idle composer reached empty" || bad "pi idle composer never reached empty (verdict $st)"
"$REAL_TMUX" -L "$SOCK1" capture-pane -p -t lab:pi > "$EV/pi-idle-pane.txt"
idle_dialog=$(matcher_from head "$EV/pi-idle-pane.txt")
[ -z "$idle_dialog" ] && ok "the idle pi pane names no dialog" || bad "the idle pi pane named '$idle_dialog'"

"$REAL_TMUX" -L "$SOCK1" send-keys -t lab:pi -l '/model'; sleep 1
"$REAL_TMUX" -L "$SOCK1" send-keys -t lab:pi Enter
i=0; d=
while [ "$i" -lt 30 ]; do
  "$REAL_TMUX" -L "$SOCK1" capture-pane -p -t lab:pi > "$LAB/sel.txt"
  d=$(matcher_from head "$LAB/sel.txt")
  [ "$d" = 'Pi model selector' ] && break
  i=$((i + 1)); sleep 1
done
[ "$d" = 'Pi model selector' ] \
  && ok "the live /model selector is named 'Pi model selector'" \
  || bad "the live /model selector was not named (got '$d')"
"$REAL_TMUX" -L "$SOCK1" send-keys -t lab:pi Down; sleep 1
"$REAL_TMUX" -L "$SOCK1" capture-pane -p -t lab:pi > "$EV/pi-selector-pane.txt"
base_d=$(matcher_from base "$EV/pi-selector-pane.txt")
[ -z "$base_d" ] \
  && ok "the base-commit matcher names no dialog on the same live capture (guard was dead)" \
  || bad "the base-commit matcher named '$base_d'"

probe='live probe: this text must not reach the selector'
rc=0
out=$(fm_backend_send_text_submit tmux lab:pi "$probe" 0 0 0 2>"$LAB/err1.txt") || rc=$?
"$REAL_TMUX" -L "$SOCK1" capture-pane -p -t lab:pi > "$EV/pi-selector-after-refused-send.txt"
[ "$rc" -ne 0 ] && ok "the typed send onto the open selector was refused (rc $rc)" \
  || bad "the typed send onto the open selector was accepted"
grep -F 'blocked on a prompt: Pi model selector' "$LAB/err1.txt" >/dev/null \
  && ok "the refusal names 'Pi model selector'" \
  || bad "the refusal did not name the selector: $(tr '\n' ' ' < "$LAB/err1.txt")"
grep -F "$probe" "$EV/pi-selector-after-refused-send.txt" >/dev/null \
  && bad "the probe text reached the open selector" \
  || ok "the probe text never appeared on the pane"
[ "$(matcher_from head "$EV/pi-selector-after-refused-send.txt")" = 'Pi model selector' ] \
  && ok "the selector is still open after the refused send" \
  || bad "the refused send left the selector unnamed (answered or closed?)"

# ---- same live pane, but with the selector quoted above a live composer
"$REAL_TMUX" -L "$SOCK1" send-keys -t lab:pi Escape; sleep 2
i=0; st=unknown
while [ "$i" -lt 45 ]; do
  st=$(fm_tmux_composer_state lab:pi 2>/dev/null); st=${st:-unknown}
  [ "$st" = empty ] && break
  i=$((i + 1)); sleep 1
done
[ "$st" = empty ] && ok "the pane returned to an idle composer after Escape" \
  || bad "the pane never returned to an idle composer (verdict $st)"
"$REAL_TMUX" -L "$SOCK1" send-keys -t lab:pi -l "!cat $LAB/work/quoted.txt"; sleep 1
"$REAL_TMUX" -L "$SOCK1" send-keys -t lab:pi Enter; sleep 3
"$REAL_TMUX" -L "$SOCK1" capture-pane -p -t lab:pi > "$EV/pi-quoted-selector-above-composer-pane.txt"
grep -F 'Enter to select · Ctrl+S to set as default · Escape/Ctrl+C to cancel' \
  "$EV/pi-quoted-selector-above-composer-pane.txt" >/dev/null \
  && ok "the pane quotes the recorded selector footer above its live composer" \
  || bad "the quoted selector footer never reached the pane"
qd=$(matcher_from head "$EV/pi-quoted-selector-above-composer-pane.txt")
[ -z "$qd" ] && ok "quoted selector text above the live composer names no dialog" \
  || bad "quoted selector text above the live composer named '$qd'"
probe2='live valid send with a quoted selector above'
rc=0
out2=$(fm_backend_send_text_submit tmux lab:pi "$probe2" 0 0 0 2>"$LAB/err2.txt") || rc=$?
"$REAL_TMUX" -L "$SOCK1" capture-pane -p -t lab:pi > "$EV/pi-quoted-after-send-pane.txt"
[ "$rc" -eq 0 ] && ok "the send with a quoted selector above was accepted (verdict '$out2')" \
  || bad "a valid send was refused (rc $rc): $(tr '\n' ' ' < "$LAB/err2.txt")"
grep -F 'blocked on a prompt' "$LAB/err2.txt" >/dev/null \
  && bad "the quoted selector still blocked the send" \
  || ok "the quoted selector did not block the send"

# ============================ Section 2: real shell prompt ==================
"$REAL_TMUX" -L "$SOCK2" new-session -d -s lab -x 100 -y 40 -c "$LAB" -- bash --norc -i
sleep 2
"$REAL_TMUX" -L "$SOCK2" send-keys -t lab -l "printf '%s\n' '  ✓ alpha-model-one [localfake]' '→   beta-model-two [localfake]' '  Enter to select · Ctrl+S to set as default · Escape/Ctrl+C to cancel' \"\$(printf '─%.0s' \$(seq 1 96))\""
"$REAL_TMUX" -L "$SOCK2" send-keys -t lab Enter; sleep 2
"$REAL_TMUX" -L "$SOCK2" send-keys -t lab -l 'echo "unfinished'; sleep 1
"$REAL_TMUX" -L "$SOCK2" send-keys -t lab Enter; sleep 2
"$REAL_TMUX" -L "$SOCK2" capture-pane -p -t lab > "$EV/shell-bare-prompt-pane.txt"
grep -qx '>' "$EV/shell-bare-prompt-pane.txt" \
  && ok "the shell pane shows a real bare '>' continuation prompt" \
  || note "the bare '>' prompt row check is advisory"
head_d=$(matcher_from head "$EV/shell-bare-prompt-pane.txt")
[ -z "$head_d" ] && ok "the changed matcher names no dialog over the bare '>' prompt" \
  || bad "the changed matcher named '$head_d' over the bare '>' prompt"
pregt_d=$(matcher_from pregt "$EV/shell-bare-prompt-pane.txt")
[ "$pregt_d" = 'Pi model selector' ] \
  && ok "the pre-fix matcher named 'Pi model selector' over that same live pane" \
  || bad "the pre-fix matcher did not reproduce the swallow (got '$pregt_d')"
# The pre-fix send path, against the same live pane.
pre_rc=0
pre_out=$(PATH="$SHIM2:$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_send_text_submit tmux lab "pre-fix probe: a valid send" 0 0 0' \
  _ "$PREFIX" 2>"$LAB/err3.txt") || pre_rc=$?
grep -F 'blocked on a prompt: Pi model selector' "$LAB/err3.txt" >/dev/null \
  && ok "the pre-fix send path refused that pane as the model selector (rc $pre_rc)" \
  || bad "the pre-fix send path did not reproduce the refusal: $(tr '\n' ' ' < "$LAB/err3.txt")"
"$REAL_TMUX" -L "$SOCK2" capture-pane -p -t lab > "$EV/shell-bare-prompt-after-prefix-send.txt"
rc=0
out3=$(PATH="$SHIM2:$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_send_text_submit tmux lab "current probe: a valid send" 0 0 0' \
  _ "$ROOT" 2>"$LAB/err4.txt") || rc=$?
grep -F 'blocked on a prompt' "$LAB/err4.txt" >/dev/null \
  && bad "the changed send path still blocked on the prompt: $(tr '\n' ' ' < "$LAB/err4.txt")" \
  || ok "the changed send path did not block on a prompt (rc $rc, verdict '$out3')"
"$REAL_TMUX" -L "$SOCK2" capture-pane -p -t lab > "$EV/shell-bare-prompt-after-current-send.txt"

# ============================ Summary ======================================
if [ "$FAILED" -eq 0 ]; then printf 'ok - live Pi selector guard scenarios\n'; else printf 'not ok - live Pi selector guard scenarios\n'; fi
exit "$FAILED"
