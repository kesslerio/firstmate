#!/usr/bin/env bash
set -eu
E=/out
. "$PWD/tests/fixtures.sh"
LAB=$(mktemp -d /tmp/l.XXXXXX)
bash bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/agent" "$LAB/user-home"
server_pid='' watch_pid=''
cleanup() {
  [ -z "$watch_pid" ] || { kill "$watch_pid" 2>/dev/null || :; wait "$watch_pid" 2>/dev/null || :; }
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || :
  [ -z "$server_pid" ] || { kill "$server_pid" 2>/dev/null || :; wait "$server_pid" 2>/dev/null || :; }
  fm_test_cleanup
  chmod -R u+w "$LAB"
  rm -rf "$LAB"
}
trap cleanup EXIT
fakebin=$(make_spawn_fakebin "$LAB/fake")
fm_git_worktree "$LAB/project" "$LAB/wt" cli-stream
fm_test_spawn_brief "$LAB" stream
FM_STREAM_SILENT_MAX_SECS=2 fm_test_run_spawn "$LAB" "$LAB/wt" "$fakebin" stream "$LAB/project" pi --mode no-mistakes --yolo off > "$LAB/spawn.log"
cat > "$LAB/server.mjs" <<'JS'
import http from 'node:http'; import fs from 'node:fs';
let stream;
const delta=(content)=>'data: '+JSON.stringify({id:'local',object:'chat.completion.chunk',created:1,model:'stream',choices:[{index:0,delta:{role:'assistant',content},finish_reason:null}]})+'\n\n';
const server=http.createServer((req,res)=>{
 if(req.url==='/delta'){stream?.write(delta(' more'));res.end('advanced');return;}
 if(req.url==='/finish'){stream?.write('data: '+JSON.stringify({id:'local',object:'chat.completion.chunk',created:1,model:'stream',choices:[{index:0,delta:{},finish_reason:'stop'}]})+'\n\ndata: [DONE]\n\n');stream?.end();res.end('finished');return;}
 req.resume();req.on('end',()=>{res.writeHead(200,{'Content-Type':'text/event-stream'});stream=res;if(process.env.PREP==='1') setTimeout(()=>res.write(delta('hello')),2500);else res.write(delta('hello'));});
});server.listen(0,'127.0.0.1',()=>fs.writeFileSync(process.argv[2],String(server.address().port)));
JS
node "$LAB/server.mjs" "$LAB/port" & server_pid=$!
for ((i=0;i<100;i++)); do [ ! -s "$LAB/port" ] || break; sleep .05; done
port=$(cat "$LAB/port")
printf '{"providers":{"fm-worker-stream":{"baseUrl":"http://127.0.0.1:%s/v1","api":"openai-completions","apiKey":"synthetic-local-only","models":[{"id":"stream","name":"stream","contextWindow":8192,"maxTokens":512}]}}}\n' "$port" > "$LAB/agent/models.json"
printf '{"cacheWarming":"off"}\n' > "$LAB/agent/settings.json"
launch="env PATH='$PATH' HOME='$LAB/user-home' FM_HOME='$LAB' PI_CODING_AGENT_DIR='$LAB/agent' PI_OFFLINE=1 pi --mode rpc --no-session --no-tools --no-mcp --no-skills --no-context-files --no-prompt-templates --no-extensions -e '$LAB/state/stream.pi-ext.ts' --provider fm-worker-stream --model stream --thinking off"
env TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s fm-lab-stream -n fm-stream -x 120 -y 40 -c "$LAB/wt" -e FM_HOME="$LAB" "$launch"
private_tmux() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
private_tmux send-keys -t fm-lab-stream:fm-stream -l '{"type":"prompt","message":"Hold the isolated local stream."}'
private_tmux send-keys -t fm-lab-stream:fm-stream Enter
if [ "${PREP:-0}" = 1 ]; then
  for ((i=0;i<200;i++)); do [ ! -s "$LAB/state/stream.model-stream" ] || break; sleep .01; done
  [ -s "$LAB/state/stream.model-stream" ]
  [ ! -e "$LAB/state/stream.model-progress" ]
  printf 'Foreground request before first response content: '; cat "$LAB/state/stream.model-stream"
  printf 'PASS: request observation starts before response progress.\n'
fi
for ((i=0;i<200;i++)); do [ ! -s "$LAB/state/stream.model-progress" ] || break; sleep .05; done
[ -s "$LAB/state/stream.model-progress" ] || { private_tmux capture-pane -p -t fm-lab-stream:fm-stream; exit 1; }
printf 'window=fm-lab-stream:fm-stream\nkind=ship\nharness=pi\nbackend=tmux\n' > "$LAB/state/stream.meta"
# Remove spawn-only fixture records; keep real Pi generation and lifecycle evidence.
rm -f "$LAB/state/stream.status"
socket=$(private_tmux display-message -p '#{socket_path}')
export TMUX="$socket,1,0" TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_STREAM_SILENT_MAX_SECS=2 FM_BUSY_TURN_MAX_SECS=99999 FM_STALE_ESCALATE_SECS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
[ "${OFF:-0}" != 1 ] || export FM_STREAM_SILENT_MAX_SECS=${BOUND:-0}
printf 'REAL PI CLI: '; pi --version
printf 'Active stream: '; cat "$LAB/state/stream.model-stream"
bash bin/fm-watch.sh > "$LAB/watch.log" 2>&1 & watch_pid=$!
if [ "${OFF:-0}" = 1 ]; then
  sleep 6
  kill -0 "$watch_pid"
  [ ! -s "$LAB/state/.wake-queue" ]
  [ ! -e "$LAB/state/.stale-since-fm-lab-stream_fm-stream" ]
  printf 'PASS: disabled observation ignores even a current real Pi stream after the short silence bound.\n'
  # Advance only the owned legacy timestamp fixture while both processes continue.
  touch -t 200001010000 "$LAB/state/stream.meta"
  for ((i=0;i<150;i++)); do kill -0 "$watch_pid" 2>/dev/null || break; sleep .1; done
  if kill -0 "$watch_pid" 2>/dev/null; then cat "$LAB/watch.log"; exit 1; fi
  wait "$watch_pid"; watch_pid=''
  cat "$LAB/watch.log"
  grep -F 'possible wedge' "$LAB/watch.log" >/dev/null
  if grep -F 'model stream silent' "$LAB/watch.log" >/dev/null; then exit 1; fi
  private_tmux display-message -p -t fm-lab-stream:fm-stream '#{pane_dead}' | grep '^0$' >/dev/null
  printf 'PASS: disabled observation preserves the legacy busy bound and leaves Pi running.\n'
  exit 0
