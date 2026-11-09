#!/usr/bin/env bash
# Drives the real bin/fm-spawn.sh and bin/fm-sol-cap-lib.sh against a disposable
# firstmate lab home plus a private tmux server, validating the opt-in
# concurrent Sol session ceiling.
set -u

EVID=~/.no-mistakes/evidence/01M6YVV5MNWEPG96N8K0N3S7A1
ROOT={run-worktree}
LOG=$EVID/live-transcript.log
: > "$LOG"

LAB=$("$EVID/live-fixture.sh") || { echo "fixture failed" | tee -a "$LOG"; exit 1; }
export FM_HOME="$LAB"
export TREEHOUSE_DIR="$LAB/.treehouse"
CFG=$LAB/config
STD=$LAB/state
TD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
HOLDERS=()

say() { printf '%s\n' "$@" | tee -a "$LOG"; }
hr() { say ""; say "######## $1"; }

TMUX_TMPDIR="$TD" tmux -L fm-lab new-session -d -s primary -c "$LAB/project" || exit 1
SOCK=$(TMUX_TMPDIR="$TD" tmux -L fm-lab display-message -p '#{socket_path}')
SPID=$(TMUX_TMPDIR="$TD" tmux -L fm-lab display-message -p '#{pid}')
export TMUX_TMPDIR="$TD"
export TMUX="$SOCK,$SPID,0"

cleanup() {
  local p
  for p in "${HOLDERS[@]:-}"; do [ -z "$p" ] || kill "$p" 2>/dev/null; done
  TMUX_TMPDIR="$TD" tmux -L fm-lab kill-server 2>/dev/null
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
  chmod -R u+w "$LAB" 2>/dev/null
  rm -rf "$LAB"
}
trap cleanup EXIT

brief() { # <id>
  mkdir -p "$LAB/data/$1"
  cat > "$LAB/data/$1/brief.md" <<EOF
# Task
## Captain's intent
Drive the Sol ceiling live.

## Firstmate spec
Dispatch one capped crewmate.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  "$ROOT/bin/fm-tasks-axi.sh" add "$1" "live task $1" --kind ship >/dev/null 2>&1 || say "WARN backlog add failed for $1"
}

# A capped launch that runs a plain sleeping worker, so the live check starts no
# real agent session while the real spawn, admission, and launch paths all run.
spawn_ship() { # <id> <model>
  local id=$1 model=$2
  brief "$id"
  FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" "$LAB/project" \
    --harness 'sleep 600' --model "$model" --mode no-mistakes --yolo off 2>&1
}

# A live capped session: a real sleeping worker process recorded as a live row.
holder() { # <id> [start-epoch]
  sleep 600 &
  HOLDERS+=("$!")
  printf '%s\t%s\t%s\t%s\n' "$1" gpt-6.1-sol "${2:-$(date +%s)}" "$!" >> "$STD/sol-sessions.tsv"
  sleep 0.3
}

rows() { cat "$STD/sol-sessions.tsv" 2>/dev/null; }

say "lab home: $LAB"
say "private tmux socket: $SOCK"

hr "S1 opt-in: with no config/sol-cap the guard is inert and a covered dispatch launches"
rm -f "$CFG/sol-cap"
say "-- ceiling: $(FM_HOME="$LAB" "$ROOT/bin/fm-sol-cap-lib.sh" ceiling "$CFG" 2>&1)"
S1_OUT=$(spawn_ship live-s1 gpt-6.1-sol)
say "$S1_OUT"
S1_ROW=$(rows | awk -F'\t' '$1=="live-s1"{print "row:", $0}')
if printf '%s' "$S1_OUT" | grep -q "^spawned live-s1" && ! printf '%s' "$S1_OUT" | grep -q "Sol ceiling"; then
  say "RESULT S1: PASS (launched without a Sol refusal in an undeclared home; registry: ${S1_ROW:-none})"
else
  say "RESULT S1: FAIL"
fi

hr "S2 under ceiling=2 with one live session, a covered dispatch is admitted and claims its row"
printf 'max=2\nceiling=2\nmodels=gpt-6.1-sol\n' > "$CFG/sol-cap"
holder live-h1
say "-- registry with the holder: $(rows | tr '\n' ';' | sed 's/;$//')"
S2_OUT=$(spawn_ship live-s2 gpt-6.1-sol)
say "$S2_OUT"
ROW_S2=$(rows | awk -F'\t' '$1=="live-s2"{print $2" pid="$4" model="$2}')
if [ -n "$ROW_S2" ] && printf '%s' "$S2_OUT" | grep -q "^spawned live-s2"; then
  say "RESULT S2: PASS (admitted; claimed row: $ROW_S2)"
else
  say "RESULT S2: FAIL (admitted=${ROW_S2:-no row})"
fi

