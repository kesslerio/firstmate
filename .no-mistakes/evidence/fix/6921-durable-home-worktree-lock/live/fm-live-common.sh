#!/usr/bin/env bash
# Shared fixture for the live durable-home scenarios.
#
# Every scenario builds a throwaway world inside one mktemp dir:
#   $BASE/fmroot   - a real git repo copied from the gate worktree (the firstmate
#                    code root / treehouse pool project)
#   $BASE/pool     - a real treehouse pool (real `treehouse get --lease` /
#                    `treehouse return --force`) rooted inside the throwaway dir
#   $BASE/lab      - the firstmate home (state/, data/) holding mate.meta
#   $BASE/tmux     - a private tmux socket dir so no default server is touched
# The product under test is the gate worktree's own bin/ scripts; only the
# treehouse pool and the tmux server are real external processes, never stubs.
set -u

W={run-worktree}
EVID=~/.no-mistakes/evidence/01M744DSFX1MRXD7FZ1NWTJ9AD/live
REAL_TREEHOUSE=$(command -v treehouse)

FAILS=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; FAILS=$((FAILS + 1)); }
note() { printf '\n### %s\n' "$*"; }
check() {  # <description> <command...>
  local what=$1
  shift
  if "$@"; then pass "$what"; else fail "$what"; fi
}
present() { [ -e "$1" ] || [ -L "$1" ]; }
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }

world() {  # mint a fresh throwaway world
  BASE=$(mktemp -d /tmp/fm-liv.XXXXXX) || exit 1
  mkdir -p "$BASE/fmroot" "$BASE/lab/state" "$BASE/lab/data" "$BASE/pool" "$BASE/tmux"
  ( cd "$W" && tar -c --exclude=.git . ) | tar -x -C "$BASE/fmroot"
  git -C "$BASE/fmroot" init -q
  printf 'max_trees = 4\nroot = "%s/pool"\n' "$BASE" > "$BASE/fmroot/treehouse.toml"
  git -C "$BASE/fmroot" add -A >/dev/null
  git -C "$BASE/fmroot" -c user.name=live -c user.email=live@example.invalid commit -qm live >/dev/null
  export FM_GATE_REFUSE_BYPASS=1
  export FM_ROOT_OVERRIDE="$BASE/fmroot"
  export FM_HOME="$BASE/lab"
  export FM_BACKEND=tmux
  export TMUX_TMPDIR="$BASE/tmux"
  unset NO_MISTAKES_GATE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
  LAB="$BASE/lab"
  STATE="$LAB/state"
  POOL_STATE="$BASE/pool/.treehouse/$(basename "$BASE/fmroot")-"*"/treehouse-state.json"
}

