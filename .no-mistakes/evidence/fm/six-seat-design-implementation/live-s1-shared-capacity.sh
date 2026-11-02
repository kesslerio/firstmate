#!/usr/bin/env bash
# Live scenario S1: one generation-bound capacity shared by a primary lab home
# and its local second mate, driven through the real bin/fm-spawn.sh,
# bin/fm-fleet-seats.sh, bin/fm-teardown.sh on a real private tmux server.
#
# Everything the product writes stays inside $LAB (a disposable lab home) and a
# private tmux socket directory. No agent/model call is made: the endpoint pane
# runs a lab stand-in process named `claude` so the backend liveness classifier
# sees a real foreground harness process.
set -u
ROOT=${ROOT:?run from the worktree}
LAB=${LAB:?disposable lab dir}
REALMODE=${REALMODE:-stub}
BIN=$ROOT/bin
PRIMARY=$LAB/primary
MATE=$LAB/android
TASK=s1-alpha
MATE_TASK=s1-beta
TMPDIR_LAB=$LAB/tmp
mkdir -p "$TMPDIR_LAB"
export TMPDIR=$TMPDIR_LAB
SOCK=$LAB/tmux/seatlab

say() { printf '\n### %s\n' "$*"; }
step() { printf '\n--- %s\n' "$*"; }

cleanup() {
  [ "${KEEP_SERVER:-0}" = 1 ] || tmux -S "$SOCK" kill-server 2>/dev/null || true
}
trap cleanup EXIT

# --- fixtures ---------------------------------------------------------------
mkdir -p "$LAB/fakebin" "$PRIMARY/data/$TASK" "$PRIMARY/data/$MATE_TASK" \
  "$PRIMARY/projects" "$PRIMARY/user-home" "$MATE/data" "$MATE/config" \
  "$MATE/state" "$MATE/projects" "$LAB/project" "$LAB/wt"
cat > "$LAB/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in --lease-holder) id=$2; shift 2 ;; *) shift ;; esac
    done
    printf '%s\n' "$FM_LAB_WORKTREE/$id" ;;
  return) shift; [ "${1:-}" = --force ] && shift; rm -rf "$1" ;;
  *) exit 0 ;;
esac
SH
if [ "$REALMODE" = real ]; then
  REAL_CLAUDE=$(command -v claude) || { echo "no claude"; exit 1; }
  cat > "$LAB/fakebin/claude" <<SH
#!/usr/bin/env bash
exec "$REAL_CLAUDE" --dangerously-skip-permissions "\$@"
SH
else
  cat > "$LAB/fakebin/claude" <<'SH'
#!/usr/bin/env bash
while :; do sleep 5; done
SH
fi
chmod +x "$LAB/fakebin/treehouse" "$LAB/fakebin/claude"

git -C "$LAB/project" init -q -b main
git -C "$LAB/project" -c user.name=Lab -c user.email=lab@example.invalid \
  commit -q --allow-empty -m fixture
for wt in "$TASK" "$MATE_TASK"; do
  git -C "$LAB/project" worktree add -q -b "fm/$wt" "$LAB/wt/$wt"
done

brief() { # <home> <task> <id-ish>
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Prove shared fleet seat capacity in a disposable lab.

## Firstmate spec
Nothing to build.

Delivery contract: mode=local-only
EOF
}
brief "$PRIMARY" "$TASK"
mkdir -p "$MATE/data/$MATE_TASK"
brief "$MATE" "$MATE_TASK"

printf 'claude\n' > "$PRIMARY/config/crew-harness"
printf 'claude\n' > "$MATE/config/crew-harness"
# One pool, one seat, shared by the primary and the registered local mate.
printf '{"pools":[{"name":"shared","capacity":1,"models":["pool-model-a"]}]}\n' > "$PRIMARY/config/fleet-seats"
printf '%s\n' "$$" > "$PRIMARY/state/.lock"
touch "$PRIMARY/state/.last-watcher-beat"
printf 'android\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PRIMARY" > "$MATE/.fm-secondmate-parent"
printf -- '- android - Lab local mate. (home: %s; scope: lab; projects: ; added 2026-11-02)\n' "$MATE" > "$PRIMARY/data/secondmates.md"

