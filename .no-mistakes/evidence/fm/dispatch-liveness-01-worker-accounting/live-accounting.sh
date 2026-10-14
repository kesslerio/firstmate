#!/usr/bin/env bash
set -euo pipefail
root=$PWD
home="$root/.test-phase/live-home"
mkdir -p "$home"/{state,config,data,projects}
export FM_HOME="$home" HERDR_CONFIG_PATH="$root/.test-phase/herdr/config.toml" FM_HERDR_LAB_STATE_DIR="$root/.test-phase/lab-local"
export FM_CREW_STATE_NO_FORGE=1 FM_GUARD_READ_ONLY=1
export GH_CONFIG_DIR="$home/gh-config"
unset GH_TOKEN GITHUB_TOKEN
mkdir -p "$home/worktree" "$GH_CONFIG_DIR"
. bin/fm-liveness-lib.sh
snapshot() {
  fm_liveness_snapshot "$home"
  printf 'snapshot target=%s live=%s free=%s over=%s\n%s%s' "$FM_LIVENESS_TARGET" "$FM_LIVENESS_LIVE" "$FM_LIVENESS_FREE" "$FM_LIVENESS_OVER_TARGET" "$FM_LIVENESS_LANES" "$FM_LIVENESS_WARNINGS"
}
for id in active paused done failed codex invalid; do
  cat > "$home/state/$id.meta" <<EOF
worktree=$home/worktree
kind=ship
mode=direct-PR
harness=claude
backend=herdr
window=<owned-lab-21>
herdr_session=<owned-lab-20>
herdr_workspace_id=w1
herdr_tab_id=w1:t1
herdr_pane_id=w1:p1
EOF
  busy=idle; [ "$id" != active ] || busy=busy
  bin/fm-busy-event.sh arm "$home/state" "$id" --state "$busy" --source claude-hook --event stop >/dev/null
  printf '%s: local task state\n' "$id" > "$home/state/$id.status"
done
printf 'done: predecessor terminal event\n' > "$home/state/active.status"
printf 'kind=scout\n' >> "$home/state/paused.meta"
printf 'worktree=%s\nharness=codex\n' "$home/worktree" > "$home/state/codex.meta"
printf 'kind=ship\nbackend=herdr\nwindow=<owned-lab-21>\nmode=direct-PR\n' >> "$home/state/codex.meta"
printf 'pr=https://github.com/example/project/pull/7\npr=https://github.com/example/project/pull/7\n' >> "$home/state/invalid.meta"
printf 'kind=secondmate\n' > "$home/state/mate.meta"
printf 'working: orphan event\n' > "$home/state/orphan.status"
checksum() { find "$home" -type f -exec cksum {} \; | sort; }
before=$(checksum)
snapshot
[ "$FM_LIVENESS_LIVE" = 4 ]
[[ "$FM_LIVENESS_LANES" == *$'active\tship\tworking\t'* ]]
[[ "$FM_LIVENESS_LANES" == *$'paused\tscout\tpaused\t'* ]]
[[ "$FM_LIVENESS_LANES" == *$'codex\tship\tunknown\t'* ]]
[ "$before" = "$(checksum)" ]
printf 'read-only snapshot preserved all home file bytes\n'
old=$(cat "$home/state/active.busy-gen")
bin/fm-busy-event.sh arm "$home/state" active --state busy --source claude-hook --event user-prompt-submit >/dev/null
if bin/fm-busy-event.sh apply "$home/state" active idle --gen "$old" --source claude-hook --event stop; then exit 1; fi
snapshot
[ "$FM_LIVENESS_LIVE" = 4 ]
printf 'stale generation refused; current active seat retained\n'
printf 'spawn_gen=s%s.123.456\n' "$(date +%s)" >> "$home/state/active.meta"
bin/fm-pr-check.sh active https://github.com/example/project/pull/8
snapshot
[ "$FM_LIVENESS_LIVE" = 3 ]
printf 'spawn_gen=s%s.123.457\n' "$(date +%s)" > "$home/state/newgen"
sed '/^spawn_gen=/d' "$home/state/active.meta" > "$home/state/updated"
cat "$home/state/newgen" >> "$home/state/updated"
mv "$home/state/updated" "$home/state/active.meta"
rm "$home/state/newgen"
snapshot
[ "$FM_LIVENESS_LIVE" = 4 ]
bin/fm-pr-check.sh active https://github.com/example/project/pull/8
snapshot
[ "$FM_LIVENESS_LIVE" = 3 ]
printf 'fresh current handoff releases seat; predecessor handoff did not\n'
for value in 0 01 -1 9223372036854775808 '4 5'; do
  printf '%s\n' "$value" > "$home/config/worker-target"
  if fm_liveness_snapshot "$home"; then exit 1; fi
  printf 'target %s refused: %s\n' "$value" "$FM_LIVENESS_ERROR"
  [ "$FM_LIVENESS_FREE" = 0 ]
done
rm "$home/config/worker-target"
ln -s "$home/missing" "$home/config/worker-target"
if fm_liveness_snapshot "$home"; then exit 1; fi
printf 'dangling target refused: %s\n' "$FM_LIVENESS_ERROR"
rm "$home/config/worker-target"
printf '2\n' > "$home/config/worker-target"
snapshot
[ "$FM_LIVENESS_OVER_TARGET" = 1 ]
printf '0\n' > "$home/config/worker-target"
bin/fm-afk-return.sh check || [ "$?" = 4 ]
rm "$home/config/worker-target"
bin/fm-afk-return.sh check || [ "$?" = 4 ]
printf 'parent_home=%s\n' "$home" > "$home/.fm-secondmate-home"
snapshot
[ "$FM_LIVENESS_TARGET" = 6 ]
printf 'ALL LIVE LOCAL ACCOUNTING CHECKS PASSED\n'
