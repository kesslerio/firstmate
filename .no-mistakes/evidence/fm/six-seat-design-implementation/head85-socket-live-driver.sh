#!/usr/bin/env bash
set -euo pipefail
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
R=$PWD
E=/home/art/.no-mistakes/evidence/01M4EGNATFWY186FV48C2W9EBR
H=$R/.test-labs/home
A=$R/.test-labs/a
B=$R/.test-labs/b
cleanup() { tmux -S "$A" kill-server 2>/dev/null || true; tmux -S "$B" kill-server 2>/dev/null || true; rm -rf "$H" "$R/.test-labs/mate"; }
trap cleanup EXIT
bin/fm-lab-home.sh create "$H"
export FM_HOME=$H
printf '{"pools":[{"name":"shared","capacity":1,"models":["pool-model-a"]}]}\n' > "$H/config/fleet-seats"
tmux -f /dev/null -S "$A" new-session -d -x 120 -y 40 -s firstmate -n fm-sm1 -c "$R" 'exec bash --noprofile --norc'
tmux -f /dev/null -S "$B" new-session -d -x 120 -y 40 -s firstmate -n fm-sm1 -c "$R" 'exec bash --noprofile --norc'
export TMUX="$A,0,0"
S=$R/bin/fm-fleet-seats.sh

printf '{"placement":"local","backend":"tmux","target":"firstmate:fm-sm1","spawn_gen":"g1"}\n' > "$H/route"
chmod 600 "$H/route"
bash -c '"$1" reserve sm1 --generation g1 --kind secondmate --harness claude --model pool-model-a --holder-pid "$$" && "$1" dispatch sm1 --generation g1 --route-file "$2"; rc=$?; exit "$rc"' _ "$S" "$H/route"
printf 'kind=secondmate\nharness=claude\nmodel=pool-model-a\nbackend=tmux\nwindow=firstmate:fm-sm1\nspawn_gen=g1\nhome=%s\nworktree=%s\nproject=%s\n' "$R/.test-labs/mate" "$R/.test-labs/mate" "$R/.test-labs/mate" > "$H/state/sm1.meta"
set +e
"$S" reclaim sm1 --generation g1
rc=$?
set -e
[ "$rc" = 3 ]
[ "$("$S" show sm1 | jq -r '.incarnations[0].lifecycle')" = reserved ]
echo 'Observed: shell-only dispatched launch remains reserved; reclaim refused.'
# Seed persisted prior-startup state for an already-exited generation. The
# running endpoints remain real shell panes; no harness CLI is substituted.
for holder in "$H/state/fleet-seats/holders/"*.json; do
  jq '.incarnations[0] |= (.lifecycle="confirmed" | .launch_phase="started" | .startup_confirmed=true)' "$holder" > "$holder.new"
  mv "$holder.new" "$holder"
done
echo 'Fixture: g1 previously confirmed; current runtime is the real exited-agent shell on A.'
export TMUX="$B,0,0" FM_ROOT=$R STATE=$H/state CONFIG=$H/config DATA=$H/data
. bin/fm-secondmate-liveness-lib.sh
for holder in "$H/state/fleet-seats/holders/"*.json; do
 cp "$holder" "$H/saved-holder"
 for socket in relative/socket ""; do
  jq --arg s "$socket" '.incarnations[0].route.socket_path=$s' "$H/saved-holder" > "$holder"
  fm_secondmate_liveness_probe "$STATE/sm1.meta" sm1 poll
  [ "$FM_SM_LIVE_STATUS" = skipped ]
  printf 'Denied socket=%s status=%s reason=%s\n' "$socket" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_REASON"
  tmux -S "$A" has-session -t firstmate
  tmux -S "$B" has-session -t firstmate
  [ "$("$S" show sm1 | jq -r '.incarnations[0].lifecycle')" = confirmed ]
 done
 cp "$H/saved-holder" "$holder"
done
fm_secondmate_liveness_lock sm1
fm_secondmate_liveness_probe "$STATE/sm1.meta" sm1 poll
printf 'Recovery probe from B: status=%s state=%s socket=%s target=%s\n' "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE" "$FM_SM_LIVE_SOCKET" "$FM_SM_LIVE_TARGET"
[ "$FM_SM_LIVE_STATUS" = relaunchable ]
lock="$STATE/.secondmate-relaunch.lock"
bash -c '. "$1" && fm_lock_try_acquire "$2" && exec sleep 60' _ "$R/bin/fm-wake-lib.sh" "$lock" &
lock_owner=$!
for i in $(seq 1 100); do [ ! -f "$lock/pid" ] || break; sleep 0.02; done
[ -f "$lock/pid" ]
set +e
fm_secondmate_liveness_relaunch "$STATE/sm1.meta" sm1 1
rc=$?
set -e
kill "$lock_owner"
wait "$lock_owner" 2>/dev/null || true
[ "$rc" != 0 ]
[ "$("$S" show sm1 | jq -r '.incarnations[0].lifecycle')" = reclaimed ]
tmux -S "$A" has-session -t firstmate
printf 'Timeout retained endpoint A after reclamation: rc=%s reason=%s\n' "$rc" "$FM_SM_LIVE_REASON"
fm_secondmate_liveness_probe "$STATE/sm1.meta" sm1 poll
[ "$FM_SM_LIVE_STATUS" = relaunchable ]
echo 'Terminal-generation retry resolved its recorded socket A from ambient B.'
# A missing home prevents replacement; this check specifically exercises both
# probes, reclamation, and endpoint close without launching a second agent.
set +e
fm_secondmate_liveness_relaunch "$STATE/sm1.meta" sm1
rc=$?
set -e
printf 'Replacement launch result=%s reason=%s output=%s\n' "$rc" "$FM_SM_LIVE_REASON" "$FM_SM_LIVE_OUT"
fm_secondmate_liveness_unlock sm1
[ "$("$S" show sm1 | jq -r '.incarnations[0].lifecycle')" = reclaimed ]
! tmux -S "$A" has-session -t firstmate 2>/dev/null
tmux -S "$B" display-message -p -t firstmate:fm-sm1 'Decoy on B survives: pane=#{pane_id} dead=#{pane_dead} command=#{pane_current_command}'
echo 'Observed: recovery reclaimed g1, closed the shell on A, and preserved the identically named unrelated window on B.'