# A lab stand-in for the third-party worktree pool inside an interactive pane:
# `treehouse get` moves the pane into the pre-created real git worktree for the
# window's task, and the harness/agent commands resolve inside the lab's fakebin.
# This keeps every write inside $LAB and never touches the operator's ~/.treehouse.
cat > "$LAB/labrc" <<'RC'
export PATH="__FAKEBIN__:$PATH"
export TREEHOUSE_ROOT="__TREEHOUSE__"
treehouse() {
  case "${1:-}" in
    get)
      local win id
      win=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{window_name}' 2>/dev/null)
      id=${win#fm-}
      if [ -d "$FM_LAB_WORKTREE/$id" ]; then cd "$FM_LAB_WORKTREE/$id" && pwd; return 0; fi
      return 1 ;;
    return) return 0 ;;
    *) return 0 ;;
  esac
}
RC
sed -i "s#__FAKEBIN__#$LAB/fakebin#; s#__TREEHOUSE__#$LAB/treehouse#" "$LAB/labrc"

tmux -f /dev/null -S "$SOCK" new-session -d -s primary -n fm-primary -c "$PRIMARY" \
  "env PATH=$LAB/fakebin:\$PATH FM_HOME=$PRIMARY TREEHOUSE_ROOT=$LAB/treehouse FM_LAB_WORKTREE=$LAB/wt bash --rcfile $LAB/labrc -i"
tmux -S "$SOCK" set-option -g default-command \
  "env PATH=$LAB/fakebin:\$PATH TREEHOUSE_ROOT=$LAB/treehouse FM_LAB_WORKTREE=$LAB/wt bash --rcfile $LAB/labrc -i"
SERVER_PID=$(tmux -S "$SOCK" display-message -p -t primary '#{pid}')
export TMUX="$SOCK,$SERVER_PID,0"
step "tmux server: $(tmux -S "$SOCK" display-message -p -t primary '#{socket_path}') pid=$SERVER_PID"

# Every firstmate call runs as the lab home, from the gate worktree, with the
# inherited fleet overrides stripped so all paths resolve inside the lab.
fm() { # <home> <cmd...>
  local home=$1
  shift
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$home" HOME="$PRIMARY/user-home" TMUX="$TMUX" \
    PATH="$LAB/fakebin:$PATH" FM_LAB_WORKTREE="$LAB/wt" FM_BACKEND=tmux \
    TREEHOUSE_ROOT="$LAB/treehouse" FM_SPAWN_NO_GUARD=1 "$@"
}

# 0. Before any holder exists: with three seats, eight simultaneous
# reservations from both homes must grant exactly three. The shared lock is
# what prevents overbooking across the two homes.
step "capacity 3, eight simultaneous reservations across both homes, expect exactly 3 grants"
printf '{"pools":[{"name":"shared","capacity":3,"models":["pool-model-a"]}]}\n' > "$PRIMARY/config/fleet-seats"
for i in 1 2 3 4 5 6 7 8; do
  home=$PRIMARY
  [ $((i % 2)) -eq 0 ] && home=$MATE
  (
    sleep 600 >/dev/null 2>&1 &
    holder=$!
    out=$(fm "$home" "$BIN/fm-fleet-seats.sh" reserve "wide$i" --generation "gw$i" \
      --harness claude --model pool-model-a --kind ship --holder-pid "$holder" 2>&1)
    printf '%s\t%s\n' "$?" "$out"
    kill "$holder" 2>/dev/null || true
  ) > "$LAB/race.$i" 2>&1 &
done
wait
printf 'reservation outcomes:\n'
cat "$LAB"/race.* | sort | sed 's/^/  /'
wide_grants=$(cat "$LAB"/race.* | grep -c '^0' || true)
printf 'granted=%s of 8 with capacity 3\n' "$wide_grants"
[ "$wide_grants" -eq 3 ] || { echo "SCENARIO FAILED: $wide_grants concurrent reservations were granted with 3 seats"; exit 1; }
used=$(cat "$LAB"/race.* | sed -n 's/.*used=\([0-9]*\) capacity=.*/\1/p' | sort -n | tail -1)
[ "$used" = 3 ] || { echo "SCENARIO FAILED: the holder count was $used, not 3"; exit 1; }
for i in 1 2 3 4 5 6 7 8; do
  home=$PRIMARY
  [ $((i % 2)) -eq 0 ] && home=$MATE
  fm "$home" "$BIN/fm-fleet-seats.sh" release "wide$i" --generation "gw$i" --reason prelaunch >/dev/null 2>&1 || true
done
printf '{"pools":[{"name":"shared","capacity":1,"models":["pool-model-a"]}]}\n' > "$PRIMARY/config/fleet-seats"
rm -f "$LAB"/race.*

say "S1: primary and local second mate share ONE seat"
step "pool declaration: $(cat "$PRIMARY/config/fleet-seats")"

