#!/usr/bin/env bash
# Live drive of the ready-queue / outcome-preservation change at head 0e3c94fa.
# Every step runs the product's own binaries (fm-watch.sh, fm-tasks-axi.sh,
# fm-wake-drain.sh, fm-bootstrap.sh, fm-branch-outcome.sh) against a marked,
# disposable fm-lab-* home, and removes every lab in the same turn.
set -u
ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M6CPKT1A9G7ANE7A4B33H9PY
EVIDENCE=/home/art/.no-mistakes/evidence/01M6CPKT1A9G7ANE7A4B33H9PY
LABS=()

cleanup() {
  local lab
  for lab in "${LABS[@]}"; do
    [ -d "$lab/tmux" ] && TMUX_TMPDIR="$lab/tmux" tmux -L fm-lab kill-server 2>/dev/null
    "$ROOT/bin/fm-lab-home.sh" teardown "$lab/home" >/dev/null 2>&1
    rm -rf "$lab"
  done
}
trap cleanup EXIT

# Fleet-path overrides and the gate marker never leak into the fixture.
unset_env=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
  -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  -u FM_SUPERVISION_ACTOR -u TMUX -u TMUX_PANE)

new_lab() {
  local lab
  lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
  mkdir -p "$lab/tmux" || exit 1
  "$ROOT/bin/fm-lab-home.sh" create "$lab/home" >/dev/null || exit 1
  cat > "$lab/home/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$lab/home/data/backlog.md"
  LABS+=("$lab")
  printf '%s\n' "$lab"
}

banner() { printf '\n=== %s ===\n' "$*"; }

# ---------------------------------------------------------------- S1 (ready)
banner "S1 ready queued work escalates instead of being absorbed"
lab=$(new_lab)
lab_home=$lab/home
"${unset_env[@]}" FM_HOME="$lab_home" "$ROOT/bin/fm-tasks-axi.sh" add dependency 'landed dependency' >/dev/null
"${unset_env[@]}" FM_HOME="$lab_home" "$ROOT/bin/fm-tasks-axi.sh" add unit-next 'ready queued unit' >/dev/null
"${unset_env[@]}" FM_HOME="$lab_home" "$ROOT/bin/fm-tasks-axi.sh" block unit-next --by dependency >/dev/null
"${unset_env[@]}" FM_HOME="$lab_home" "$ROOT/bin/fm-tasks-axi.sh" 'done' dependency \
  --pr https://github.com/example/fixture/pull/1 >/dev/null
echo "--- real backlog consumer: ready + queued"
"${unset_env[@]}" FM_HOME="$lab_home" "$ROOT/bin/fm-tasks-axi.sh" ready | sed -n '1,3p'
"${unset_env[@]}" FM_HOME="$lab_home" "$ROOT/bin/fm-tasks-axi.sh" list --state queued | sed -n '1,3p'
echo "--- real watcher process (FM_HEARTBEAT=1, FM_CHECK_INTERVAL=999999, no status events, no live worker)"
out=$(cd "$ROOT" && "${unset_env[@]}" FM_HOME="$lab_home" FM_POLL=0.2 FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=1 TMUX_TMPDIR="$lab/tmux" timeout 60 "$ROOT/bin/fm-watch.sh")
echo "watcher stdout: $out"
echo "durable wake queue: $(cat "$lab_home/state/.wake-queue" 2>/dev/null | tr '\t' ' ')"
echo "--- real drain of that wake"
(cd "$ROOT" && "${unset_env[@]}" FM_HOME="$lab_home" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null | sed -n '1,12p')
[ "$out" = heartbeat ] || { echo "S1 FAILED: watcher absorbed the ready queue"; exit 1; }
grep -q $'\theartbeat\t' "$lab_home/state/.wake-queue" || { echo "S1 FAILED: no durable wake"; exit 1; }
echo "S1 PASS"

# ---------------------------------------------------------------- S2 (empty)
banner "S2 empty queue stays quiet (no unnecessary dispatch wake)"
lab=$(new_lab)
lab_home=$lab/home
out="$lab/watch.out"
(cd "$ROOT" && "${unset_env[@]}" FM_HOME="$lab_home" FM_POLL=0.2 FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=1 TMUX_TMPDIR="$lab/tmux" "$ROOT/bin/fm-watch.sh" > "$out" 2>&1) &
pid=$!
for _ in $(seq 1 60); do
  [ "$(cat "$lab_home/state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] && break
  sleep 0.1
done
kill -TERM "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
echo "heartbeat streak: $(cat "$lab_home/state/.heartbeat-streak" 2>/dev/null || echo 0)"
echo "watcher stdout (empty expected): '$(cat "$out")'"
echo "wake queue present: $( [ -e "$lab_home/state/.wake-queue" ] && echo yes || echo no )"
[ ! -s "$out" ] && [ ! -s "$lab_home/state/.wake-queue" ] || { echo "S2 FAILED: empty queue woke firstmate"; exit 1; }
echo "S2 PASS"