pool_dir() { find "$BASE/pool/.treehouse" -maxdepth 1 -mindepth 1 -type d | head -1; }
pool_json() { printf '%s/treehouse-state.json\n' "$(pool_dir)"; }
pool_entry() { python3 - "$(pool_json)" "$1" <<'PY'
import json, os, sys
state, home = sys.argv[1:]
entries = json.load(open(state))["worktrees"]
match = [e for e in entries if os.path.realpath(e["path"]) == os.path.realpath(home)]
print(json.dumps(match[0] if match else None, indent=1))
PY
}
seed_live() {  # <id>  -> prints the seeded home path
  local id=$1 out
  out=$( cd "$W" && env FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$FM_ROOT_OVERRIDE" FM_HOME="$LAB" \
    FM_SECONDMATE_CHARTER="live domain $id" FM_SECONDMATE_SCOPE="live domain $id" \
    bash bin/fm-home-seed.sh "$id" - --no-projects 2>&1 ) || { printf '%s\n' "$out"; return 1; }
  printf '%s\n' "$out" >&2
  printf '%s\n' "$out" | sed -n 's/^home=//p' | tail -1
}

seed_explicit_path() {  # <id> <path> -> seeds an existing checkout (unleased pool entry)
  local id=$1 path=$2 out
  out=$( cd "$W" && env FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$FM_ROOT_OVERRIDE" FM_HOME="$LAB" \
    FM_SECONDMATE_CHARTER="live domain $id" FM_SECONDMATE_SCOPE="live domain $id" \
    bash bin/fm-home-seed.sh "$id" "$path" --no-projects 2>&1 ) || { printf '%s\n' "$out"; return 1; }
  printf '%s\n' "$out" >&2
  printf '%s\n' "$out" | sed -n 's/^home=//p' | tail -1
}

write_meta() {  # <id> <home>
  cat > "$STATE/$1.meta" <<EOF
window=firstmate:fm-$1
endpoint_task_id=$1
worktree=$2
project=$2
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$2
projects=alpha
EOF
  printf '%s\n' "- $1 - live mate (home: $2; scope: live domain $1; projects: alpha; added 2026-11-10)" \
    > "$LAB/data/secondmates.md"
}

tmux_up() {  # <id>
  tmux new-session -d -s firstmate -n "fm-$1" 2>/dev/null || true
}

teardown_live() {  # <id> [extra args...]
  local id=$1
  shift
  ( cd "$W" && env FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$FM_ROOT_OVERRIDE" FM_HOME="$LAB" \
    FM_BACKEND=tmux TMUX_TMPDIR="$BASE/tmux" bash bin/fm-teardown.sh "$id" "$@" )
}

# A PATH shim that only delays the real `treehouse return`, so a signal can be
# delivered while the return is in flight. It never replaces pool behaviour.
make_slow_treehouse() {  # <delay-seconds>
  mkdir -p "$BASE/shim"
  cat > "$BASE/shim/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = return ]; then sleep "$1"; fi
exec "$REAL_TREEHOUSE" "\$@"
SH
  chmod +x "$BASE/shim/treehouse"
}

children_of() { ps -o pid= --ppid "$1" 2>/dev/null | tr -d ' '; }

descendants_of() {  # all descendant pids, deepest last
  local pid=$1 child
  for child in $(children_of "$pid"); do
    printf '%s\n' "$child"
    descendants_of "$child"
  done
}

wait_for_staging() {  # <seconds>
  local deadline=$((SECONDS + $1))
  while [ "$SECONDS" -lt "$deadline" ]; do
    set -- "$LAB"/state/.home-return.*
    [ -e "$1" ] && { printf '%s\n' "$1"; return 0; }
    sleep 0.02
  done
  return 1
}

staging_dirs() {
  local s
  for s in "$LAB"/state/.home-return.*; do [ -d "$s" ] && printf '%s\n' "$s"; done
}

home_intact() {  # <home> <id>
  [ -f "$1/data/charter.md" ] && [ "$(cat "$1/.fm-secondmate-home" 2>/dev/null)" = "$2" ] \
    && present "$(git -C "$1" rev-parse --absolute-git-dir)/locked"
}

home_retired_payload() {  # <home> - payload/markers/protection all gone
  local p
  for p in data state config projects .fm-secondmate-home .fm-secondmate-parent; do
    absent "$1/$p" || return 1
  done
  local gd
  gd=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  absent "$gd/locked" && absent "$gd/firstmate-home-lock"
}

teardown_world() {
  [ -n "${BASE:-}" ] || return 0
  tmux kill-server 2>/dev/null || true
  for pid in $(pgrep -f "$BASE" 2>/dev/null); do kill -KILL "$pid" 2>/dev/null || true; done
  # Return any still-leased slot through the real pool so nothing outlives the run.
  local home
  for home in $(find "$BASE/pool" -maxdepth 4 -mindepth 4 -type d 2>/dev/null); do
    ( cd "$BASE/fmroot" && "$REAL_TREEHOUSE" return --force "$home" >/dev/null 2>&1 ) || true
  done
  rm -rf -- "$BASE"
  BASE=
}
