#!/usr/bin/env bash
# Live validation driver for the Sol ceiling change under test
# (fm/sol61-ceiling-enforcement): "Enforce Sol ceiling across separate state
# roots and resolve state override against effective configuration".
#
# It stands up a disposable, marked fm-lab home (bin/fm-lab-home.sh) plus a
# registered local secondmate lab home, then drives the REAL product entrypoints
# (bin/fm-spawn.sh and bin/fm-sol-cap-lib.sh) against them:
#
#   S1  a capped worker occupying a registered secondmate home's separate state
#       root makes a dispatch from the primary lab home refuse at the ceiling.
#   S2  redirected config + separate state override: admission claims, the
#       staged handoff promotes the reservation and runs the worker in a REAL
#       tmux pane on the lab's private socket, even though the config inferred
#       from the state path is malformed.
#   S3  adversarial: a malformed *effective* declaration refuses loudly and
#       leaves no reservation and no task record.
#   S4  adversarial: a permissive declaration sitting at the state path's
#       inferred config must not be consulted when the effective config is
#       max=1 - the second dispatch refuses; switching the effective config to
#       the permissive one admits it (control proving the trap is reachable).
set -u

ROOT=${FM_LIVE_ROOT:?set FM_LIVE_ROOT to the run worktree}
EVID=${FM_LIVE_EVIDENCE:?set FM_LIVE_EVIDENCE to the evidence dir}
TMUX_BIN=$(command -v tmux) || { echo "tmux is not on PATH; the live pane launch cannot run"; exit 1; }
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
SOCK=
TMUX_SESS=fm-lab-launch
FAILS=0

cleanup() {
  if [ -n "$SOCK" ]; then
    "$TMUX_BIN" -S "$SOCK/fm-lab.sock" kill-server 2>/dev/null || true
    rm -rf "$SOCK" 2>/dev/null || true
  fi
  # Stop any worker the launcher left running in the lab.
  pkill -f "$LAB/" 2>/dev/null || true
  [ -z "${STAGED_DIR:-}" ] || rm -rf "$STAGED_DIR" 2>/dev/null || true
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

say() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
ok() { printf 'PASS %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
check() {  # <description> <expected-substring> <actual>
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1 (missing: $2)"; printf '%s\n' "$3" | sed 's/^/     | /' ;;
  esac
}
check_absent() {  # <description> <file>
  if [ -e "$2" ]; then bad "$1 ($2 exists)"; else ok "$1"; fi
}

# --- disposable lab homes ---------------------------------------------------
# Minted by the supported writer, which only marks a fresh empty directory and
# is the one authorization a gate agent may use for fleet lifecycle.
H=$("$ROOT/bin/fm-lab-home.sh" create "$LAB") || { echo "cannot mint lab home"; exit 1; }
M=$("$ROOT/bin/fm-lab-home.sh" create "$LAB/sm") || { echo "cannot mint secondmate lab home"; exit 1; }
SOCK=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$H") || { echo "cannot mint lab tmux dir"; exit 1; }
printf 'lab primary home : %s\nlab secondmate   : %s\nlab tmux socket  : %s/fm-lab.sock\n' "$H" "$M" "$SOCK"

# Both homes declare the same ceiling and cover the same Sol model, so the
# machine-wide count is one declaration's worth across two state roots.
printf 'max=1\nmodels=gpt-6.1-sol\n' > "$H/config/sol-cap"
printf 'max=1\nmodels=gpt-6.1-sol\n' > "$M/config/sol-cap"

# Register the secondmate as a LOCAL home the way a real captain's
# data/secondmates.md does, so machine-local state enumeration discovers it.
cat > "$H/data/secondmates.md" <<EOF
# Secondmates

- sm - disposable lab secondmate (home: $M/; scope: repo; projects: all; added 2026-01-01)
EOF

# --- project fixture an end user dispatches from ---------------------------
PROJ=$LAB/proj
mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
git -C "$PROJ" -c user.email=lab@example.invalid -c user.name=Lab commit -q --allow-empty -m init
git init -q --bare "$PROJ.origin.git"
git -C "$PROJ" remote add origin "$PROJ.origin.git"
git --git-dir="$PROJ.origin.git" symbolic-ref HEAD refs/heads/main
git -C "$PROJ" -c user.email=lab@example.invalid -c user.name=Lab push -q -u origin main 2>/dev/null || true

# --- external tools the spawn/launch shells call (not firstmate itself) ----
FAKE=$LAB/fakebin
mkdir -p "$FAKE"
for tool in treehouse gh gh-axi no-mistakes; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/$tool"
  chmod +x "$FAKE/$tool"
done
# The worker the launch must actually run: records the argv it received and
# whether it was reached at all.
cat > "$FAKE/codex" <<'SH'
#!/usr/bin/env bash
# The probe the launch must actually run; <log> is baked into the raw launch
# command so the pane never depends on PATH lookup.
log=$1
shift
printf '%s\n' "${*:-probe-ran}" >> "$log"
printf 'live worker reachable, argv: %s\n' "${*:-probe-ran}"
sleep 30
SH
chmod +x "$FAKE/codex"

# tmux stand-in for the spawn's window bookkeeping only. The launch handoff
# itself is executed in a REAL tmux pane below.
cat > "$FAKE/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_LIVE_CALL_LOG"
case "${1:-}" in
  display-message)
    case "$*" in
      *pane_current_path*) printf '%s\n' "${FM_LIVE_PANE_PATH:-}" ;;
      *) printf 'firstmate\n' ;;
    esac ;;
  list-windows) [ ! -s "$FM_LIVE_CALL_LOG.w" ] || cat "$FM_LIVE_CALL_LOG.w" ;;
  list-panes) printf '%s\n' "${FM_LIVE_PANE_PID:-0}" ;;
  new-window)
    prev=; name=
    for a in "$@"; do [ "$prev" = -n ] && name=$a; prev=$a; done
    grep -Fqx -- "$name" "$FM_LIVE_CALL_LOG.w" 2>/dev/null || printf '%s\n' "$name" >> "$FM_LIVE_CALL_LOG.w" ;;
  kill-window) : ;;
  send-keys)
    # Record the launch text the spawn hands the pane so the same handoff can
    # be executed in a real tmux pane below.
    prev=
    for a in "$@"; do
      if [ "$prev" = -l ]; then
        case "$a" in
          ". '"*"'")
            staged=${a#". '"}
            staged=${staged%"'"}
            if [ -f "$staged" ]; then
              cat "$staged" >> "$FM_LIVE_CALL_LOG.launch"
              printf '%s\n' "$staged" >> "$FM_LIVE_CALL_LOG.launchpath"
            fi ;;
        esac
      fi
      prev=$a
    done ;;
  *) : ;;