fi
if [ -n "${RACE:-}" ]; then
  for ((i=0;i<150;i++)); do [ ! -s "$LAB/state/.stale-since-fm-lab-stream_fm-stream" ] || break; sleep .05; done
  [ -s "$LAB/state/.stale-since-fm-lab-stream_fm-stream" ]
  publication_lock="$LAB/state/.wake-queue.lock"
  [ "${LOCK_KIND:-queue}" != recovery ] || publication_lock="$LAB/state/.watcher-down.lock"
  mkdir "$publication_lock"
  printf '%s\n' "$$" > "$publication_lock/pid"
  sleep 3
  old_request=$(cat "$LAB/state/stream.model-stream")
  case "$RACE" in
    progress) curl --silent --fail "http://127.0.0.1:$port/delta" >/dev/null ;;
    close|replace)
      curl --silent --fail "http://127.0.0.1:$port/finish" >/dev/null
      for ((i=0;i<100;i++)); do grep -q 'state=idle' "$LAB/state/stream.busy-state" && break; sleep .05; done
      grep -q 'state=idle' "$LAB/state/stream.busy-state"
      if [ "$RACE" = replace ]; then
        private_tmux send-keys -t fm-lab-stream:fm-stream -l '{"type":"prompt","message":"Hold the next local stream."}'
        private_tmux send-keys -t fm-lab-stream:fm-stream Enter
        for ((i=0;i<100;i++)); do [ ! -s "$LAB/state/stream.model-stream" ] || break; sleep .05; done
      fi ;;
  esac
  for ((i=0;i<100;i++)); do [ "$(cat "$LAB/state/stream.model-stream" 2>/dev/null || :)" != "$old_request" ] && break; sleep .05; done
  [ "$(cat "$LAB/state/stream.model-stream" 2>/dev/null || :)" != "$old_request" ]
  rm -f "$publication_lock/pid"
  rmdir "$publication_lock"
  sleep 1
  [ ! -s "$LAB/state/.wake-queue" ]
  [ ! -e "$LAB/state/.watcher-down" ]
  kill -0 "$watch_pid"
  printf 'PASS: real Pi CLI %s during %s lock wait cancelled obsolete notification; recovery marker remains absent.\n' "$RACE" "${LOCK_KIND:-queue}"
  exit 0
fi
for ((i=0;i<200;i++)); do kill -0 "$watch_pid" 2>/dev/null || break; sleep .1; done
if kill -0 "$watch_pid" 2>/dev/null; then cat "$LAB/watch.log"; echo 'watcher failed to surface'; exit 1; fi
wait "$watch_pid"; watch_pid=''
cat "$LAB/watch.log"
cat "$LAB/state/.wake-queue"
grep -F 'model stream silent for' "$LAB/state/.wake-queue" >/dev/null
private_tmux capture-pane -p -S - -t fm-lab-stream:fm-stream > "$E/pi-cli-pane.txt"
private_tmux display-message -p -t fm-lab-stream:fm-stream '#{pane_dead}' | grep '^0$' >/dev/null
before_progress=$(cat "$LAB/state/stream.model-stream")
curl --silent --fail "http://127.0.0.1:$port/delta" >/dev/null
for ((i=0;i<100;i++)); do [ "$(cat "$LAB/state/stream.model-stream")" = "$before_progress" ] || break; sleep .05; done
[ "$(cat "$LAB/state/stream.model-stream")" != "$before_progress" ]
printf 'Progress after notification (worker still running): '; cat "$LAB/state/stream.model-stream"
curl --silent --fail "http://127.0.0.1:$port/finish" >/dev/null
for ((i=0;i<100;i++)); do [ -e "$LAB/state/stream.model-stream" ] || break; sleep .05; done
[ ! -e "$LAB/state/stream.model-stream" ]
for ((i=0;i<100;i++)); do grep -q 'state=idle' "$LAB/state/stream.busy-state" && break; sleep .05; done
grep -q 'state=idle' "$LAB/state/stream.busy-state"
printf 'After settlement: '; cat "$LAB/state/stream.busy-state"
private_tmux capture-pane -p -S - -t fm-lab-stream:fm-stream > "$E/pi-cli-pane-settled.txt"
printf 'PASS: real Pi CLI silence produced inspection notification; worker continued and settled.\n'
