#!/usr/bin/env bash
# Live-primary ready-work drive for the lab stood up by bin/fm-live-lab.sh.
# Queues a dependency-clear ship unit in the lab home's own backlog, forces a
# heartbeat, and observes the real chain: watcher heartbeat -> supervision host
# branch turn -> durable captain handoff -> MAIN's drain -> MAIN's dispatch.
# Only fixture setup and observation happen here; every step in the chain is a
# real firstmate script or a real Claude session inside the disposable lab.
set -u

LAB=${1:?usage: drive-ready-work.sh <lab-root>}
EV=/home/art/.no-mistakes/evidence/01M68DFDPBY58KJMCHPEQ7GB3W
HOMEDIR="$LAB/home"
ID=lab-ready-9c1
TD=$(sed -n 's/^tmux_dir=//p' "$LAB/.fm-live-lab")

labsh() {  # <script> [args...]
  local s=$1
  shift
  ( cd "$HOMEDIR" && env -u TMUX -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
      -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TASKS_AXI_FILE \
      -u TASKS_AXI_BACKEND -u CLAUDECODE FM_HOME="$HOMEDIR" "$HOMEDIR/bin/$s" "$@" )
}

pane() { env -u TMUX TMUX_TMPDIR="$TD" tmux capture-pane -p -J -t firstmate:main -S -300; }

{
  echo "== before: backlog"
  cat "$HOMEDIR/data/backlog.md"
  echo "== before: outcomes"
  cat "$HOMEDIR/state/branch-outcomes.jsonl" 2>/dev/null
  echo "== before: workers"
  ls "$HOMEDIR/state"/*.meta 2>/dev/null
} > "$EV/live-primary-before.txt"

labsh fm-brief.sh "$ID" notes --mode local-only >/dev/null || { echo "brief failed"; exit 1; }
python3 - "$HOMEDIR/data/$ID/brief.md" <<'PY' || exit 1
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
t = t.replace("{TASK}", "Add subtract(a, b) to notes/__init__.py with a unit test in tests/test_notes.py, run python3 -m unittest discover -s tests, commit, then report done. Nothing else is in scope.", 1)
t = t.replace("{FIRSTMATE_SPEC}", "Implement and verify subtract(a, b) exactly as the task says; run the unit tests before reporting.", 1)
open(p, "w", encoding="utf-8").write(t)
PY
labsh fm-tasks-axi.sh add "$ID" 'Add a subtract helper to the notes library' --kind ship --repo notes >/dev/null || { echo "add failed"; exit 1; }

echo "== queued ready work:"
labsh fm-tasks-axi.sh ready
echo "== forcing a heartbeat (backdating .last-heartbeat)"
touch -d '-2 hours' "$HOMEDIR/state/.last-heartbeat" 2>/dev/null || touch -t 200001010000 "$HOMEDIR/state/.last-heartbeat"

handoff=0
spawned=0
start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt 600 ]; do
  if [ "$handoff" -eq 0 ] && jq -e --arg id "$ID" -s 'any(.[]; .verdict=="captain" and (.summary|test($id)))' \
      "$HOMEDIR/state/branch-outcomes.jsonl" >/dev/null 2>&1; then
    handoff=1
    echo "== durable captain handoff recorded at +$(( $(date +%s) - start ))s"
    jq --arg id "$ID" -c 'select(.verdict=="captain" and (.summary|test($id)))' "$HOMEDIR/state/branch-outcomes.jsonl"
  fi
  if [ -e "$HOMEDIR/state/$ID.meta" ]; then
    spawned=1
    echo "== MAIN dispatched a worker at +$(( $(date +%s) - start ))s"
    cat "$HOMEDIR/state/$ID.meta"
    break
  fi
  if [ "$handoff" -eq 1 ] && [ $(( $(date +%s) - start )) -gt 300 ]; then
    break
  fi
  sleep 5
done

echo "== after: ready"
labsh fm-tasks-axi.sh ready
echo "== after: show unit"
labsh fm-tasks-axi.sh show "$ID" --full
echo "== after: outcomes"
cat "$HOMEDIR/state/branch-outcomes.jsonl" 2>/dev/null
echo "== after: workers"
ls "$HOMEDIR/state"/*.meta 2>/dev/null
echo "== main pane"
pane
echo "== host log tail"
tail -20 "$HOMEDIR/state/.supervision-host.log" 2>/dev/null
echo "SUMMARY handoff=$handoff spawned=$spawned"