# ------------------------------------------------------- S3 (unreadable)
banner "S3 unreadable readiness escalates rather than reading as an empty queue"
lab=$(new_lab)
lab_home=$lab/home
printf 'backend = "not-a-real-backend"\n' > "$lab_home/.tasks.toml"
echo "--- real backlog consumer fails on the misconfigured backend:"
"${unset_env[@]}" FM_HOME="$lab_home" "$ROOT/bin/fm-tasks-axi.sh" ready 2>&1 | sed -n '1,3p'
echo "rc=$?"
out=$(cd "$ROOT" && "${unset_env[@]}" FM_HOME="$lab_home" FM_POLL=0.2 FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=1 TMUX_TMPDIR="$lab/tmux" timeout 60 "$ROOT/bin/fm-watch.sh")
echo "watcher stdout: $out"
[ "$out" = heartbeat ] || { echo "S3 FAILED: unreadable readiness was absorbed"; exit 1; }
echo "S3 PASS"

# ------------------------------------------------- S4 (unconfirmed start)
banner "S4 an unconfirmed start stays off the queue-drop path (bootstrap heal)"
lab=$(new_lab)
lab_home=$lab/home
"${unset_env[@]}" FM_HOME="$lab_home" "$ROOT/bin/fm-tasks-axi.sh" add unit-start 'unconfirmed start' >/dev/null
printf 'project=demo\nwindow=fm-demo\nharness=claude\n' > "$lab_home/state/unit-start.meta"
echo "--- backlog row before bootstrap: $("${unset_env[@]}" FM_HOME="$lab_home" "$ROOT/bin/fm-tasks-axi.sh" show unit-start | awk '/state:/ {print $2}')"
echo "--- real bootstrap run (FM_BOOTSTRAP_NETWORK=skip), backlog reconcile sweep:"
(cd "$ROOT" && "${unset_env[@]}" FM_HOME="$lab_home" FM_BOOTSTRAP_NETWORK=skip \
  timeout 180 "$ROOT/bin/fm-bootstrap.sh" 2>&1 | grep -E 'BOOTSTRAP_INFO|BACKLOG_RECONCILE' || true)
state=$("${unset_env[@]}" FM_HOME="$lab_home" "$ROOT/bin/fm-tasks-axi.sh" show unit-start | awk '/state:/ {print $2}')
echo "--- backlog row after bootstrap: $state"
echo "--- ready count after bootstrap (a reopen would drop the unit here without a confirmed starter):"
"${unset_env[@]}" FM_HOME="$lab_home" "$ROOT/bin/fm-tasks-axi.sh" ready | sed -n '1p'
[ "$state" = in_flight ] || { echo "S4 FAILED: a queued row paired with an owned worker record was left queued"; exit 1; }
echo "S4 PASS"

# --------------------------------------- S5 (unprocessed captain outcomes)
banner "S5 every unprocessed captain outcome and its ready-work handoff stays visible"
lab=$(new_lab)
lab_home=$lab/home
: > "$lab_home/config/supervision-host"
fakebin="$lab/fakebin"; mkdir -p "$fakebin"
ln -s "$(command -v bash)" "$fakebin/claude"
"${unset_env[@]}" FM_HOME="$lab_home" "$ROOT/bin/fm-branch-outcome.sh" append --task source --verdict captain \
  --summary 'ready-work handoff: dispatch unit-next; its dependency landed' >/dev/null
"${unset_env[@]}" FM_HOME="$lab_home" "$ROOT/bin/fm-branch-outcome.sh" append --task source --verdict captain \
  --summary 'source task finished; no new handoff' >/dev/null
echo "--- first real drain (MAIN):"
first=$(cd "$ROOT" && "${unset_env[@]}" PATH="$fakebin:$PATH" FM_HOME="$lab_home" \
  "$fakebin/claude" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
printf '%s\n' "$first" | sed -n '1,12p'
printf '%s\n' "$first" | grep -q 'ready-work handoff: dispatch unit-next' \
  || { echo "S5 FAILED: the newer summary hid the older ready-work handoff"; exit 1; }
printf '%s\n' "$first" | grep -q 'source task finished; no new handoff' \
  || { echo "S5 FAILED: the newer outcome was not presented"; exit 1; }
target=$(printf '%s\n' "$first" | sed -n 's/.*mark-processed --through \([0-9]*\);.*/\1/p' | head -1)
echo "--- presented acknowledgement target: through $target"
echo "--- unprocessed after presentation: $("${unset_env[@]}" FM_HOME="$lab_home" "$ROOT/bin/fm-branch-outcome.sh" unprocessed | tr '\n' ' ')"
"${unset_env[@]}" FM_HOME="$lab_home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through "$target" >/dev/null
second=$(cd "$ROOT" && "${unset_env[@]}" PATH="$fakebin:$PATH" FM_HOME="$lab_home" \
  "$fakebin/claude" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
echo "--- drain after acknowledgement (handoff must not repeat):"
printf '%s\n' "$second" | sed -n '1,8p'
printf '%s\n' "$second" | grep -q 'dispatch unit-next' && { echo "S5 FAILED: an acknowledged handoff repeated"; exit 1; }
echo "S5 PASS"
