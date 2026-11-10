#!/usr/bin/env bash
# Regression reproduction against the base commit (14d06b0): each failure mode
# this change fixes gets its own fresh disposable lab so one bug cannot pollute
# the other.
set -u
WT={run-worktree}
BASE=14d06b0441783fc8fc80d04ce5c2745db91b0700
LABS=()
newlab() {
  local d
  d=$(mktemp -d /tmp/fm-base-lab.XXXXXX)
  mkdir -p "$d/home" "$d/parent/state" "$d/parent/data" "$d/parent/config" "$d/parent/projects" "$d/tmux"
  git clone --quiet --no-checkout "$WT" "$d/code"
  git -C "$d/code" checkout --quiet "$BASE"
  git -C "$d/code" checkout -B main --quiet
  printf 'max_trees = 2\nroot = "%s/pool"\n' "$d" > "$d/code/treehouse.toml"
  LABS+=("$d")
  printf '%s' "$d"
}
cleanup() {
  local d
  for d in "${LABS[@]:-}"; do TMUX_TMPDIR="$d/tmux" tmux kill-server 2>/dev/null || true; rm -rf "$d"; done
}
trap cleanup EXIT
run() { # <lab> <args...>
  local lab=$1; shift
  env -u NO_MISTAKES_GATE -u TMUX -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS HOME="$lab/home" FM_HOME="$lab/parent" \
    FM_ROOT_OVERRIDE="$lab/code" TMUX_TMPDIR="$lab/tmux" "$@"
}
meta() { # <lab> <id> <home>
  cat > "$2" 2>/dev/null || true
  cat > "$1/parent/state/$2.meta" <<EOF
window=firstmate:fm-$2
endpoint_task_id=$2
worktree=$3
project=$3
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$3
projects=
EOF
}

echo "### BASE COMMIT $BASE -- failure mode 1: an idle durable home has no protection"
L=$(newlab)
out=$( cd "$L/code" && run "$L" FM_SECONDMATE_CHARTER='base domain one' FM_SECONDMATE_SCOPE='base domain one' \
  bin/fm-home-seed.sh mate1 - --no-projects 2>&1 )
printf '%s\n' "$out" | tail -2
H=$(printf '%s\n' "$out" | sed -n 's/^home=//p' | tail -1)
GD=$(git -C "$H" rev-parse --absolute-git-dir)
[ -e "$GD/locked" ] && echo "   home is Git-locked: $(cat "$GD/locked")" || echo "   NO Git worktree lock on the seeded home (base behaviour)"
rm_out=$(git -C "$L/code" worktree remove "$H" 2>&1); rm_rc=$?
printf '%s\n' "$rm_out" | sed 's/^/   /'
if [ "$rm_rc" -eq 0 ]; then
  echo "   REPRODUCED: an ordinary 'git worktree remove' deleted the idle durable home (still present: $([ -e "$H" ] && echo yes || echo no))"
else
  echo "   base refused the removal"
fi
TMUX_TMPDIR="$L/tmux" tmux kill-server 2>/dev/null || true

echo
echo "### BASE COMMIT $BASE -- failure mode 2: a returned slot keeps the retired payload"
L=$(newlab)
out=$( cd "$L/code" && run "$L" FM_SECONDMATE_CHARTER='base domain two' FM_SECONDMATE_SCOPE='base domain two' \
  bin/fm-home-seed.sh mate2 - --no-projects 2>&1 )
printf '%s\n' "$out" | tail -2
H=$(printf '%s\n' "$out" | sed -n 's/^home=//p' | tail -1)
meta "$L" mate2 "$H"
tear=$( cd "$L/code" && run "$L" bin/fm-teardown.sh mate2 2>&1 ); tear_rc=$?
printf '%s\n' "$tear" | tail -3 | sed 's/^/   /'
echo "   teardown rc=$tear_rc"
echo "   slot contents after the pool return:"
for p in data state config projects .fm-secondmate-home .fm-secondmate-parent; do
  [ -e "$H/$p" ] && echo "     PRESENT: $p"
done
out3=$( cd "$L/code" && run "$L" FM_SECONDMATE_CHARTER='base domain three' FM_SECONDMATE_SCOPE='base domain three' \
  bin/fm-home-seed.sh mate3 - --no-projects 2>&1 ); rc3=$?
printf '%s\n' "$out3" | tail -4 | sed 's/^/   /'
echo "   next seed rc=$rc3"
[ "$rc3" -ne 0 ] && echo "   REPRODUCED: the returned slot refused the next seed while it still carried the retired mate's marker" \
  || echo "   next seed leased the slot"