esac
exit 0
SH
chmod +x "$FAKE/tmux"

task_fixture() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Live Sol-ceiling check for $2.

## Firstmate spec
Drive the real ceiling admission path.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  printf '{"task":"%s","status":"off","profile":null}\n' "$2" > "$1/data/$2/dispatch-resolution.json"
}

# The real dispatch entrypoint, run from the lab (not a gate worktree) with the
# marked lab home so the product's own gate boundary permits it.
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
cd "$LAB" || exit 1

run_spawn() {  # <case-dir> <pane-path> <args...>
  local case_dir=$1 pane=$2
  shift 2
  env -u FM_ROOT_OVERRIDE FM_HOME="$H" FM_SPAWN_NO_GUARD=1 \
    TMUX="fake,1,0" FM_BACKEND=tmux FM_LIVE_PANE_PID="$$" \
    FM_LIVE_PANE_PATH="$pane" FM_LIVE_CALL_LOG="$case_dir/calls.log" \
    FM_LIVE_INVOCATION_LOG="$case_dir/invocation" \
    PATH="$FAKE:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

new_worktree() {  # <case-dir> <name>
  git -C "$PROJ" worktree add --quiet -b "wt-$2" "$1/wt-$2" >/dev/null 2>&1
  printf '%s\n' "$1/wt-$2"
}

CASES=$LAB/cases
mkdir -p "$CASES"

# =========================================================================
say "S1  registered secondmate home's separate state root holds the slot"
# The secondmate dispatch is admitted through the real product: admission
# reserves, then the reservation is promoted onto a real long-running worker
# process inside the secondmate's own state root. Nothing here is hand-written
# registry data.
task_fixture "$M" sm-task
(
  cd "$LAB" || exit 1
  env -u FM_ROOT_OVERRIDE FM_HOME="$M" PATH="$FAKE:$PATH" \
    "$ROOT/bin/fm-sol-cap-lib.sh" refuse-claim sm-task ship codex gpt-6.1-sol \
    "$M/config" "$M/state" >"$CASES/sm-admit.out" 2>&1 || exit 1
  exec env -u FM_ROOT_OVERRIDE FM_HOME="$M" \
    "$ROOT/bin/fm-sol-cap-lib.sh" run sm-task "$M/state" sleep 120
) &
SM_PID=$!
sleep 1.5
note "secondmate admission: $(cat "$CASES/sm-admit.out")"
note "secondmate registry: $(cat "$M/state/sol-sessions.tsv")"
SM_ROW_PID=$(awk -F'\t' '$1 == "sm-task" {print $4}' "$M/state/sol-sessions.tsv")
if kill -0 "${SM_ROW_PID:-0}" 2>/dev/null; then
  ok "the secondmate home holds a live covered session (pid $SM_ROW_PID)"
else
  bad "the secondmate home holds no live covered session (row pid ${SM_ROW_PID:-none})"
fi

S1=$CASES/s1
mkdir -p "$S1"
task_fixture "$H" task-one
S1_PANE=$(new_worktree "$S1" task-one)
S1_BEFORE=$(ls -1 "$H"/state/*.meta 2>/dev/null | wc -l | tr -d ' ')
S1_OUT=$(run_spawn "$S1" "$S1_PANE" task-one "$PROJ" --harness codex --model gpt-6.1-sol --mode no-mistakes --yolo off)
S1_RC=$?
say "S1  dispatch from the primary lab home at that machine-wide ceiling (rc=$S1_RC)"
printf '%s\n' "$S1_OUT" | sed 's/^/   | /'
[ "$S1_RC" -eq 1 ] && ok "the dispatch was refused" || bad "the dispatch was not refused (rc=$S1_RC)"
check "the refusal names the ceiling" "Sol ceiling reached" "$S1_OUT"
check "the refusal names the secondmate's session" "sm-task (gpt-6.1-sol" "$S1_OUT"
check "the refusal names the separate state root it counted" "in $M/state" "$S1_OUT"
check_absent "the refused dispatch published no task record" "$H/state/task-one.meta"

# Finish S1's session so the remaining scenarios start from an empty machine:
# the secondmate's worker exits, and the machine-wide count is no longer held.
kill "$SM_PID" 2>/dev/null || true
wait "$SM_PID" 2>/dev/null || true
SM_PID=
sleep 0.5
S1_AFTER=$(cd "$LAB" && env -u FM_ROOT_OVERRIDE FM_HOME="$H" FM_STATE_OVERRIDE='' \
  "$ROOT/bin/fm-sol-cap-lib.sh" ceiling "$H/config" 2>&1)
note "ceiling still declared after the secondmate worker exited: $S1_AFTER"
S1_AGAIN=$(cd "$LAB" && env -u FM_ROOT_OVERRIDE FM_HOME="$H" \
  "$ROOT/bin/fm-sol-cap-lib.sh" refuse-claim task-one-b ship codex gpt-6.1-sol \
  "$H/config" "$H/state" 2>&1)
note "dispatch after the secondmate session stopped: $S1_AGAIN"
check "the stopped session freed the machine-wide slot" "claimed" "$S1_AGAIN"

# =========================================================================
say "S2  separate state override reads the effective redirected configuration"
RUNTIME=$LAB/runtime
S2_STATE=$RUNTIME/state
S2_CFG=$LAB/redir-config
mkdir -p "$S2_STATE" "$RUNTIME/config" "$S2_CFG"
touch "$S2_STATE/.last-watcher-beat"
# The declaration inferred from the state path is malformed: any consumer that
# resolved the state override against the path instead of the effective
# configuration would refuse here.
printf 'max=invalid\n' > "$RUNTIME/config/sol-cap"
printf 'max=1\nmodels=gpt-6.1-sol\n' > "$S2_CFG/sol-cap"
# The primary lab home's own declaration is malformed too, so the effective
# configuration must be the override everywhere.
printf 'max=invalid\n' > "$H/config/sol-cap"

S2=$CASES/s2
mkdir -p "$S2"
task_fixture "$H" task-two
S2_PANE=$(new_worktree "$S2" task-two)
S2_OUT=$(FM_STATE_OVERRIDE="$S2_STATE" FM_CONFIG_OVERRIDE="$S2_CFG" \
  run_spawn "$S2" "$S2_PANE" task-two "$PROJ" \
  --harness "$FAKE/codex '$S2/invocation.argv'" --model gpt-6.1-sol --mode no-mistakes --yolo off)
S2_RC=$?
say "S2  dispatch under separate state + redirected config (rc=$S2_RC)"
printf '%s\n' "$S2_OUT" | sed 's/^/   | /'
[ "$S2_RC" -eq 0 ] && ok "admission accepted the dispatch" || bad "admission refused the dispatch (rc=$S2_RC)"
S2_ROW=$(cat "$S2_STATE/sol-sessions.tsv" 2>/dev/null || true)
note "state override registry after admission: ${S2_ROW:-<none>}"
STAGED=$(tail -1 "$S2/calls.log.launchpath" 2>/dev/null || true)
note "spawn tmux calls:"; sed 's/^/     t| /' "$S2/calls.log" 2>/dev/null | head -20
note "staged launch files under the state root:"
find "$S2_STATE" -maxdepth 2 -name 'launch.*.sh' 2>/dev/null | sed 's/^/     f| /'
if [ -z "$STAGED" ]; then
  STAGED=$(find "$S2_STATE" -maxdepth 2 -name 'launch.*.sh' 2>/dev/null | tail -1)
  [ -z "$STAGED" ] || note "using the launch file the spawn staged in the state root"
fi
note "staged handoff file: ${STAGED:-<none>}"
if [ -n "$STAGED" ] && [ -f "$STAGED" ]; then
  ok "the spawn staged a launch handoff"
  note "handoff: $(cat "$STAGED")"
  check "the handoff passes the resolved config override" "FM_CONFIG_OVERRIDE='$S2_CFG'" "$(cat "$STAGED")"
  check "the handoff passes the resolved state override" "FM_STATE_OVERRIDE='$S2_STATE'" "$(cat "$STAGED")"
  STAGED_DIR=${STAGED%/*}

  # Execute that very handoff in a REAL tmux pane on the lab's private socket.
  # The server (and therefore the pane) carries the probe log and the fake
  # toolchain, exactly as an operator's shell would carry its PATH.
  env FM_LIVE_INVOCATION_LOG="$S2/invocation" \
    "$TMUX_BIN" -S "$SOCK/fm-lab.sock" new-session -d -s "$TMUX_SESS" -x 200 -y 50 -c "$S2_PANE"
  "$TMUX_BIN" -S "$SOCK/fm-lab.sock" send-keys -t "$TMUX_SESS" ". '$STAGED'" Enter
  i=0
  while [ "$i" -lt 40 ]; do
    [ -s "$S2/invocation.argv" ] && break
    i=$((i + 1))
    sleep 0.25
  done
  if [ -s "$S2/invocation.argv" ]; then
    ok "the worker launched in the real pane: $(cat "$S2/invocation.argv")"
  else
    bad "the worker never ran in the real pane"
    "$TMUX_BIN" -S "$SOCK/fm-lab.sock" capture-pane -p -t "$TMUX_SESS" | sed 's/^/     p| /'
  fi
  "$TMUX_BIN" -S "$SOCK/fm-lab.sock" capture-pane -p -t "$TMUX_SESS" > "$S2/pane.txt" 2>/dev/null || true
  note "real pane after the launch:"; sed 's/^/     p| /' "$S2/pane.txt" 2>/dev/null | head -20
  S2_PROMOTED=$(awk -F'\t' '$1 == "task-two" {print $4}' "$S2_STATE/sol-sessions.tsv" 2>/dev/null || true)
  note "state override registry after launch: $(cat "$S2_STATE/sol-sessions.tsv" 2>/dev/null || echo '<none>')"
  case "$S2_PROMOTED" in
    '' | 0) bad "the reservation was not promoted to the worker (pid '${S2_PROMOTED:-none}')" ;;
    *)
      if kill -0 "$S2_PROMOTED" 2>/dev/null; then
        ok "the reservation was promoted onto the live worker process (pid $S2_PROMOTED)"
      else
        bad "the promoted pid $S2_PROMOTED is not alive"
      fi ;;
  esac
else
  bad "the spawn staged no launch handoff"
fi

# Control: the malformed declaration inferred from the state path really does
# refuse, proving S2 resolved the override rather than a harmless path.
S2C_OUT=$(cd "$LAB" && env -u FM_ROOT_OVERRIDE FM_HOME="$H" FM_STATE_OVERRIDE="$S2_STATE" \
  "$ROOT/bin/fm-sol-cap-lib.sh" refuse-claim task-ctl ship codex gpt-6.1-sol \
  "$RUNTIME/config" "$S2_STATE" 2>&1)
S2C_RC=$?
say "S2 control: same state root, path-inferred malformed declaration, no effective override (rc=$S2C_RC)"
printf '%s\n' "$S2C_OUT" | sed 's/^/   | /'
[ "$S2C_RC" -eq 1 ] && ok "the path-inferred malformed declaration refuses" ||
  bad "the path-inferred malformed declaration was accepted (rc=$S2C_RC)"
check "the refusal names the malformed declaration" "must declare max as a positive integer" "$S2C_OUT"

# =========================================================================
say "S3  adversarial: a malformed effective declaration refuses and reserves nothing"
S3=$CASES/s3
mkdir -p "$S3"
S3_STATE=$S3/state
S3_CFG=$S3/bad-config
mkdir -p "$S3_STATE" "$S3_CFG"
touch "$S3_STATE/.last-watcher-beat"
printf 'max=invalid\nmodels=gpt-6.1-sol\n' > "$S3_CFG/sol-cap"
task_fixture "$H" task-three
S3_PANE=$(new_worktree "$S3" task-three)
S3_OUT=$(FM_STATE_OVERRIDE="$S3_STATE" FM_CONFIG_OVERRIDE="$S3_CFG" \
  run_spawn "$S3" "$S3_PANE" task-three "$PROJ" --harness codex --model gpt-6.1-sol --mode no-mistakes --yolo off)
S3_RC=$?
say "S3  dispatch under a malformed effective declaration (rc=$S3_RC)"
printf '%s\n' "$S3_OUT" | sed 's/^/   | /'
[ "$S3_RC" -eq 1 ] && ok "the dispatch was refused" || bad "the dispatch was not refused (rc=$S3_RC)"
check "the refusal names the ceiling as unavailable" "Sol ceiling unavailable" "$S3_OUT"
check "the refusal names the malformed max" "must declare max as a positive integer" "$S3_OUT"
check "the refusal names the offending file" "$S3_CFG/sol-cap" "$S3_OUT"
check_absent "no reservation was written for the refused dispatch" "$S3_STATE/sol-sessions.tsv"
check_absent "no task record was published for the refused dispatch" "$H/state/task-three.meta"

# =========================================================================
say "S4  adversarial: a permissive declaration at the inferred config path is not consulted"
S4=$CASES/s4
mkdir -p "$S4"
S4_ROOT=$S4/runtime
S4_STATE=$S4_ROOT/state
S4_CFG=$S4/effective-config
mkdir -p "$S4_STATE" "$S4_ROOT/config" "$S4_CFG"
touch "$S4_STATE/.last-watcher-beat"
# The trap: the declaration a state-path guess would find is permissive.
printf 'max=99\nmodels=gpt-6.1-sol\n' > "$S4_ROOT/config/sol-cap"
printf 'max=1\nmodels=gpt-6.1-sol\n' > "$S4_CFG/sol-cap"
# The primary lab home declares nothing here, so only the overrides can speak.
rm -f "$H/config/sol-cap"

admit() {  # <id> <config-dir> <state-dir>
  (cd "$LAB" && env -u FM_ROOT_OVERRIDE FM_HOME="$H" FM_STATE_OVERRIDE="$3" \
    FM_CONFIG_OVERRIDE="$2" "$ROOT/bin/fm-sol-cap-lib.sh" refuse-claim \
    "$1" ship codex gpt-6.1-sol "$2" "$3" 2>&1)
}
# The first dispatch really holds its slot: admission reserves, then the
# reservation is promoted onto a live worker process, both through the product.
(
  cd "$LAB" || exit 1
  env -u FM_ROOT_OVERRIDE FM_HOME="$H" FM_STATE_OVERRIDE="$S4_STATE" \
    FM_CONFIG_OVERRIDE="$S4_CFG" "$ROOT/bin/fm-sol-cap-lib.sh" refuse-claim \
    task-four-a ship codex gpt-6.1-sol "$S4_CFG" "$S4_STATE" \
    >"$S4/first-admit.out" 2>&1 || exit 1
  exec env -u FM_ROOT_OVERRIDE FM_HOME="$H" FM_STATE_OVERRIDE="$S4_STATE" \
    FM_CONFIG_OVERRIDE="$S4_CFG" \
    "$ROOT/bin/fm-sol-cap-lib.sh" run task-four-a "$S4_STATE" sleep 120
) &
S4_PID=$!
sleep 1.5
S4_A=$(cat "$S4/first-admit.out")
S4_A_RC=0
S4_ROW_PID=$(awk -F'\t' '$1 == "task-four-a" {print $4}' "$S4_STATE/sol-sessions.tsv" 2>/dev/null)
if kill -0 "${S4_ROW_PID:-0}" 2>/dev/null; then
  ok "the first covered worker is live in the redirected state root (pid $S4_ROW_PID)"
else
  bad "the first covered worker is not live (row pid ${S4_ROW_PID:-none})"
fi
S4_B=$(admit task-four-b "$S4_CFG" "$S4_STATE"); S4_B_RC=$?
say "S4  first admission under max=1: rc=$S4_A_RC ${S4_A}"
say "S4  second admission, permissive trap present at the inferred path: rc=$S4_B_RC"
printf '%s\n' "$S4_B" | sed 's/^/   | /'
[ "$S4_A_RC" -eq 0 ] && ok "the first admission claimed the only slot" || bad "the first admission failed"
[ "$S4_B_RC" -eq 1 ] && ok "the second admission was refused at the ceiling" ||
  bad "the second admission was admitted (rc=$S4_B_RC)"
check "the refusal names the ceiling" "Sol ceiling reached" "$S4_B"
check "the refusal names the occupying session" "task-four-a (gpt-6.1-sol" "$S4_B"
# Control: the trap declaration is reachable and does admit, so the refusal
# above is the effective configuration's decision, not an inert file.
S4_C=$(admit task-four-c "$S4_ROOT/config" "$S4_STATE"); S4_C_RC=$?
say "S4 control: same state, effective config switched to the permissive one: rc=$S4_C_RC ${S4_C}"
[ "$S4_C_RC" -eq 0 ] && ok "the permissive declaration admits, so the trap is genuinely reachable" ||
  bad "the control admission failed (rc=$S4_C_RC): ${S4_C}"

# =========================================================================
say "evidence"
printf '%s\n' "$S1_OUT" > "$EVID/sol-cap-cross-root-refusal.txt"
printf '%s\n' "$S2C_OUT" > "$EVID/sol-cap-effective-config-refusal.txt"
printf '%s\n' "$S3_OUT" > "$EVID/sol-cap-malformed-effective-refusal.txt"
printf '%s\n' "$S4_B" > "$EVID/sol-cap-inferred-config-ignored-refusal.txt"
{
  printf 'cross-root refusal:\n%s\n\n' "$S1_OUT"
  printf 'effective-config refusal:\n%s\n\n' "$S2C_OUT"
  printf 'malformed effective declaration refusal:\n%s\n\n' "$S3_OUT"
  printf 'inferred-config-ignored refusal:\n%s\n\n' "$S4_B"
  printf 'permissive control admission:\n%s\n' "$S4_C"
} > "$EVID/sol-cap-live-refusals.txt"
if [ -n "${STAGED:-}" ] && [ -f "$STAGED" ]; then
  cat "$STAGED" > "$EVID/sol-cap-live-handoff.txt"
fi
[ ! -f "$S2/pane.txt" ] || cp "$S2/pane.txt" "$EVID/sol-cap-live-pane.txt"
cp "$S2_STATE/sol-sessions.tsv" "$EVID/sol-cap-live-registry.tsv" 2>/dev/null || true
note "wrote evidence under $EVID"

say "teardown"
[ -z "${SM_PID:-}" ] || { kill "$SM_PID" 2>/dev/null || true; wait "$SM_PID" 2>/dev/null || true; }
[ -z "${S4_PID:-}" ] || { kill "$S4_PID" 2>/dev/null || true; wait "$S4_PID" 2>/dev/null || true; }
"$TMUX_BIN" -S "$SOCK/fm-lab.sock" kill-server 2>/dev/null || true
rm -rf "$SOCK"
SOCK=
[ -z "${STAGED_DIR:-}" ] || rm -rf "$STAGED_DIR"
chmod -R u+w "$LAB" 2>/dev/null || true
rm -rf "$LAB"
printf '\nlab homes and socket removed: %s\n' "$LAB"
if [ "$FAILS" -eq 0 ]; then
  printf '\nRESULT: all live scenarios passed\n'
  exit 0
fi
printf '\nRESULT: %d live check(s) failed\n' "$FAILS"
exit 1