hr "S3 at the ceiling a covered dispatch is refused, names the active sessions, and creates nothing"
holder live-h2
say "-- registry at the ceiling:"; rows | tee -a "$LOG"
S3_OUT=$(spawn_ship live-s3 gpt-6.1-sol)
say "$S3_OUT"
if printf '%s' "$S3_OUT" | grep -q "Sol ceiling reached: 2 concurrent capped session" &&
  printf '%s' "$S3_OUT" | grep -q "live-h1 (gpt-6.1-sol, age [0-9]" &&
  printf '%s' "$S3_OUT" | grep -q "live-s2 (gpt-6.1-sol, age [0-9]" &&
  printf '%s' "$S3_OUT" | grep -q "declared in config/sol-cap" &&
  [ ! -e "$STD/live-s3.meta" ] && [ ! -e "$LAB/data/live-s3/launch-brief.md" ] &&
  ! (cd "$LAB/project" && git worktree list | grep -q live-s3) &&
  ! TMUX_TMPDIR="$TD" tmux -L fm-lab list-windows -a -F '#{window_name}' | grep -qx "fm-live-s3"; then
  say "RESULT S3: PASS (refused at the cap naming both live sessions, with no record, brief, worktree, or window)"
else
  say "RESULT S3: FAIL"
fi

hr "S4 at the ceiling an uncovered model is not capped and is not refused"
S4_OUT=$(spawn_ship live-s4 gpt-5.6-luna)
say "$S4_OUT"
if printf '%s' "$S4_OUT" | grep -q "^spawned live-s4" && ! printf '%s' "$S4_OUT" | grep -q "Sol ceiling reached"; then
  say "RESULT S4: PASS (uncovered model dispatched at the ceiling)"
else
  say "RESULT S4: FAIL"
fi

hr "S5a a row whose worker process ended no longer counts"
for p in "${HOLDERS[@]}"; do kill "$p" 2>/dev/null; done
HOLDERS=()
sleep 0.5
say "-- registry after the holders ended:"; rows | tee -a "$LOG"
S5A_OUT=$(spawn_ship live-s5a gpt-6.1-sol)
say "$S5A_OUT"
if printf '%s' "$S5A_OUT" | grep -q "^spawned live-s5a"; then
  say "RESULT S5a: PASS (dead rows released their slots; dispatch admitted)"
else
  say "RESULT S5a: FAIL"
fi

hr "S5b a live session of an ancient age still holds its slot (age never releases a live worker)"
printf 'max=1\nceiling=1\nmodels=gpt-6.1-sol\n' > "$CFG/sol-cap"
rm -f "$STD/sol-sessions.tsv"
holder ancient-session 1000000000
say "-- registry with an ancient live row:"; rows | tee -a "$LOG"
S5B_OUT=$(spawn_ship live-s5b gpt-6.1-sol)
say "$S5B_OUT"
if printf '%s' "$S5B_OUT" | grep -q "Sol ceiling reached: 1 concurrent capped session" &&
  printf '%s' "$S5B_OUT" | grep -q "ancient-session (gpt-6.1-sol, age [0-9]"; then
  say "RESULT S5b: PASS (an ancient live row still counted and was named)"
else
  say "RESULT S5b: FAIL"
fi

hr "S6 a malformed declaration refuses loudly, naming the file and the problem"
printf 'max=2\nceiling=9\nmodels=gpt-6.1-sol\n' > "$CFG/sol-cap"
rm -f "$STD/sol-sessions.tsv"
S6_OUT=$(spawn_ship live-s6 gpt-6.1-sol)
say "$S6_OUT"
if printf '%s' "$S6_OUT" | grep -q "Sol ceiling unavailable: $CFG/sol-cap must declare ceiling as an integer from 1 through 2, not '9'" &&
  [ ! -e "$STD/live-s6.meta" ]; then
  say "RESULT S6: PASS (malformed declaration named, dispatch refused, no record created)"
else
  say "RESULT S6: FAIL"
fi

hr "S7 a relaunch at the ceiling is refused, naming the live session"
printf 'max=2\nceiling=2\nmodels=gpt-6.1-sol\n' > "$CFG/sol-cap"
rm -f "$STD/sol-sessions.tsv"
S7A_OUT=$(spawn_ship live-r1 gpt-6.1-sol)
say "-- first launch: $S7A_OUT"
say "-- registry: $(rows | tr '\n' ';' | sed 's/;$//')"
# End the launched worker, leaving the endpoint alive and agent-free, then fill
# the ceiling with an unrelated live session.
for _ in $(seq 1 20); do
  pids=$(TMUX_TMPDIR="$TD" tmux -L fm-lab list-panes -a -F '#{pane_pid}' 2>/dev/null)
  found=0
  for pp in $pids; do
    children=$(pgrep -P "$pp" 2>/dev/null || true)
    for c in $children; do
      case "$(ps -o args= -p "$c" 2>/dev/null)" in *"sleep 600"*) kill "$c" 2>/dev/null && found=1 ;; esac
    done
  done
  [ "$found" = 0 ] || break
  sleep 0.5
done
rm -f "$STD/sol-sessions.tsv"
printf 'max=1\nceiling=1\nmodels=gpt-6.1-sol\n' > "$CFG/sol-cap"
holder live-h7
say "-- registry before relaunch: $(rows | tr '\n' ';' | sed 's/;$//')"
S7_OUT=$(FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" live-r1 --relaunch --harness 'sleep 600' --model gpt-6.1-sol 2>&1)
say "$S7_OUT"
if printf '%s' "$S7_OUT" | grep -q "Sol ceiling reached: 1 concurrent capped session" &&
  printf '%s' "$S7_OUT" | grep -q "live-h7 (gpt-6.1-sol, age [0-9]"; then
  say "RESULT S7: PASS (relaunch refused at the ceiling, naming the live session)"
else
  say "RESULT S7: FAIL"
fi

hr "done"
say "-- final registry:"; rows | tee -a "$LOG"
