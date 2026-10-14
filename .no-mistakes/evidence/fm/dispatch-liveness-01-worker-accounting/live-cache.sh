set -euo pipefail
home="$PWD/.test-phase/live-home"
export FM_HOME="$home" HERDR_CONFIG_PATH="$PWD/.test-phase/herdr/config.toml" FM_CREW_STATE_NO_FORGE=1
sessions="$home/native-sessions"
log="$sessions/$(date +%Y/%m/%d)/local-session/session.jsonl"
mkdir -p "${log%/*}"
printf '{"schema_version":1,"payload_type":"runtime.session.metadata","payload":{"kind":"metadata","record":{"workspace_root":"%s"}}}\n' "$home/worktree" > "$log"
printf '{"schema_version":1,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"local-run","event":{"kind":"started"}}}\n' >> "$log"
cat > "$home/state/muse.meta" <<EOF
kind=ship
mode=direct-PR
harness=muse
backend=herdr
window=<owned-lab-21>
worktree=$home/worktree
EOF
printf 'sessions_root=%s\nworkspace_root=%s\nbinding_id=local-incarnation\n' "$sessions" "$home/worktree" > "$home/state/muse.muse-session"
cache="$home/state/muse.muse-session-current"
. bin/fm-busy-lib.sh
for variant in missing stale valid; do
 case "$variant" in
 missing) [ ! -e "$cache" ] ;;
 stale) printf 'binding_id=foreign\nsession_log=untrusted\n' > "$cache" ;;
 valid) FM_BUSY_CACHE_READ_ONLY=0 fm_busy_muse_session_log "$home/state" muse ;;
 esac
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
printf 'ambiguous log: %s\n' "$out"
[[ "$out" == 'state: unknown'* ]]
[ "$before" = "$(find "$home" -type f -exec cksum {} \; | sort)" ]
printf 'native cache observation preserved all files; direct owner maintenance still works\n'