# 1. A real pooled ship spawn in the primary takes the only seat.
step "bin/fm-spawn.sh $TASK (primary, model pool-model-a)"
spawn1=$(fm "$PRIMARY" "$BIN/fm-spawn.sh" "$TASK" "$LAB/project" --mode local-only --yolo off \
  --harness claude --model pool-model-a 2>&1)
rc1=$?
printf 'rc=%s\n%s\n' "$rc1" "$spawn1"
[ "$rc1" -eq 0 ] || { echo "SCENARIO FAILED: primary spawn did not launch"; exit 1; }

step "seat ledger for $TASK"
show1=$(fm "$PRIMARY" "$BIN/fm-fleet-seats.sh" show "$TASK" 2>&1)
printf '%s\n' "$show1"
printf '%s\n' "$show1" | jq -r '.incarnations[] | "generation=\(.generation) lifecycle=\(.lifecycle) phase=\(.launch_phase) model=\(.model) kind=\(.kind)"'

# 2. The registered local second mate must be refused: same pool, same one seat.
step "bin/fm-spawn.sh $MATE_TASK (local second mate android, model pool-model-a)"
spawn2=$(fm "$MATE" "$BIN/fm-spawn.sh" "$MATE_TASK" "$LAB/project" --mode local-only --yolo off \
  --harness claude --model pool-model-a 2>&1)
rc2=$?
printf 'rc=%s\n%s\n' "$rc2" "$spawn2"
[ "$rc2" -eq 1 ] || { echo "SCENARIO FAILED: the mate was not refused while the pool was full"; exit 1; }
printf '%s\n' "$spawn2" | grep -q 'pool shared is full' \
  || { echo "SCENARIO FAILED: refusal did not name the full pool"; exit 1; }
printf '%s\n' "$spawn2" | grep -q "$TASK" \
  || { echo "SCENARIO FAILED: refusal did not name the current holder"; exit 1; }
[ ! -e "$MATE/state/$MATE_TASK.meta" ] \
  || { echo "SCENARIO FAILED: a refused spawn published a task record"; exit 1; }

# 3. Concurrent reservations from both homes still never overbook.
step "6 concurrent bin/fm-fleet-seats.sh reserve calls across both homes (capacity 1, one seat already held)"
for i in 1 2 3 4 5 6; do
  home=$PRIMARY
  [ $((i % 2)) -eq 0 ] && home=$MATE
  (
    sleep 600 >/dev/null 2>&1 &
    holder=$!
    out=$(fm "$home" "$BIN/fm-fleet-seats.sh" reserve "race$i" --generation "g$i" \
      --harness claude --model pool-model-a --kind ship --holder-pid "$holder" 2>&1)
    printf '%s\t%s\n' "$?" "$out"
    kill "$holder" 2>/dev/null || true
  ) > "$LAB/race.$i" 2>&1 &
done
wait
printf 'reservation outcomes:\n'
cat "$LAB"/race.* | sort | sed 's/^/  /'
grants=$(cat "$LAB"/race.* | grep -c '^0' || true)
[ "$grants" -eq 0 ] || { echo "SCENARIO FAILED: $grants concurrent reservations were granted with the only seat already held"; exit 1; }

# 4. Release the primary's seat through a real teardown, then the mate launches.
step "bin/fm-teardown.sh $TASK (primary)"
td=$(fm "$PRIMARY" "$BIN/fm-teardown.sh" "$TASK" 2>&1)
printf 'rc=%s\n%s\n' "$?" "$td"
[ -e "$PRIMARY/state/$TASK.meta" ] && { echo "SCENARIO FAILED: teardown left the task record"; exit 1; }

step "seat ledger for $TASK after teardown"
fm "$PRIMARY" "$BIN/fm-fleet-seats.sh" show "$TASK" 2>&1 \
  | jq -c '.incarnations[] | {generation, lifecycle}'

step "bin/fm-spawn.sh $MATE_TASK (local second mate android) after the seat freed"
spawn3=$(fm "$MATE" "$BIN/fm-spawn.sh" "$MATE_TASK" "$LAB/project" --mode local-only --yolo off \
  --harness claude --model pool-model-a 2>&1)
rc3=$?
printf 'rc=%s\n%s\n' "$rc3" "$spawn3"
[ "$rc3" -eq 0 ] || { echo "SCENARIO FAILED: the mate was still refused after the seat was released"; exit 1; }

say "PASS: one seat spanned the primary and its local second mate; the mate was refused at capacity and admitted after teardown released it"
