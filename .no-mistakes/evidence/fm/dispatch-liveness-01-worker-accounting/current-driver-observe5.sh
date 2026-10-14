set -euo pipefail
root=$PWD
owned="$root/.test-phase/observe-lab5"
home="$owned/home"
mkdir -p "$owned/herdr" "$owned/lab-state" "$home"/{state,data,config,worktree}
cp .test-phase/herdr/config.toml "$owned/herdr/config.toml"
export FM_HOME="$home" FM_GUARD_READ_ONLY=1 FM_CREW_STATE_NO_FORGE=1 HERDR_CONFIG_PATH="$owned/herdr/config.toml" FM_HERDR_LAB_STATE_DIR="$owned/lab-state"
helper="$root/bin/fm-herdr-lab.sh"
session=$("$helper" name observations)
case "$home:$session" in "$root/.test-phase/observe-lab5/home:fm-lab-"*) ;; *) exit 98;; esac
. tests/herdr-test-safety.sh
herdr_forget_inherited_pane
export HERDR_SESSION="$session"
trap '"$helper" teardown "$session"' EXIT
"$helper" provision "$session"
json=$("$helper" run "$session" workspace create --cwd "$home/worktree" --label observation --no-focus)
pane=$(jq -r .result.root_pane.pane_id <<< "$json")
workspace=$(jq -r .result.workspace.workspace_id <<< "$json")
log="$home/native-sessions/$(date +%Y/%m/%d)/first/session.jsonl"
mkdir -p "${log%/*}"
printf '{"schema_version":1,"payload_type":"runtime.session.metadata","payload":{"kind":"metadata","record":{"workspace_root":"%s"}}}\n' "$home/worktree" > "$log"
printf '{"schema_version":1,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"local-run","event":{"kind":"started"}}}\n' >> "$log"
cat > "$home/state/muse.meta" <<EOF
kind=ship
mode=direct-PR
harness=muse
backend=herdr
window=$session:$pane
herdr_session=$session
herdr_workspace_id=$workspace
herdr_pane_id=$pane
worktree=$home/worktree
EOF
printf 'sessions_root=%s\nworkspace_root=%s\nbinding_id=local-incarnation\n' "$home/native-sessions" "$home/worktree" > "$home/state/muse.muse-session"
. bin/fm-busy-lib.sh
cache="$home/state/muse.muse-session-current"
for variant in missing stale valid; do
 case "$variant" in missing) [ ! -e "$cache" ];; stale) printf 'binding_id=foreign\nsession_log=untrusted\n' > "$cache";; valid) FM_BUSY_CACHE_READ_ONLY=0 fm_busy_muse_session_log "$home/state" muse;; esac
 before=$(find "$home" -type f -exec cksum {} \; | sort)
 out=$(bin/fm-crew-state.sh muse)
 printf '%s cache: %s\n' "$variant" "$out"
 [[ "$out" == 'state: working'* ]]
 [ "$before" = "$(find "$home" -type f -exec cksum {} \; | sort)" ]
done
mkdir -p "${log%/*}/../second"
cp "$log" "${log%/*}/../second/session.jsonl"
before=$(find "$home" -type f -exec cksum {} \; | sort)
out=$(bin/fm-crew-state.sh muse)
printf 'ambiguous native sessions: %s\n' "$out"
[[ "$out" == 'state: unknown'* ]]
[ "$before" = "$(find "$home" -type f -exec cksum {} \; | sort)" ]
rm "${log%/*}/../second/session.jsonl"
printf '{"schema_version":1,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"local-run","event":{"kind":"terminal","terminal":"completed"}}}\n' >> "$log"
cp "$home/state/muse.meta" "$home/state/paused.meta"
printf 'kind=scout\n' >> "$home/state/paused.meta"
# Each task uses its own native binding; the external log is a disposable dataset.
cp "$home/state/muse.muse-session" "$home/state/paused.muse-session"
printf 'paused: external wait\n' > "$home/state/paused.status"
printf 'kind=secondmate\n' > "$home/state/mate.meta"
printf 'working: orphan event\n' > "$home/state/orphan.status"
printf 'pr=https://github.com/example/fixture/pull/7\npr=https://github.com/example/fixture/pull/7\n' >> "$home/state/muse.meta"
. bin/fm-liveness-lib.sh
fm_liveness_snapshot "$home"
printf 'snapshot live=%s target=%s free=%s\n%s%s' "$FM_LIVENESS_LIVE" "$FM_LIVENESS_TARGET" "$FM_LIVENESS_FREE" "$FM_LIVENESS_LANES" "$FM_LIVENESS_WARNINGS"
[ "$FM_LIVENESS_LIVE" = 2 ]
[[ "$FM_LIVENESS_LANES" == *$'paused\tscout\tpaused\t'* ]]
set +e
bin/fm-afk-return.sh check
rc=$?
set -e
printf "return check exit=%s (catch-up blocked)\n" "$rc"
[ "$rc" = 3 ]
printf '0\n' > "$home/config/worker-target"
set +e
bin/fm-afk-return.sh check
rc=$?
set -e
printf "invalid observation return exit=%s\n" "$rc"
[ "$rc" = 3 ]
rm "$home/config/worker-target"
original=$PATH
mkdir -p "$owned/slow-bin"
cat > "$owned/slow-bin/herdr" <<EOF
#!/usr/bin/env bash
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[n-2]}" = --session ]; then
  [ "\${args[n-1]}" = '$session' ] || exit 98
  args=("\${args[@]:0:n-2}")
fi
sleep 12
exec env PATH='$original' '$helper' run '$session' "\${args[@]}"
EOF
chmod +x "$owned/slow-bin/herdr"
start=$(date +%s)
PATH="$owned/slow-bin:$original" fm_liveness_snapshot "$home"
elapsed=$(( $(date +%s)-start ))
printf 'slow actual-backend read live=%s elapsed=%s warnings=%s\n' "$FM_LIVENESS_LIVE" "$elapsed" "$FM_LIVENESS_WARNINGS"
[ "$FM_LIVENESS_LIVE" = 2 ] && [ "$elapsed" -le 25 ]
[[ "$FM_LIVENESS_WARNINGS" == *'paused: current state unknown; seat retained'* ]]
printf 'Read-only native dataset, paused scout, bounded failed reads, uncertainty and AFK-return verified\n' 
