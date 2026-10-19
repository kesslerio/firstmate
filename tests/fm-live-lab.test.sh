#!/usr/bin/env bash
# Behavior tests for bin/fm-live-lab.sh (readiness checks and teardown) and
# bin/fm-claude-trust.sh --lab-home.
#
# Every readiness check is proven both ways against a real private tmux server
# and real processes, with no harness: it passes on a lab in the shape up builds
# and fails, by name, on the recorded lab miss it exists to catch. The live
# end-to-end run on the real harnesses is the builder's own `up`.
set -u
export LC_ALL=C TZ=UTC

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-live-lab)
: > "$TMP_ROOT/pids"
FM_TEST_CHILD_REGISTRY=${FM_TEST_CHILD_REGISTRY:-"$TMP_ROOT/children"}
export FM_TEST_CHILD_REGISTRY
(umask 077; : >> "$FM_TEST_CHILD_REGISTRY"; : >> "$FM_TEST_CHILD_REGISTRY.history"; : >> "$FM_TEST_CHILD_REGISTRY.sockets.jsonl")
fm_test_track_child() {
  local pid=$1 identity
  identity=$(ps -p "$pid" -o lstart= 2>/dev/null) || return 0
  [ -n "$identity" ] || return 0
  (umask 077; printf '%s\t%s\t%s\n' "$pid" "$identity" "${2:-kill}" >> "$FM_TEST_CHILD_REGISTRY.history") || return 1
  printf '%s\t%s\t%s\n' "$pid" "$identity" "${2:-kill}" >> "$FM_TEST_CHILD_REGISTRY"
}
export -f fm_test_track_child
: > "$TMP_ROOT/tmux-dirs"
LIVE_LAB="$ROOT/bin/fm-live-lab.sh"
TRUST="$ROOT/bin/fm-claude-trust.sh"

live_lab_cleanup() {
  local exiting_status=${1:-$?} dir pid marker home
  for marker in "$TMP_ROOT/orphan-child" "$TMP_ROOT/late-child" "$TMP_ROOT/reused-child"; do
    [ ! -s "$marker" ] || printf '%s\n' "$(<"$marker")" >> "$TMP_ROOT/pids"
  done
  if ! fm_test_stop_children; then
    echo "lab fixture child cleanup failed; retained ownership records and evidence: $TMP_ROOT" >&2
    return 1
  fi
  while read -r pid; do [ -z "$pid" ] || wait "$pid" 2>/dev/null || true; done < "$TMP_ROOT/pids"
  python3 - "$FM_TEST_CHILD_REGISTRY.sockets.jsonl" <<'PYSOCKETCHECK'
import json, pathlib, sys
for line in open(sys.argv[1]):
    data = json.loads(line)
    directory = pathlib.Path(data['directory'])
    if directory.is_symlink(): raise ValueError('lab fixture socket directory became a link')
    if directory.exists():
        info = directory.lstat()
        if [info.st_dev, info.st_ino] != data['identity']:
            raise ValueError('lab fixture socket directory generation changed')
        record = pathlib.Path(data['home'], 'state', '.fm-lab-tmux-dir')
        if record.read_text().strip() != str(directory):
            raise ValueError('lab fixture socket ownership record changed')
        for socket in directory.glob('tmux-*/*'):
            info = socket.lstat()
            if data['sockets'].get(str(socket)) != [info.st_dev, info.st_ino]:
                raise ValueError('lab fixture socket generation changed')
PYSOCKETCHECK
  if [ "$?" -ne 0 ]; then
    echo "lab fixture socket ownership unknown; retained evidence: $TMP_ROOT" >&2
    return 1
  fi
  for home in "$TMP_ROOT"/*/home; do
    [ -f "$home/state/.fm-lab-tmux-dir" ] || continue
    "$ROOT/bin/fm-lab-home.sh" teardown "$home" || return 1
  done
  while read -r dir; do
    [ -n "$dir" ] || continue
    [ ! -e "$dir" ] || { echo "lab fixture socket remains; retained evidence: $TMP_ROOT" >&2; return 1; }
  done < "$TMP_ROOT/tmux-dirs"
  python3 - "$FM_TEST_CHILD_REGISTRY" <<'PYCLEANED'
import hashlib, json, os, pathlib, subprocess, sys
registry = pathlib.Path(sys.argv[1])
history = pathlib.Path(str(registry) + '.history')
rows = subprocess.check_output(['ps', '-axo', 'pid=,stat=,lstart='], text=True)
current = {int(pid): (state, born.strip()) for line in rows.splitlines()
           for pid, state, born in [line.split(None, 2)]}
for line in history.read_text().splitlines():
    pid, born, _ = line.split('\t')
    row = current.get(int(pid))
    if row and row[1] == born.strip() and not row[0].startswith('Z'):
        raise ValueError('archived lab fixture identity remains live: ' + pid)
socket_records = [json.loads(line) for line in pathlib.Path(str(registry) + '.sockets.jsonl').read_text().splitlines()]
if any(pathlib.Path(item['directory']).exists() or pathlib.Path(item['directory']).is_symlink() for item in socket_records):
    raise ValueError('archived lab socket remains')
receipt = pathlib.Path(str(registry) + '.custody.json')
temporary = pathlib.Path(str(receipt) + '.tmp')
temporary.write_text(json.dumps(dict(schema=1, registry=str(registry), history=str(history),
                                    cleanup_complete=True, retained_before_cleanup=True,
                                    history_sha256=hashlib.sha256(history.read_bytes()).hexdigest(),
                                    sockets=socket_records)) + '\n')
temporary.chmod(0o600)
os.replace(temporary, receipt)
PYCLEANED
  [ "$?" -eq 0 ] || { echo "lab fixture cleanup audit failed; retained evidence: $TMP_ROOT" >&2; return 1; }
  rm -rf "/tmp/fm-labt$$-mate" "/tmp/fm-labt$$-worker" "/tmp/fm-labt$$-other" /tmp/fm-labt"$$"-*+*
  if [ "$exiting_status" -ne 0 ]; then
    echo "lab test failed; owned processes and sockets retired; retained evidence: $TMP_ROOT" >&2
    return 0
  fi
  fm_test_cleanup
}
trap 'live_lab_cleanup || exit 1' EXIT

command -v tmux >/dev/null 2>&1 || { echo "ok - skipped: tmux is not installed"; exit 0; }

FAKE_HOME="$TMP_ROOT/fakehome"
mkdir -p "$FAKE_HOME/.pi/agent" "$FAKE_HOME/.treehouse/existing-pool"
printf '{}\n' > "$FAKE_HOME/.pi/agent/trust.json"
export HOME="$FAKE_HOME"
unset CLAUDE_CONFIG_DIR TMUX

MATE_ID="labt$$-mate"
WORKER_ID="labt$$-worker"
NONCE=abc12345

digest() { shasum -a 256 "$1" | awk '{print $1}'; }

# make_lab <name> <harness> [<claude-config-dir>]: a lab root in the shape up
# builds, with a live private tmux server. Every readiness input starts in its
# passing state.
make_lab() {
  local root="$TMP_ROOT/$1" harness=$2 claude_dir=${3:-} home tmux_dir lock_pid
  home="$root/home"
  mkdir -p "$root"
  "$ROOT/bin/fm-lab-home.sh" create "$home" >/dev/null || fail "lab home create"
  cp -R "$ROOT/bin" "$home/bin"
  cp "$ROOT/AGENTS.md" "$home/AGENTS.md"
  mkdir -p "$home/.pi" "$home/data/$WORKER_ID" "$root/mate/state" "$root/treehouse"
  cp -R "$ROOT/.pi/extensions" "$home/.pi/extensions"
  git -C "$home" init -q -b main
  git -C "$home" add -A bin AGENTS.md .pi
  git -C "$home" -c user.name=t -c user.email=t@example.invalid commit -qm lab
  tmux_dir=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$home") || fail "lab tmux dir"
  printf '%s\n' "$tmux_dir" >> "$TMP_ROOT/tmux-dirs"
  find "$HOME/.treehouse" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort > "$root/.treehouse-before"
  {
    echo 'fm-live-lab v1'
    echo "harness=$harness"
    echo "home=$home"
    echo "expect_host=yes"
    echo "host_off=no"
    echo "mate=yes"
    echo "worker=yes"
    echo "nonce=$NONCE"
    echo "mate_id=$MATE_ID"
    echo "worker_id=$WORKER_ID"
    echo "gate=$home/data/$WORKER_ID/gate"
    echo "pi_trust=$(digest "$HOME/.pi/agent/trust.json")"
    echo "claude_config_dir=$claude_dir"
    echo "claude_store=${claude_dir:-$HOME}/.claude.json"
    echo "pi_trust_store=$HOME/.pi/agent/trust.json"
    echo "treehouse_dir=$HOME/.treehouse"
    echo "tmux_dir=$tmux_dir"
  } > "$root/.fm-live-lab"

  lab_tmux "$root" new-session -d -s firstmate -n lab -c "$root" 'exec sleep 600'
  record_pid "$root" "$(lab_tmux "$root" display-message -p '#{pid}')"
  python3 - "$tmux_dir" "$home" >> "$FM_TEST_CHILD_REGISTRY.sockets.jsonl" <<'PYSOCKETCAPTURE'
import json, pathlib, sys
directory = pathlib.Path(sys.argv[1])
info = directory.lstat()
print(json.dumps(dict(directory=str(directory), home=sys.argv[2], identity=[info.st_dev, info.st_ino],
                     sockets={str(path): [path.lstat().st_dev, path.lstat().st_ino]
                              for path in directory.glob('tmux-*/*')})))
PYSOCKETCAPTURE
  lab_tmux "$root" new-window -d -t firstmate: -n main -c "$home" "printf 'LABREADY-$NONCE\n'; exec sleep 600"
  lab_tmux "$root" new-window -d -t firstmate: -n "fm-$MATE_ID" -c "$root/mate" 'exec sleep 600'
  lab_tmux "$root" new-window -d -t firstmate: -n "fm-$WORKER_ID" -c "$root" 'exec sleep 600'
  fm_write_meta "$home/state/$MATE_ID.meta" "window=firstmate:fm-$MATE_ID" "tasktmp=/tmp/fm-$MATE_ID"
  fm_write_meta "$home/state/$WORKER_ID.meta" "window=firstmate:fm-$WORKER_ID" "worktree=$home/projects/notes" "kind=secondmate" "tasktmp=/tmp/fm-$WORKER_ID"
  mkdir -p "$home/projects/notes"
  printf 'paused [at=1]: waiting on gate file %s to exist\n' "$home/data/$WORKER_ID/gate" > "$home/state/$WORKER_ID.status"

  lock_pid=$(lab_tmux "$root" display-message -p -t firstmate:=main '#{pane_pid}')
  printf '%s\n' "$lock_pid" > "$home/state/.lock"
  printf '%s\n' "$(lab_tmux "$root" display-message -p -t "firstmate:=fm-$MATE_ID" '#{pane_pid}')" > "$root/mate/state/.lock"
  start_watcher "$home"
  printf 'host\t%s\tx\n' "$(start_sleeper)" > "$home/state/.supervision-host"
  printf '%s\n' \
    '{"seq":1,"epoch":1,"key":"k","id":"a","tag":"captain","text":"probe"}' \
    '{"seq":2,"epoch":2,"key":"k","id":"b","tag":"main","text":"LABREADY"}' > "$home/state/.host-mirror.jsonl"
  write_pi_markers "$home" "$lock_pid"
  [ "$harness" = claude ] && node -e 'const fs=require("node:fs");const [s,h,r]=process.argv.slice(1);fs.writeFileSync(s,JSON.stringify({keep:1,projects:{[h]:{hasTrustDialogAccepted:true},[r+"/mate"]:{hasTrustDialogAccepted:true},"/elsewhere/project":{hasTrustDialogAccepted:true}}},null,2)+"\n")' \
    "${claude_dir:-$HOME}/.claude.json" "$home" "$root"
  printf '%s\n' "$root"
}

# Recorded fixture roots must not share the runner's process group.
start_group() { perl -e 'setpgrp(0,0); exec @ARGV' "$@" >/dev/null 2>&1 &
  fm_test_track_child "$!" kill
}

record_pid() {  # <root> <pid>
  printf 'launch_pid=%s\nlaunch_start=%s\n' "$2" "$(ps -o lstart= -p "$2" | awk '{$1=$1; print}')" >> "$1/.fm-live-lab"
  fm_test_track_child "$2" kill
}

capture_up_lab() {
  python3 - "$1" "$FM_TEST_CHILD_REGISTRY" "$ROOT/bin/fm-lab-launch.py" <<'PYUPCAPTURE'
import json, os, pathlib, subprocess, sys
root, registry, helper = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
fields = {}
for line in (root / '.fm-live-lab').read_text().splitlines()[1:]:
    key, sep, value = line.partition('=')
    if sep: fields.setdefault(key, []).append(value)
text = subprocess.check_output([sys.executable, helper, 'anchors', str(root)], text=True)
expected = {int(pid): born for line in text.splitlines() for pid, born in [line.split('\t', 1)]}
text = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,pgid=,stat=,lstart='], text=True)
rows = {int(pid): (int(parent), int(group), state, born.strip()) for line in text.splitlines()
        for pid, parent, group, state, born in [line.split(None, 4)]}
owned = set()
groups = set()
for name in fields.get('anchor_record', []):
    data = json.loads(root.joinpath(name).read_text())
    if data.get('retired') is True: continue
    row = rows.get(data['pid'])
    if not row or expected.get(data['pid']) != row[3] or row[1] != data['group'] or row[2].startswith('Z'):
        raise ValueError('public-up guardian identity changed before fixture custody capture')
    owned.add(data['pid'])
    groups.add(row[1])
for pid, born in zip(fields.get('launch_pid', []), fields.get('launch_start', [])):
    pid = int(pid)
    if pid in rows and rows[pid][3] == born and not rows[pid][2].startswith('Z'): owned.add(pid)
owned.update(pid for pid, row in rows.items() if row[1] in groups and not row[2].startswith('Z'))
while True:
    children = {pid for pid, row in rows.items() if row[0] in owned and not row[2].startswith('Z')}
    if children <= owned: break
    owned.update(children)
with open(str(registry) + '.history', 'a') as history, registry.open('a') as stream:
    for pid in owned:
        line = str(pid) + '\t' + rows[pid][3] + '\tkill\n'
        history.write(line)
        history.flush()
        os.fsync(history.fileno())
        stream.write(line)
directory = pathlib.Path(fields['tmux_dir'][0])
info = directory.lstat()
with open(str(registry) + '.sockets.jsonl', 'a') as stream:
    stream.write(json.dumps(dict(directory=str(directory), home=fields['home'][0], identity=[info.st_dev, info.st_ino],
                                sockets={str(path): [path.lstat().st_dev, path.lstat().st_ino]
                                         for path in directory.glob('tmux-*/*')})) + '\n')
PYUPCAPTURE
}

lab_tmux() {  # <root> <tmux args...>
  local dir
  dir=$(sed -n 's/^tmux_dir=//p' "$1/.fm-live-lab")
  shift
  env -u TMUX TMUX_TMPDIR="$dir" tmux "$@"
}

start_sleeper() {
  sleep 600 >/dev/null 2>&1 &
  fm_test_track_child "$!"
  printf '%s\n' "$!" >> "$TMP_ROOT/pids"
  printf '%s\n' "$!"
}

start_watcher() {  # <home>: a live process holding a matching watcher lock
  local home=$1 pid lock="$1/state/.watch.lock"
  pid=$(start_sleeper)
  mkdir -p "$lock"
  printf '%s\n' "$pid" > "$lock/pid"
  printf '%s\n' "$home" > "$lock/fm-home"
  printf '%s\n' "$home/bin/fm-watch.sh" > "$lock/watcher-path"
  fm_test_pid_identity "$pid" > "$lock/pid-identity"
  touch "$home/state/.last-watcher-beat"
}

write_pi_markers() {  # <home> <lock-pid>
  local home=$1 pid=$2
  v() { FM_HOME="$home" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pi_extension_version "$1/.pi/extensions/$2"' _ "$home" "$1"; }
  printf '%s\n%s\ngeneration=1 phase=active\n' "$(v fm-primary-pi-watch.ts)" "$pid" > "$home/state/.pi-watch-extension-loaded"
  printf '%s\n%s\n' "$(v fm-primary-turnend-guard.ts)" "$pid" > "$home/state/.pi-turnend-extension-loaded"
  printf '%s\n' "$pid" > "$home/state/.pi-branch-extension-loaded"
}

run_check() {  # <root>: sets CHECK_OUT and CHECK_RC
  CHECK_OUT=$("$LIVE_LAB" check "$1" 2>&1)
  CHECK_RC=$?
}

set_record() {  # <root> <key> <value>
  sed -i.bak "s|^$2=.*|$2=$3|" "$1/.fm-live-lab" && rm -f "$1/.fm-live-lab.bak"
}

start_retirement_anchor() {  # <lab> [env <assignments>]
  local lab=$1 attempt
  shift
  start_group "$@" "$LIVE_LAB" launch "$lab" -- true
  ANCHOR_WRAPPER=$!
  ANCHOR_RECORD="$lab/.fm-lab-anchor-$ANCHOR_WRAPPER"
  printf '%s\n' "$ANCHOR_WRAPPER" >> "$TMP_ROOT/pids"
  for ((attempt=0; attempt<50; attempt++)); do
    [ -f "$ANCHOR_RECORD" ] && grep -q '"child"' "$ANCHOR_RECORD" && break
    sleep .1
  done
  read -r ANCHOR_PID ANCHOR_CHILD ANCHOR_GROUP < <(python3 - "$ANCHOR_RECORD" <<'PYANCHOR'
import json, sys
data = json.load(open(sys.argv[1]))
print(data['pid'], data['child'], data['group'])
PYANCHOR
  )
  [ -n "${ANCHOR_PID:-}" ] && [ "$ANCHOR_PID" != "$ANCHOR_GROUP" ] || fail 'fixture needs distinct guardian PID and target PGID'
  fm_test_track_child "$ANCHOR_PID" kill
  fm_test_track_child "$ANCHOR_CHILD" kill
  record_pid "$lab" "$ANCHOR_WRAPPER"
}

start_retirement_sentinel() {
  local attempt
  RETIREMENT_SENTINEL_SEQUENCE=$((${RETIREMENT_SENTINEL_SEQUENCE:-0}+1))
  RETIREMENT_SENTINEL_SIGNALS="$TMP_ROOT/retirement-sentinel-$RETIREMENT_SENTINEL_SEQUENCE-signals"
  RETIREMENT_SENTINEL_READY="$TMP_ROOT/retirement-sentinel-$RETIREMENT_SENTINEL_SEQUENCE-ready"
  cat > "$TMP_ROOT/retirement-sentinel.py" <<'PYSENTINEL'
import pathlib, signal, sys, time
def received(signum, frame):
    with open(sys.argv[1], 'a') as stream:
        stream.write(str(signum) + '\n')
for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGCONT, signal.SIGUSR1):
    signal.signal(sig, received)
pathlib.Path(sys.argv[2]).touch()
time.sleep(120)
PYSENTINEL
  start_group python3 "$TMP_ROOT/retirement-sentinel.py" "$RETIREMENT_SENTINEL_SIGNALS" "$RETIREMENT_SENTINEL_READY"
  RETIREMENT_SENTINEL=$!
  for ((attempt=0; attempt<50; attempt++)); do
    [ -e "$RETIREMENT_SENTINEL_READY" ] && return 0
    sleep .1
  done
  fail 'retirement sentinel did not become ready'
}

assert_retirement_preserved() {  # <lab> <guardian-record> <trust-digest>
  assert_present "$1/.fm-live-lab" 'refused retirement lost its lab evidence'
  assert_present "$1/home" 'refused retirement removed its private home'
  assert_equals "$3" "$(digest "$HOME/.claude.json")" 'refused retirement changed Claude trust'
  python3 - "$2" <<'PYUNRETIRED'
import json, sys
assert json.load(open(sys.argv[1])).get('retired') is not True
PYUNRETIRED
  expect_code 0 "$?" 'refused retirement must retain an unretired record'
  kill -0 "$RETIREMENT_SENTINEL" || fail 'retirement touched the unrelated sentinel'
  assert_absent "$RETIREMENT_SENTINEL_SIGNALS" 'retirement sent an unrelated signal'
}

test_retirement_effect_boundary() {
  local lab fault trust_before guard_start out
  test_guardian_terminal_transition
  start_retirement_sentinel
  mkdir "$TMP_ROOT/retirement-boundary-bin"
  cat > "$TMP_ROOT/retirement-boundary-bin/ps" <<'SHBOUNDARY'
#!/usr/bin/env bash
if [ "${1:-}" = -o ] && [ "${2:-}" = lstart= ] && [ "${4:-}" = "$BOUNDARY_PID" ]; then
  parent=$("$REAL_PS" -o args= -p "$PPID") || exit 1
  case "$parent" in
    *'fm-lab-launch.py request-retirement '*)
      touch "$BOUNDARY_PROVED"
      case "$BOUNDARY_FAULT" in
        stale) printf 'Mon Jan 1 00:00:00 1990\n'; exit 0 ;;
        unknown) exit 1 ;;
        exited)
          observed=$("$REAL_PS" -o lstart= -p "$BOUNDARY_PID" | awk '{$1=$1; print}')
          [ "$observed" = "$BOUNDARY_START" ] || exit 1
          kill -KILL "$BOUNDARY_PID" || exit 1
          ;;
      esac
      ;;
  esac
fi
exec "$REAL_PS" "$@"
SHBOUNDARY
  chmod +x "$TMP_ROOT/retirement-boundary-bin/ps"
  for fault in stale unknown exited; do
    lab=$(make_lab "retirement-$fault" claude)
    start_retirement_anchor "$lab"
    guard_start=$(ps -o lstart= -p "$ANCHOR_PID" | awk '{$1=$1; print}')
    trust_before=$(digest "$HOME/.claude.json")
    out=$(REAL_PS="$(command -v ps)" BOUNDARY_PID="$ANCHOR_PID" BOUNDARY_START="$guard_start" BOUNDARY_FAULT="$fault" BOUNDARY_PROVED="$lab/boundary-proved" PATH="$TMP_ROOT/retirement-boundary-bin:$PATH" "$LIVE_LAB" down "$lab" 2>&1)
    [ "$?" -ne 0 ] || fail "$fault retirement boundary was accepted: $out"
    assert_present "$lab/boundary-proved" 'fixture did not reach the retirement request boundary'
    assert_absent "$ANCHOR_RECORD.retire" 'denied retirement published an effect request'
    assert_retirement_preserved "$lab" "$ANCHOR_RECORD" "$trust_before"
    if [ "$fault" != exited ]; then
      assert_equals "$guard_start" "$(ps -o lstart= -p "$ANCHOR_PID" | awk '{$1=$1; print}')" 'denied retirement lost its original guardian'
      out=$("$LIVE_LAB" down "$lab" 2>&1)
      expect_code 0 "$?" "current owner must retire after a denied request: $out"
      assert_absent "$lab" 'verified retirement did not remove its private lab'
      case "$(ps -o stat= -p "$ANCHOR_PID" 2>/dev/null | awk '{$1=$1; print}')" in ''|Z*) ;; *) fail 'successful retirement left its guardian live' ;; esac
    fi
  done
  pass 'retirement revalidates identity at the request boundary; stale, unknown and exited owners retain lab and trust without unrelated signals'
}

test_guardian_terminal_transition() {
  local fault lab control out rc trust_before
  start_retirement_sentinel
  mkdir -p "$TMP_ROOT/transition-bin"
  cat > "$TMP_ROOT/transition-bin/ps" <<'SHTRANSITION'
#!/usr/bin/env bash
if [ "${1:-}" = -axo ] && [ "${2:-}" = 'pid=,pgid=,stat=' ]; then
  touch "$TRANSITION_CONTROL/peer-held"
  for ((attempt=0; attempt<50; attempt++)); do
    [ -f "$TRANSITION_CONTROL/reader-held" ] && break
    sleep .1
  done
  [ -f "$TRANSITION_CONTROL/reader-held" ] || exit 1
elif [ "${1:-}" = -o ] && [ "${2:-}" = args= ] && [ "${4:-}" = "$(cat "$TRANSITION_CONTROL/pid")" ]; then
  parent=$("$REAL_PS" -o args= -p "$PPID") || exit 1
  case "$parent" in
    *'fm-lab-launch.py retirement-status '*)
      python3 - "$TRANSITION_CONTROL" "$REAL_PS" "$TRANSITION_FAULT" <<'PYTRANSITION'
import datetime, json, os, pathlib, re, subprocess, sys, time
control, real_ps, fault = pathlib.Path(sys.argv[1]), *sys.argv[2:]
path = pathlib.Path((control / 'record').read_text().strip())
pid = int((control / 'pid').read_text())
(control / 'reader-held').touch()
for _ in range(50):
    data = json.loads(path.read_text())
    request = json.loads(pathlib.Path(str(path) + '.retire').read_text())
    snapshot = subprocess.run([real_ps, '-axo', 'pid=,stat=,lstart='], text=True, capture_output=True)
    (control / 'owner-exit-snapshot-stdout').write_text(snapshot.stdout)
    (control / 'owner-exit-snapshot-stderr').write_text(snapshot.stderr)
    (control / 'owner-exit-snapshot-exit').write_text(str(snapshot.returncode) + '\n')
    if snapshot.returncode != 0:
        raise SystemExit('owner-exit observation UNKNOWN: complete real ps snapshot failed')
    rows = {}
    for line in snapshot.stdout.splitlines():
        row = line.split(None, 2)
        if (len(row) != 3 or not row[0].isdigit() or int(row[0]) <= 0
                or int(row[0]) in rows or re.fullmatch(r'[RSDTtZXIW][<NLsl+]*', row[1]) is None):
            raise SystemExit('owner-exit observation UNKNOWN: malformed real ps snapshot')
        born = ' '.join(row[2].split())
        datetime.datetime.strptime(born, '%a %b %d %H:%M:%S %Y')
        rows[int(row[0])] = (row[1], born)
    if os.getpid() not in rows:
        raise SystemExit('owner-exit observation UNKNOWN: real ps snapshot omitted its live reader')
    owner = rows.get(pid)
    exited = owner is None or owner[1] != request['identity']['start'] or owner[0].startswith('Z')
    if (data.get('retired') is True and not data.get('retirement_error')
            and data.get('retirement_request') == request['request']
            and all(data.get(key) == value for key, value in request['identity'].items()) and exited):
        (control / 'valid-terminal.json').write_text(json.dumps(data) + '\n')
        (control / 'valid-terminal.json').chmod(0o600)
        witness = dict(case=fault, pid=pid, matching_terminal_ack=True, reader_released_peer=True,
                       owner_exit_snapshot=dict(returncode=snapshot.returncode, stdout=snapshot.stdout,
                                                stderr=snapshot.stderr, reader_pid=os.getpid(),
                                                original_start=request['identity']['start'], owner_row=owner))
        (control / 'transition-witness.json').write_text(json.dumps(witness) + '\n')
        if fault == 'missing': path.unlink()
        elif fault != 'allowed':
            if fault == 'wrong-request': data['retirement_request'] = 'foreign-request'
            if fault == 'foreign': data.update(root='/foreign-lab', nonce=['foreign-lab'])
            if fault == 'wrong-token': data['retirement_token'] = 'foreign-token'
            if fault == 'stale-start': data['start'] = 'Mon Jan 1 00:00:00 1990'
            if fault == 'unretired': data.pop('retired', None)
            if fault == 'error': data['retirement_error'] = 'injected terminal observation UNKNOWN'
            temporary = path.parent / 'terminal-tmp'
            temporary.write_text(json.dumps(data) + '\n')
            temporary.chmod(0o600)
            temporary.replace(path)
        (control / 'transition-proved').touch()
        break
    time.sleep(.1)
else:
    raise SystemExit('guardian did not publish a matching terminal acknowledgement and exit before the held observation')
PYTRANSITION
      [ "$?" -eq 0 ] || exit 1
      "$REAL_PS" "$@" > "$TRANSITION_CONTROL/owner-args-stdout" 2> "$TRANSITION_CONTROL/owner-args-stderr"
      rc=$?
      printf '%s\n' "$rc" > "$TRANSITION_CONTROL/owner-args-exit"
      cat "$TRANSITION_CONTROL/owner-args-stdout"
      cat "$TRANSITION_CONTROL/owner-args-stderr" >&2
      exit "$rc"
      ;;
  esac
fi
exec "$REAL_PS" "$@"
SHTRANSITION
  chmod +x "$TMP_ROOT/transition-bin/ps"
  for fault in allowed wrong-request foreign wrong-token stale-start unretired error missing; do
    lab=$(make_lab "terminal-$fault" claude)
    control="$TMP_ROOT/transition-control-$fault"
    mkdir "$control"
    start_retirement_anchor "$lab" env REAL_PS="$(command -v ps)" TRANSITION_CONTROL="$control" TRANSITION_FAULT="$fault" PATH="$TMP_ROOT/transition-bin:$PATH"
    printf '%s\n' "$ANCHOR_RECORD" > "$control/record"
    printf '%s\n' "$ANCHOR_PID" > "$control/pid"
    trust_before=$(digest "$HOME/.claude.json")
    out=$(REAL_PS="$(command -v ps)" TRANSITION_CONTROL="$control" TRANSITION_FAULT="$fault" PATH="$TMP_ROOT/transition-bin:$PATH" "$LIVE_LAB" down "$lab" 2>&1)
    rc=$?
    assert_present "$control/peer-held" 'fixture did not hold the guardian before terminal publication'
    assert_present "$control/reader-held" 'status reader did not observe the pre-terminal owner'
    assert_present "$control/transition-proved" 'fixture did not prove matching terminal acknowledgement and real owner exit'
    assert_present "$control/owner-args-exit" 'fixture did not complete the held real owner args observation'
    python3 - "$control" "$ROOT/bin/fm-lab-launch.py" "$lab" "$FM_TEST_CHILD_REGISTRY.terminal-transition.jsonl" <<'PYARGSPROOF'
import json, pathlib, sys
control, helper, root, evidence = pathlib.Path(sys.argv[1]), str(pathlib.Path(sys.argv[2]).resolve()), sys.argv[3], sys.argv[4]
status = int((control / 'owner-args-exit').read_text())
command = (control / 'owner-args-stdout').read_text()
if status == 0 and helper in command and root in command:
    raise SystemExit('held real owner args still satisfies the original live-owner predicate')
witness = json.loads((control / 'transition-witness.json').read_text())
witness.update(owner_args_exit=status, owner_args_stdout=command,
               owner_args_stderr=(control / 'owner-args-stderr').read_text(),
               helper_binding=helper, root_binding=root, original_owner_predicate_false=True)
with open(evidence, 'a') as stream:
    stream.write(json.dumps(witness) + '\n')
PYARGSPROOF
    expect_code 0 "$?" 'held real owner observation must fail the original live-owner predicate'
    if [ "$fault" = allowed ]; then
      expect_code 0 "$rc" "matching terminal acknowledgement must survive owner-observation exit: $out"
    else
      [ "$rc" -ne 0 ] || fail "$fault terminal record was accepted after owner observation failed"
      assert_present "$lab/.fm-live-lab" 'unverified terminal transition removed its lab evidence'
      assert_present "$lab/home" 'unverified terminal transition removed its private home'
      assert_equals "$trust_before" "$(digest "$HOME/.claude.json")" "$fault terminal transition changed trust"
      cp "$control/valid-terminal.json" "$lab/terminal-restore"
      mv "$lab/terminal-restore" "$ANCHOR_RECORD"
      out=$("$LIVE_LAB" down "$lab" 2>&1)
      expect_code 0 "$?" "restored exact terminal acknowledgement must permit cleanup: $out"
    fi
    assert_absent "$lab" 'verified terminal transition did not remove its private lab'
    python3 - "$control/valid-terminal.json" <<'PYFINALOWNER'
import datetime, json, os, re, subprocess, sys
data = json.load(open(sys.argv[1]))
text = subprocess.check_output(['ps', '-axo', 'pid=,stat=,lstart='], text=True)
rows = {}
for line in text.splitlines():
    row = line.split(None, 2)
    if (len(row) != 3 or not row[0].isdigit() or int(row[0]) <= 0
            or int(row[0]) in rows or re.fullmatch(r'[RSDTtZXIW][<NLsl+]*', row[1]) is None):
        raise SystemExit('final owner observation UNKNOWN: malformed real ps snapshot')
    born = ' '.join(row[2].split())
    datetime.datetime.strptime(born, '%a %b %d %H:%M:%S %Y')
    rows[int(row[0])] = (row[1], born)
if os.getpid() not in rows:
    raise SystemExit('final owner observation UNKNOWN: real ps snapshot omitted its live reader')
owner = rows.get(data['pid'])
if owner and owner[1] == data['start'] and not owner[0].startswith('Z'):
    raise SystemExit('terminal transition left its guardian live')
PYFINALOWNER
    expect_code 0 "$?" 'terminal transition must leave its captured guardian absent or explicitly zombie'
    kill -0 "$RETIREMENT_SENTINEL" || fail 'terminal transition signalled its unrelated sentinel'
    assert_absent "$RETIREMENT_SENTINEL_SIGNALS" 'terminal transition sent an unrelated signal'
  done
}

make_guardian_observer_bin() {
  mkdir -p "$TMP_ROOT/guardian-observer-bin"
  cat > "$TMP_ROOT/guardian-observer-bin/ps" <<'SHOBSERVER'
#!/usr/bin/env bash
if [ "${1:-}" = -axo ] && [ "${2:-}" = 'pid=,pgid=,stat=' ] && [ -e "$GUARDIAN_FAULT_ARM" ]; then
  rm "$GUARDIAN_FAULT_ARM" || exit 1
  printf 'failed\n' >> "$GUARDIAN_FAULT_HIT"
  exit 1
fi
exec "$REAL_PS" "$@"
SHOBSERVER
  chmod +x "$TMP_ROOT/guardian-observer-bin/ps"
}

test_guardian_observation_retry() {
  local lab trust_before guard_start out
  start_retirement_sentinel
  make_guardian_observer_bin
  lab=$(make_lab guardian-observer claude)
  start_retirement_anchor "$lab" env REAL_PS="$(command -v ps)" GUARDIAN_FAULT_ARM="$lab/observer-arm" GUARDIAN_FAULT_HIT="$lab/observer-hit" PATH="$TMP_ROOT/guardian-observer-bin:$PATH"
  guard_start=$(ps -o lstart= -p "$ANCHOR_PID" | awk '{$1=$1; print}')
  trust_before=$(digest "$HOME/.claude.json")
  touch "$lab/observer-arm"
  out=$("$LIVE_LAB" down "$lab" 2>&1)
  [ "$?" -ne 0 ] || fail "guardian UNKNOWN was accepted: $out"
  assert_present "$lab/observer-hit" 'fixture did not fail the guardian three-field peer observer'
  assert_contains "$out" 'launch retirement observation unavailable' 'guardian UNKNOWN must reach the cleanup caller'
  assert_retirement_preserved "$lab" "$ANCHOR_RECORD" "$trust_before"
  assert_equals "$guard_start" "$(ps -o lstart= -p "$ANCHOR_PID" | awk '{$1=$1; print}')" 'UNKNOWN destroyed the continuous guardian'
  python3 - "$ANCHOR_RECORD" <<'PYUNKNOWN'
import json, sys
data = json.load(open(sys.argv[1]))
assert data.get('retirement_error') and data.get('retirement_request')
assert data.get('retired') is not True
PYUNKNOWN
  expect_code 0 "$?" 'UNKNOWN needs durable non-success acknowledgement'
  out=$("$LIVE_LAB" down "$lab" 2>&1)
  expect_code 0 "$?" "fresh request must recover after guardian observation resumes: $out"
  assert_absent "$lab" 'fresh retirement did not remove the verified private lab'
  case "$(ps -o stat= -p "$ANCHOR_PID" 2>/dev/null | awk '{$1=$1; print}')" in ''|Z*) ;; *) fail 'retried retirement left its guardian live' ;; esac
  kill -0 "$RETIREMENT_SENTINEL" || fail 'retried retirement signalled the sentinel'
  assert_absent "$RETIREMENT_SENTINEL_SIGNALS" 'retried retirement sent an unrelated signal'
  pass 'guardian three-field UNKNOWN retains a live owner and durable evidence; a fresh request retires it safely'
}

test_guardian_acknowledgement_retry() {
  local lab trust_before guard_start out
  start_retirement_sentinel
  mkdir -p "$TMP_ROOT/ack-hook"
  cat > "$TMP_ROOT/ack-hook/sitecustomize.py" <<'PYACKHOOK'
import errno, os, pathlib, sys
original_replace = os.replace
def replace(source, destination, *args, **kwargs):
    target = pathlib.Path(destination)
    arm = pathlib.Path(os.environ['ACK_FAULT_ARM'])
    if (len(sys.argv) > 1 and sys.argv[1] == 'launch' and arm.exists()
            and target.name.startswith('.fm-lab-anchor-') and not target.name.endswith('.retire')):
        arm.unlink()
        pathlib.Path(os.environ['ACK_FAULT_HIT']).touch()
        raise OSError(errno.EIO, 'injected retirement acknowledgement failure')
    return original_replace(source, destination, *args, **kwargs)
os.replace = replace
PYACKHOOK
  lab=$(make_lab guardian-ack claude)
  start_retirement_anchor "$lab" env PYTHONPATH="$TMP_ROOT/ack-hook" ACK_FAULT_ARM="$lab/ack-arm" ACK_FAULT_HIT="$lab/ack-hit"
  guard_start=$(ps -o lstart= -p "$ANCHOR_PID" | awk '{$1=$1; print}')
  trust_before=$(digest "$HOME/.claude.json")
  touch "$lab/ack-arm"
  out=$("$LIVE_LAB" down "$lab" 2>&1)
  [ "$?" -ne 0 ] || fail "failed acknowledgement was accepted: $out"
  assert_present "$lab/ack-hit" 'fixture did not fail the guardian acknowledgement publication'
  assert_contains "$out" 'launch retirement acknowledgement unavailable' 'publication failure must reach the cleanup caller'
  assert_retirement_preserved "$lab" "$ANCHOR_RECORD" "$trust_before"
  assert_equals "$guard_start" "$(ps -o lstart= -p "$ANCHOR_PID" | awk '{$1=$1; print}')" 'publication failure destroyed the guardian'
  out=$("$LIVE_LAB" down "$lab" 2>&1)
  expect_code 0 "$?" "fresh request must recover after acknowledgement publication: $out"
  assert_absent "$lab" 'acknowledgement retry did not remove its verified lab'
  case "$(ps -o stat= -p "$ANCHOR_PID" 2>/dev/null | awk '{$1=$1; print}')" in ''|Z*) ;; *) fail 'acknowledgement retry left its guardian live' ;; esac
  pass 'failed acknowledgement publication retains an unretired guardian and a fresh request can complete'
}

test_guardian_request_replay() {
  local lab trust_before guard_start out first_request second_request attempt
  start_retirement_sentinel
  make_guardian_observer_bin
  lab=$(make_lab guardian-replay claude)
  start_retirement_anchor "$lab" env REAL_PS="$(command -v ps)" GUARDIAN_FAULT_ARM="$lab/observer-arm" GUARDIAN_FAULT_HIT="$lab/observer-hit" PATH="$TMP_ROOT/guardian-observer-bin:$PATH"
  guard_start=$(ps -o lstart= -p "$ANCHOR_PID" | awk '{$1=$1; print}')
  trust_before=$(digest "$HOME/.claude.json")
  touch "$lab/observer-arm"
  out=$("$LIVE_LAB" down "$lab" 2>&1)
  [ "$?" -ne 0 ] || fail "request A observation failure was accepted: $out"
  assert_contains "$out" 'launch retirement observation unavailable' 'request A must acknowledge UNKNOWN'
  cp "$ANCHOR_RECORD.retire" "$lab/request-A"
  first_request=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["request"])' "$lab/request-A")
  touch "$lab/observer-arm"
  out=$("$LIVE_LAB" down "$lab" 2>&1)
  [ "$?" -ne 0 ] || fail "request B observation failure was accepted: $out"
  assert_contains "$out" 'launch retirement observation unavailable' 'request B must acknowledge UNKNOWN'
  second_request=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["request"])' "$ANCHOR_RECORD.retire")
  [ "$first_request" != "$second_request" ] || fail 'fresh cleanup reused request A'
  assert_equals 2 "$(wc -l < "$lab/observer-hit" | tr -d ' ')" 'A and B must each reach the real peer observer'
  touch "$lab/observer-arm"
  cp "$lab/request-A" "$lab/replay-tmp"
  mv "$lab/replay-tmp" "$ANCHOR_RECORD.retire"
  for ((attempt=0; attempt<50; attempt++)); do
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(not (d.get("retirement_request")==sys.argv[2] and d.get("retirement_error")=="replayed lab launch retirement request"))' "$ANCHOR_RECORD" "$first_request" && break
    sleep .1
  done
  [ "$attempt" -lt 50 ] || fail 'guardian did not explicitly deny A after consuming A and B'
  assert_present "$lab/observer-arm" 'replayed A reached the peer observer again'
  assert_equals 2 "$(wc -l < "$lab/observer-hit" | tr -d ' ')" 'replayed A produced another observation'
  assert_retirement_preserved "$lab" "$ANCHOR_RECORD" "$trust_before"
  assert_equals "$guard_start" "$(ps -o lstart= -p "$ANCHOR_PID" | awk '{$1=$1; print}')" 'replay denial lost the continuous owner'
  rm "$lab/observer-arm"
  out=$("$LIVE_LAB" down "$lab" 2>&1)
  expect_code 0 "$?" "fresh request C must retire after denied replay: $out"
  assert_absent "$lab" 'request C did not remove its verified lab'
  case "$(ps -o stat= -p "$ANCHOR_PID" 2>/dev/null | awk '{$1=$1; print}')" in ''|Z*) ;; *) fail 'request C left its guardian live' ;; esac
  pass 'consumed requests A and B cannot replay A; a distinct healthy request C retires the same guardian'
}

test_guardian_invalid_requests() {
  local lab fault out guard_start trust_before record_before attempt
  start_retirement_sentinel
  mkdir -p "$TMP_ROOT/request-hook"
  cat > "$TMP_ROOT/request-hook/sitecustomize.py" <<'PYREQUESTHOOK'
import os, pathlib, subprocess, sys
original_open, original_popen = os.open, subprocess.Popen
def observe_open(path, flags, *args, **kwargs):
    phase = pathlib.Path(os.environ['REQUEST_PHASE'])
    watching = len(sys.argv) > 1 and sys.argv[1] == 'launch' and str(path).endswith('.retire') and phase.exists()
    if watching:
        name = phase.read_text().strip()
        counter = phase.parent / ('request-attempts-' + name)
        temporary = counter.with_suffix('.tmp')
        temporary.write_text(str(int(counter.read_text()) + 1 if counter.exists() else 1))
        os.replace(temporary, counter)
    fd = original_open(path, flags, *args, **kwargs)
    if watching:
        (phase.parent / ('request-opened-' + name)).touch()
    return fd
def observe_popen(command, *args, **kwargs):
    if command == ['ps', '-axo', 'pid=,pgid=,stat=']:
        pathlib.Path(os.environ['REQUEST_PEER_OBSERVER']).touch()
    return original_popen(command, *args, **kwargs)
os.open, subprocess.Popen = observe_open, observe_popen
PYREQUESTHOOK
  lab=$(make_lab guardian-invalid-requests claude)
  start_retirement_anchor "$lab" env PYTHONPATH="$TMP_ROOT/request-hook" REQUEST_PHASE="$lab/request-phase" REQUEST_PEER_OBSERVER="$lab/peer-observer"
  guard_start=$(ps -o lstart= -p "$ANCHOR_PID" | awk '{$1=$1; print}')
  trust_before=$(digest "$HOME/.claude.json")
  record_before=$(digest "$ANCHOR_RECORD")
  for fault in missing malformed malformed-json foreign stale linked fifo; do
    python3 - "$ANCHOR_RECORD" "$fault" <<'PYREQUESTFAULT'
import json, os, pathlib, secrets, sys
record, fault = pathlib.Path(sys.argv[1]), sys.argv[2]
data = json.loads(record.read_text())
path = pathlib.Path(str(record) + '.retire')
if os.path.lexists(path): path.unlink()
if fault == 'fifo': os.mkfifo(path, 0o600)
elif fault == 'linked':
    target = record.parent / 'foreign-request'
    target.write_text('{}')
    path.symlink_to(target)
elif fault != 'missing':
    request = dict(record=record.name, request=secrets.token_hex(16), identity={key: data[key] for key in
                   ('schema', 'root', 'nonce', 'pid', 'start', 'group', 'child', 'retirement_token')})
    if fault == 'foreign': request['identity']['nonce'] = ['foreign-lab']
    if fault == 'stale': request['identity']['start'] = 'Mon Jan 1 00:00:00 1990'
    temporary = record.parent / 'request-tmp'
    temporary.write_text('[]' if fault == 'malformed' else '{' if fault == 'malformed-json' else json.dumps(request))
    temporary.chmod(0o600)
    os.replace(temporary, path)
(record.parent / 'request-phase').write_text(fault)
PYREQUESTFAULT
    for ((attempt=0; attempt<50; attempt++)); do
      [ -f "$lab/request-attempts-$fault" ] && [ "$(cat "$lab/request-attempts-$fault")" -ge 2 ] && break
      sleep .1
    done
    [ "$attempt" -lt 50 ] || fail "$fault request blocked or destroyed the guardian before a second request-read attempt"
    [ "$fault" != fifo ] || assert_present "$lab/request-opened-fifo" 'FIFO request open blocked before guarded record validation'
    assert_equals "$record_before" "$(digest "$ANCHOR_RECORD")" "$fault request changed its owner's acknowledgement record"
    assert_equals "$guard_start" "$(ps -o lstart= -p "$ANCHOR_PID" | awk '{$1=$1; print}')" "$fault request lost its original guardian"
    assert_absent "$lab/peer-observer" "$fault request reached retirement effects"
    assert_retirement_preserved "$lab" "$ANCHOR_RECORD" "$trust_before"
  done
  out=$("$LIVE_LAB" down "$lab" 2>&1)
  expect_code 0 "$?" "fresh valid request must retire after denied request files: $out"
  assert_absent "$lab" 'valid request did not retire its verified private lab'
  case "$(ps -o stat= -p "$ANCHOR_PID" 2>/dev/null | awk '{$1=$1; print}')" in ''|Z*) ;; *) fail 'valid request left its guardian live' ;; esac
  kill -0 "$RETIREMENT_SENTINEL" || fail 'valid request signalled the unrelated sentinel'
  assert_absent "$RETIREMENT_SENTINEL_SIGNALS" 'valid request sent an unrelated signal'
  pass 'missing, malformed, foreign, stale, linked and FIFO retirement requests leave owner and evidence intact; a valid request retires safely'
}

test_guardian_without_legacy_roots() {
  local lab fault out trust_before attempt rc expected observed
  start_retirement_sentinel
  for fault in current missing stale; do
    lab=$(make_lab "guardian-no-wrapper-$fault" claude)
    start_retirement_anchor "$lab"
    if [ "$fault" = current ]; then
      expected=$(python3 "$ROOT/bin/fm-lab-launch.py" anchors "$lab") || fail 'cannot observe current guardian'
      observed=$(TZ=HST10 python3 "$ROOT/bin/fm-lab-launch.py" anchors "$lab") || fail 'timezone changed the current guardian identity'
      [ -n "$expected" ] || fail 'timezone identity regression has no live guardian'
      assert_equals "$expected" "$observed" 'guardian identity must be independent of caller timezone'
    fi
    lab_tmux "$lab" kill-server || fail 'cannot stop the owned fixture tmux server'
    kill -TERM "$ANCHOR_WRAPPER" || fail 'cannot stop the owned launcher wrapper'
    for ((attempt=0; attempt<50; attempt++)); do
      case "$(ps -o stat= -p "$ANCHOR_WRAPPER" 2>/dev/null | awk '{$1=$1; print}')" in ''|Z*) break ;; esac
      sleep .1
    done
    [ "$attempt" -lt 50 ] || fail 'owned wrapper did not exit before first cleanup'
    kill -0 "$ANCHOR_PID" || fail 'wrapper exit lost the continuous guardian'
    cp "$ANCHOR_RECORD" "$lab/guard-saved"
    trust_before=$(digest "$HOME/.claude.json")
    case "$fault" in
      missing) rm "$ANCHOR_RECORD" ;;
      stale) python3 -c 'import json,pathlib,sys; p=pathlib.Path(sys.argv[1]); d=json.loads(p.read_text()); d["start"]="Mon Jan 1 00:00:00 1990"; p.write_text(json.dumps(d))' "$ANCHOR_RECORD" ;;
    esac
    out=$(TZ=HST10 "$LIVE_LAB" down "$lab" 2>&1)
    rc=$?
    if [ "$fault" = current ]; then
      expect_code 0 "$rc" "current guardian must own cleanup after legacy roots exit: $out"
    else
      [ "$rc" -ne 0 ] || fail "$fault guardian supplied cleanup authority after legacy roots exited"
      assert_present "$lab/.fm-live-lab" 'denied guardian lost evidence after wrapper exit'
      assert_equals "$trust_before" "$(digest "$HOME/.claude.json")" 'denied guardian changed trust after wrapper exit'
      kill -0 "$ANCHOR_PID" || fail 'denied guardian was signalled after wrapper exit'
      cp "$lab/guard-saved" "$ANCHOR_RECORD"
      out=$("$LIVE_LAB" down "$lab" 2>&1)
      expect_code 0 "$?" "restored guardian must permit cleanup after legacy roots exit: $out"
    fi
    assert_absent "$lab" 'verified guardian did not remove its lab after legacy roots exited'
    case "$(ps -o stat= -p "$ANCHOR_PID" 2>/dev/null | awk '{$1=$1; print}')" in ''|Z*) ;; *) fail 'cleanup after wrapper exit left its guardian live' ;; esac
    kill -0 "$RETIREMENT_SENTINEL" || fail 'cleanup after wrapper exit signalled its sentinel'
    assert_absent "$RETIREMENT_SENTINEL_SIGNALS" 'cleanup after wrapper exit sent an unrelated signal'
  done
  pass 'only a current guardian supplies first-cleanup authority after owned wrapper and server roots exit'
}

test_late_child_cleanup() {
# A recorded process can create a new descendant only after TERM arrives.
LATE=$(make_lab late claude)
cat > "$TMP_ROOT/late-rewriter.sh" <<'SH'
store=$1 key=$2 marker=$3
trap 'bash -c '\''sleep 1; node -e "const fs=require(\"node:fs\");const [s,k]=process.argv.slice(1);const j=JSON.parse(fs.readFileSync(s,\"utf8\"));j.projects[k]={hasTrustDialogAccepted:true};fs.writeFileSync(s,JSON.stringify(j))" "$1" "$2"'\'' _ "$store" "$key" >/dev/null 2>&1 & fm_test_track_child "$!"; echo $! > "$marker"; exit 0' TERM
echo ready > "$marker.ready"
while :; do sleep 0.1; done
SH
start_group "$LIVE_LAB" launch "$LATE" -- bash "$TMP_ROOT/late-rewriter.sh" "$HOME/.claude.json" "$LATE/home" "$TMP_ROOT/late-child"
LATE_ROOT=$!
printf '%s\n' "$LATE_ROOT" >> "$TMP_ROOT/pids"
for ((attempt=0; attempt<50; attempt++)); do
  [ -s "$TMP_ROOT/late-child.ready" ] && break
  sleep 0.1
done
assert_present "$TMP_ROOT/late-child.ready" "TERM fixture installed its handler before down"
record_pid "$LATE" "$LATE_ROOT"
LAUNCH_TARGET=$(python3 - "$LATE/.fm-lab-anchor-$LATE_ROOT" <<'PYTARGET'
import json,sys
print(json.load(open(sys.argv[1]))['child'])
PYTARGET
)
LATE_ROOT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$LATE/.fm-lab-anchor-$LATE_ROOT")
fm_test_track_child "$LATE_ROOT" kill
fm_test_track_child "$LAUNCH_TARGET" kill
mkdir "$TMP_ROOT/late-ps"
REAL_PS=$(command -v ps)
cat > "$TMP_ROOT/late-ps/ps" <<'SHPS'
#!/usr/bin/env bash
if [ "${1:-}" = -axo ] && [ "${2:-}" = 'pid=,ppid=,pgid=,stat=,lstart=' ]; then
  n=$(cat "$LATE_COUNT" 2>/dev/null || echo 0)
  n=$((n+1)); echo "$n" > "$LATE_COUNT"
  if [ "$n" = 4 ]; then
    for ((i=0; i<50; i++)); do [ -s "$LATE_MARKER" ] && break; sleep .1; done
    child=$(cat "$LATE_MARKER") || exit 1
    [ "$("$REAL_PS" -o pgid= -p "$child" | tr -d ' ')" = "$LATE_TARGET" ] || exit 1
    fm_test_track_child "$child" kill || exit 1
    kill -STOP "$child" || exit 1
    for ((i=0; i<50; i++)); do kill -0 "$LATE_TARGET" 2>/dev/null || break; sleep .1; done
    ! kill -0 "$LATE_TARGET" 2>/dev/null || exit 1
    kill -0 "$LATE_ANCHOR" || exit 1
    "$REAL_PS" -o stat= -p "$child" | grep -q '^[[:space:]]*T' || exit 1
    touch "$LATE_COUNT.proved"
    [ "${FM_LIVE_LAB_TEST_GROUP:-}" != late-child-cleanup-failure ] || exit 1
  fi
fi
exec "$REAL_PS" "$@"
SHPS
chmod +x "$TMP_ROOT/late-ps/ps"
out=$(REAL_PS="$REAL_PS" LATE_COUNT="$TMP_ROOT/late-count" LATE_MARKER="$TMP_ROOT/late-child" LATE_TARGET="$LAUNCH_TARGET" LATE_ANCHOR="$LATE_ROOT" PATH="$TMP_ROOT/late-ps:$PATH" "$LIVE_LAB" down "$LATE" 2>&1)
late_rc=$?
if [ "${FM_LIVE_LAB_TEST_GROUP:-}" = late-child-cleanup-failure ]; then
  [ "$late_rc" -ne 0 ] || fail 'forced stopped-child observation failure was accepted'
  assert_present "$TMP_ROOT/late-count.proved" 'forced failure did not reach the real stopped late child'
  assert_present "$LATE/.fm-live-lab" 'failed down removed its ownership evidence'
  LATE_CHILD=$(cat "$TMP_ROOT/late-child")
  live_lab_cleanup 1 || fail 'fixture could not retire its stopped late child after failed down'
  case "$(ps -o stat= -p "$LATE_CHILD" 2>/dev/null | awk '{$1=$1; print}')" in ''|Z*) ;; *) fail 'fixture cleanup left the stopped late child live' ;; esac
  assert_present "$FM_TEST_CHILD_REGISTRY.history" 'failed cleanup lost its archived identities'
  assert_present "$FM_TEST_CHILD_REGISTRY.custody.json" 'failed cleanup lost its completed ownership proof'
  assert_present "$LATE/.fm-live-lab" 'fixture erased failure evidence before review'
  trap - EXIT
  pass 'a failed down after the controlled STOP retires the identity-captured child and retains failure evidence'
  exit 0
fi
expect_code 0 "$late_rc" "down waits for a child born during TERM: $out"
assert_present "$TMP_ROOT/late-child" "TERM handler spawned a child"
assert_present "$TMP_ROOT/late-count.proved" "real fourth snapshot observed target reaping with a live launch anchor and stopped late child"
LATE_CHILD=$(cat "$TMP_ROOT/late-child")
fm_test_track_child "$LATE_CHILD" kill
printf '%s\n' "$LATE_CHILD" >> "$TMP_ROOT/pids"
case "$(ps -o stat= -p "$LATE_CHILD" 2>/dev/null | awk '{$1=$1; print}')" in ''|Z*) ;; *) fail "down leaves a TERM-spawned child alive" ;; esac
lab_keys=$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));console.log(Object.keys(j.projects).filter(k=>k.startsWith(process.argv[2])).join(" "))' "$HOME/.claude.json" "$LATE")
assert_equals "" "$lab_keys" "TERM-spawned child cannot re-add trust after down"
pass "down tracks descendants spawned during TERM"
}

case ${FM_LIVE_LAB_TEST_GROUP:-all} in
  all) ;;
  late-child-cleanup-failure) test_late_child_cleanup; exit 0 ;;
  retirement)
    test_retirement_effect_boundary
    test_guardian_observation_retry
    test_guardian_acknowledgement_retry
    test_guardian_request_replay
    test_guardian_invalid_requests
    test_guardian_without_legacy_roots
    exit 0
    ;;
  retirement-boundary) test_retirement_effect_boundary; test_guardian_without_legacy_roots; exit 0 ;;
  retirement-observer) test_guardian_observation_retry; test_guardian_acknowledgement_retry; test_guardian_request_replay; test_guardian_invalid_requests; exit 0 ;;
  *) fail 'unknown FM_LIVE_LAB_TEST_GROUP' ;;
esac

# ---- Claude lab: every check passes on the shape up builds -----------------

C=$(make_lab c claude)
CH="$C/home"
run_check "$C"
expect_code 0 "$CHECK_RC" "a Claude lab in up's shape is ready: $CHECK_OUT"
for name in primary probe trust mirror host watcher mate worker treehouse; do
  assert_contains "$CHECK_OUT" "ok $name:" "the $name check passes on a ready Claude lab"
done
pass "a ready Claude lab passes every readiness check"

# Names may contain the printable format delimiter. Compare the entire name,
# and never let an absent name fall back to its existing prefix window.
DELIMITED_MATE=$(lab_tmux "$C" new-window -d -P -F '#{window_id}' -t firstmate: -n "fm-$MATE_ID:detail" -c "$C/mate" 'exec sleep 600')
fm_write_meta "$CH/state/$MATE_ID.meta" "window=firstmate:fm-$MATE_ID:detail"
run_check "$C"
expect_code 0 "$CHECK_RC" "readiness resolves the complete punctuated window name: $CHECK_OUT"
fm_write_meta "$CH/state/$MATE_ID.meta" "window=firstmate:fm-$MATE_ID:missing"
run_check "$C"
expect_code 1 "$CHECK_RC" 'a missing punctuated name must not select the existing prefix window'
assert_contains "$CHECK_OUT" "fail mate: the $MATE_ID window is not running" 'missing punctuated window is refused'
fm_write_meta "$CH/state/$MATE_ID.meta" "window=firstmate:fm-$MATE_ID" "tasktmp=/tmp/fm-$MATE_ID"
lab_tmux "$C" kill-window -t "$DELIMITED_MATE"
pass 'readiness matches complete window names without relying on control-character separators'

# primary: the lab session lock must name a live process (session start ran).
printf '999999\n' > "$CH/state/.lock"
run_check "$C"
expect_code 1 "$CHECK_RC" "a dead session lock is not ready"
assert_contains "$CHECK_OUT" "fail primary: the lab session lock names no live process" "primary names the dead lock"
lab_tmux "$C" display-message -p -t firstmate:=main '#{pane_pid}' > "$CH/state/.lock"
pass "primary fails when session start never took the lab lock"

# primary: a lab home that is a linked worktree is not the genuine primary
# checkout a mirrored Claude primary needs.
WT_CASE="$TMP_ROOT/wtcase"
fm_git_worktree "$WT_CASE/project" "$WT_CASE/wt" lab-wt
cp "$C/.fm-live-lab" "$WT_CASE/.fm-live-lab"
set_record "$WT_CASE" home "$WT_CASE/wt"
lab_tmux "$C" new-window -d -t firstmate: -n wtmain -c "$WT_CASE/wt" 'exec sleep 600'
lab_tmux "$C" kill-window -t firstmate:=main
lab_tmux "$C" rename-window -t firstmate:=wtmain main
run_check "$WT_CASE"
assert_contains "$CHECK_OUT" "fail primary: the lab home is not a primary checkout" "primary refuses a linked-worktree home"
lab_tmux "$C" kill-window -t firstmate:=main
lab_tmux "$C" new-window -d -t firstmate: -n main -c "$CH" "printf 'LABREADY-$NONCE\n'; exec sleep 600"
lab_tmux "$C" display-message -p -t firstmate:=main '#{pane_pid}' > "$CH/state/.lock"
pass "primary fails when the primary runs in a linked worktree instead of the lab's primary checkout"

# probe: the nonce reply proves the model is accepted and a turn completed.
set_record "$C" nonce 00000000
run_check "$C"
assert_contains "$CHECK_OUT" "fail probe: no LABREADY-00000000 reply" "probe names the missing reply"
set_record "$C" nonce "$NONCE"
pass "probe fails when the primary never answered its nonce"

# trust: the workspace-trust prompt wedged the first lab.
cp "$HOME/.claude.json" "$TMP_ROOT/claude.json.keep"
node -e 'const fs=require("node:fs");const [s,h]=process.argv.slice(1);const j=JSON.parse(fs.readFileSync(s,"utf8"));delete j.projects[h];fs.writeFileSync(s,JSON.stringify(j))' "$HOME/.claude.json" "$CH"
run_check "$C"
assert_contains "$CHECK_OUT" "fail trust: $CH has no registered Claude workspace trust" "trust names the untrusted home"
cp "$TMP_ROOT/claude.json.keep" "$HOME/.claude.json"
pass "trust fails when the lab home has no registered Claude trust"

# mirror: the dialog mirror feed must be wired and hold both sides.
cp "$CH/state/.host-mirror.jsonl" "$TMP_ROOT/mirror.keep"
head -n 1 "$TMP_ROOT/mirror.keep" > "$CH/state/.host-mirror.jsonl"
run_check "$C"
assert_contains "$CHECK_OUT" "fail mirror: the dialog mirror has no captain and main entry yet (captain=1 main=0)" "mirror needs a main entry"
rm -f "$CH/state/.host-mirror.jsonl"
run_check "$C"
assert_contains "$CHECK_OUT" "fail mirror: fm-host-mirror.sh check exited 1" "mirror fails without a mirror file"
cp "$TMP_ROOT/mirror.keep" "$CH/state/.host-mirror.jsonl"
pass "mirror fails when the feed is unwired or has not recorded a whole turn"

# host: expected on Claude, refused when it should be absent.
host_pid=$(awk -F '\t' '{print $2}' "$CH/state/.supervision-host")
kill "$host_pid" 2>/dev/null
wait "$host_pid" 2>/dev/null
run_check "$C"
assert_contains "$CHECK_OUT" "fail host: no live supervision host (expected one)" "host names the missing host"
set_record "$C" expect_host no
run_check "$C"
assert_contains "$CHECK_OUT" "ok host: none running, as expected" "an opted-out lab expects no host"
assert_not_contains "$CHECK_OUT" "mirror" "an opted-out lab skips the mirror"
host_pid=$(start_sleeper)
printf 'host\t%s\tx\n' "$host_pid" > "$CH/state/.supervision-host"
run_check "$C"
assert_contains "$CHECK_OUT" "fail host: supervision host pid $host_pid runs (expected none)" "an opted-out lab refuses a host"
set_record "$C" expect_host yes
pass "host passes and fails according to --expect-host"

# watcher: a stale beacon is not supervision.
touch -t 202001010000 "$CH/state/.last-watcher-beat"
run_check "$C"
assert_contains "$CHECK_OUT" "fail watcher: no live watcher with a fresh beacon" "watcher names the stale beacon"
touch "$CH/state/.last-watcher-beat"
pass "watcher fails on a stale beacon"

# mate: its own window, targeted exactly. A missing window must not resolve to
# another one (tmux falls back to the current window for an unknown name).
lab_tmux "$C" kill-window -t "firstmate:=fm-$MATE_ID"
run_check "$C"
assert_contains "$CHECK_OUT" "fail mate: the $MATE_ID window is not running" "mate names its missing window"
lab_tmux "$C" new-window -d -t firstmate: -n "fm-$MATE_ID" -c "$C/mate" 'exec sleep 600'
rm -f "$C/mate/state/.lock"
run_check "$C"
assert_contains "$CHECK_OUT" "fail mate: the mate holds no session lock yet" "mate needs its own session lock"
lab_tmux "$C" display-message -p -t "firstmate:=fm-$MATE_ID" '#{pane_pid}' > "$C/mate/state/.lock"
pass "mate fails when its window is gone or it never reached its charter"

# Opt-out readiness must observe the mate's inherited material and its real
# home gate, rather than just the primary's absent host.
set_record "$C" host_off yes
set_record "$C" expect_host no
host_pid=$(awk -F '\t' '{print $2}' "$CH/state/.supervision-host")
kill "$host_pid" 2>/dev/null
wait "$host_pid" 2>/dev/null
mkdir -p "$C/mate/config" "$C/mate/bin"
cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$C/mate/bin/"
run_check "$C"
expect_code 1 "$CHECK_RC" "off readiness refuses a mate without its inherited flag"
assert_contains "$CHECK_OUT" "fail mate: the inherited supervision-host-off flag is missing" "mate names the missing opt-out"
: > "$C/mate/config/supervision-host-off"
run_check "$C"
expect_code 0 "$CHECK_RC" "off readiness accepts the mate's inherited flag and disabled gate: $CHECK_OUT"
printf '#!/usr/bin/env bash\nexit 0\n' > "$C/mate/bin/fm-supervision-engine-lib.sh"
run_check "$C"
expect_code 1 "$CHECK_RC" "off readiness refuses a mate whose gate reads on"
assert_contains "$CHECK_OUT" "fail mate: the supervision-host gate did not read off" "mate names the enabled gate"
cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$C/mate/bin/"
set_record "$C" host_off no
set_record "$C" expect_host yes
printf 'host\t%s\tx\n' "$(start_sleeper)" > "$CH/state/.supervision-host"
pass "mate off readiness requires inherited material and a disabled home gate"

# The current-state reader, not an old event, establishes the gate wait.
GATE="$CH/data/$WORKER_ID/gate"
assert_contains "$(sed -n 's/^gate=//p' "$C/.fm-live-lab")" "$CH/data/$WORKER_ID/" "operator can find the gate in the worker's task directory"
: > "$CH/state/$WORKER_ID.status"
run_check "$C"
assert_contains "$CHECK_OUT" "fail worker: the worker is not currently parked" "worker needs a current pause"
printf 'paused [at=1]: waiting on gate file %s to exist\n' "$GATE" > "$CH/state/$WORKER_ID.status"
printf 'working [at=2]: resumed\n' >> "$CH/state/$WORKER_ID.status"
run_check "$C"
assert_contains "$CHECK_OUT" "fail worker: the worker is not currently parked" "stale paused event cannot pass readiness"
printf 'paused [at=3]: waiting on gate file %s to exist\n' "$GATE" >> "$CH/state/$WORKER_ID.status"
run_check "$C"
assert_contains "$CHECK_OUT" "ok worker: $WORKER_ID parked on $GATE" "current pause passes readiness"
pass "worker readiness follows current crew state and the recorded accessible gate"

# treehouse: a worker pool must land inside the lab, never in ~/.treehouse.
mkdir "$HOME/.treehouse/notes-leaked"
run_check "$C"
assert_contains "$CHECK_OUT" "fail treehouse: new ~/.treehouse entries: notes-leaked" "treehouse names the leaked pool"
rmdir "$HOME/.treehouse/notes-leaked"
LATER_HOME="$TMP_ROOT/later-home"
mkdir -p "$LATER_HOME"
CHECK_OUT=$(HOME="$LATER_HOME" "$LIVE_LAB" check "$C" 2>&1)
expect_code 0 "$?" "the Claude lab is ready again after every restore, even from a shell with another HOME: $CHECK_OUT"
pass "treehouse fails when a pool lands in ~/.treehouse"

# ---- Pi lab: extensions and the session-only trust store -------------------

P=$(make_lab p pi)
PH="$P/home"
run_check "$P"
expect_code 0 "$CHECK_RC" "a Pi lab in up's shape is ready: $CHECK_OUT"
assert_contains "$CHECK_OUT" "ok extensions: fm-primary-pi-watch fm-primary-turnend-guard fm-branch-supervision" "all three extensions load"
assert_contains "$CHECK_OUT" "ok trust: Pi trust store unchanged" "the Pi trust store is untouched"
assert_not_contains "$CHECK_OUT" "mirror" "a Pi lab has no host mirror check"
rm -f "$PH/state/.pi-branch-extension-loaded"
run_check "$P"
assert_contains "$CHECK_OUT" "fail extensions: fm-branch-supervision.ts is not loaded by the lock holder" "the missing branch extension is named"
printf '%s\n' "$(sed -n 1p "$PH/state/.lock")" > "$PH/state/.pi-branch-extension-loaded"
printf 'stale\n' > "$PH/state/.pi-turnend-extension-loaded"
run_check "$P"
assert_contains "$CHECK_OUT" "fail extensions: fm-primary-turnend-guard.ts is not loaded at its current build" "a stale turn-end build is named"
pass "extensions fail when the Pi lab lacks the branch extension or loads a stale build"

# ---- down -------------------------------------------------------------------

NOT_LAB="$TMP_ROOT/not-a-lab"
mkdir -p "$NOT_LAB/keep"
out=$("$LIVE_LAB" down "$NOT_LAB" 2>&1)
expect_code 1 "$?" "down refuses a path without a lab record"
assert_contains "$out" "carries no lab record" "the refusal names the missing record"
assert_present "$NOT_LAB/keep" "a refused down removes nothing"
pass "down refuses anything up did not build"

C_HASH=$(printf '%s' "$CH" | shasum -a 256 | awk '{print $1}')
OTHER_ID="labt$$-other"
fm_write_meta "$CH/state/$OTHER_ID.meta" "window=firstmate:fm-$OTHER_ID" "tasktmp=/tmp/fm-$OTHER_ID"
mkdir -p "/tmp/fm-$WORKER_ID/gotmp" "/tmp/fm-$MATE_ID" "/tmp/fm-$WORKER_ID+$C_HASH" "/tmp/fm-$OTHER_ID+$C_HASH" "/tmp/fm-$OTHER_ID"
# An outsider opening a lab path is not owned by the lab.
printf 'sleep 600\n' > "$C/stray.sh"
bash "$C/stray.sh" >/dev/null 2>&1 &
STRAY=$!
fm_test_track_child "$STRAY"
printf '%s\n' "$STRAY" >> "$TMP_ROOT/pids"
until STRAY_CHILD=$(pgrep -P "$STRAY" sleep); do sleep 0.1; done
fm_test_track_child "$STRAY_CHILD"
printf '%s\n' "$STRAY_CHILD" >> "$TMP_ROOT/pids"
# A launch-recorded process and its child must be stopped even when not in tmux.
start_group sleep 600
OWNED=$!
printf '%s\n' "$OWNED" >> "$TMP_ROOT/pids"
record_pid "$C" "$OWNED"
# A process in the runner's group is not part of any recorded lab group.
sleep 600 >/dev/null 2>&1 &
UNRELATED=$!
fm_test_track_child "$UNRELATED"
printf '%s\n' "$UNRELATED" >> "$TMP_ROOT/pids"
[ "$(ps -o pgid= -p "$UNRELATED" | awk '{$1=$1; print}')" != "$(ps -o pgid= -p "$OWNED" | awk '{$1=$1; print}')" ] || fail "fixture roots must have their own group"
# A sibling lab root that shares this root as a string prefix is not this lab.
mkdir -p "${C}2"
printf 'sleep 600\n' > "${C}2/stray.sh"
bash "${C}2/stray.sh" 2>/dev/null &
SIBLING=$!
fm_test_track_child "$SIBLING"
printf '%s\n' "$SIBLING" >> "$TMP_ROOT/pids"
# The worker spawn failed after keeping its task temp dirs, before its meta.
rm -f "$CH/state/$WORKER_ID.meta"
C_TMUX=$(sed -n 's/^tmux_dir=//p' "$C/.fm-live-lab")
out=$(HOME="$LATER_HOME" "$LIVE_LAB" down "$C" 2>&1)
expect_code 0 "$?" "down of a clean Claude lab succeeds from a shell with another HOME: $out"
kill -0 "$STRAY" 2>/dev/null || fail "down leaves unrelated processes opening the lab path alone"
kill -0 "$STRAY_CHILD" 2>/dev/null || fail "down leaves their descendants alone"
! kill -0 "$OWNED" 2>/dev/null || fail "down stops recorded launch processes"
kill -0 "$UNRELATED" 2>/dev/null || fail "down signalled an unrelated process outside recorded groups"
assert_absent "$C" "down removes the lab root"
kill -0 "$SIBLING" 2>/dev/null || fail "down leaves a sibling root's process running"
pkill -P "$SIBLING" 2>/dev/null
kill "$SIBLING" 2>/dev/null
assert_absent "$C_TMUX" "down removes the private tmux directory"
assert_absent "/tmp/fm-$WORKER_ID" "down removes the worker's task temp dir, even without its meta"
assert_absent "/tmp/fm-$MATE_ID" "down removes the mate's task temp dir"
assert_absent "/tmp/fm-$WORKER_ID+$C_HASH" "down removes the worker's launch dir"
assert_absent "/tmp/fm-$OTHER_ID+$C_HASH" "down removes a lab-spawned task's launch dir scoped to the lab home"
assert_present "/tmp/fm-$OTHER_ID" "down keeps a task temp dir another home could share"
kept=$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));console.log(JSON.stringify([j.keep,Object.keys(j.projects).sort()]))' "$HOME/.claude.json")
assert_equals '[1,["/elsewhere/project"]]' "$kept" "down removes exactly the lab's Claude project entries"
assert_contains "$out" "removed: 2 Claude project entries" "down reports the removed entries"
kill "$STRAY" "$STRAY_CHILD" 2>/dev/null || true
pass "down stops only recorded lab processes, removes trust entries and task temp dirs"

# The Claude store up selected is the one check and down use, even from a later
# shell with another CLAUDE_CONFIG_DIR, and a symlinked store stays a symlink.
SC="$TMP_ROOT/claude-config"
mkdir -p "$SC"
S=$(make_lab s claude "$SC")
mv "$SC/.claude.json" "$TMP_ROOT/claude-store-target.json"
ln -s "$TMP_ROOT/claude-store-target.json" "$SC/.claude.json"
HOME_STORE_BEFORE=$(digest "$HOME/.claude.json")
CHECK_OUT=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/other-config" "$LIVE_LAB" check "$S" 2>&1)
assert_contains "$CHECK_OUT" "ok trust: $S/home is trusted in the Claude store" "check reads the recorded store"
out=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/other-config" "$LIVE_LAB" down "$S" 2>&1)
expect_code 0 "$?" "down of a lab on a configured store succeeds: $out"
assert_contains "$out" "removed: 2 Claude project entries" "down removes the entries from the recorded store"
[ -L "$SC/.claude.json" ] || fail "down keeps a symlinked Claude store a symlink"
kept=$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));console.log(JSON.stringify([j.keep,Object.keys(j.projects).sort()]))' "$TMP_ROOT/claude-store-target.json")
assert_equals '[1,["/elsewhere/project"]]' "$kept" "down rewrites the symlink's target"
assert_equals "$HOME_STORE_BEFORE" "$(digest "$HOME/.claude.json")" "down leaves the default store alone"
pass "check and down use the recorded Claude store and keep a symlinked store linked"

# TERM handlers may write trust again, and an uncooperative lab process must
# be killed before the store or lab directory is removed.
X=$(make_lab x claude)
cat > "$TMP_ROOT/exit-rewriter.sh" <<'SH'
store=$1 key=$2 marker=$3
trap 'sleep 1; node -e "const fs=require(\"node:fs\");const [s,k]=process.argv.slice(1);const j=JSON.parse(fs.readFileSync(s,\"utf8\"));j.projects[k]={hasTrustDialogAccepted:true};fs.writeFileSync(s,JSON.stringify(j))" "$store" "$key"; echo rewrote > "$marker"; exit 0' TERM
while :; do sleep 0.1; done
SH
start_group bash "$TMP_ROOT/exit-rewriter.sh" "$HOME/.claude.json" "$X/home" "$TMP_ROOT/rewrote"
REWRITER=$!
start_group bash -c 'trap "" TERM; while :; do sleep 0.1; done'
STUBBORN=$!
sleep 0.2
printf '%s\n%s\n' "$REWRITER" "$STUBBORN" >> "$TMP_ROOT/pids"
record_pid "$X" "$REWRITER"
record_pid "$X" "$STUBBORN"
out=$("$LIVE_LAB" down "$X" 2>&1)
expect_code 0 "$?" "down waits for lab processes: $out"
wait "$REWRITER" 2>/dev/null || true
assert_equals rewrote "$(cat "$TMP_ROOT/rewrote" 2>/dev/null)" "TERM handler rewrote its Claude key before down returned"
! kill -0 "$STUBBORN" 2>/dev/null || fail "down must kill a TERM-resistant lab process"
sleep 1.5
lab_keys=$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));console.log(Object.keys(j.projects).filter(k=>k.startsWith(process.argv[2])).join(" "))' "$HOME/.claude.json" "$X")
assert_equals "" "$lab_keys" "no exiting lab process re-adds Claude trust"
pass "down waits for TERM handlers and escalates before removing trust"

# A pane root may exit on TERM while its child remains alive, reparented and
# still able to write Claude trust. Teardown must wait for the captured child.
ORPHAN=$(make_lab orphan claude)
cat > "$TMP_ROOT/orphan-rewriter.sh" <<'SH'
store=$1 key=$2 marker=$3
trap 'sleep 1; node -e "const fs=require(\"node:fs\");const [s,k]=process.argv.slice(1);const j=JSON.parse(fs.readFileSync(s,\"utf8\"));j.projects[k]={hasTrustDialogAccepted:true};fs.writeFileSync(s,JSON.stringify(j))" "$store" "$key"; echo rewrote > "$marker"; exit 0' TERM
while :; do sleep 0.1; done
SH
# shellcheck disable=SC2016 # Positional parameters expand in the launched shell.
start_group bash -c 'bash "$1" "$2" "$3" "$4" & echo $! > "$5"; while :; do sleep 0.1; done' _ \
  "$TMP_ROOT/orphan-rewriter.sh" "$HOME/.claude.json" "$ORPHAN/home" "$TMP_ROOT/orphan-rewrote" "$TMP_ROOT/orphan-child"
ORPHAN_ROOT=$!
until [ -s "$TMP_ROOT/orphan-child" ]; do sleep 0.1; done
ORPHAN_CHILD=$(cat "$TMP_ROOT/orphan-child")
fm_test_track_child "$ORPHAN_CHILD" kill
printf '%s\n%s\n' "$ORPHAN_ROOT" "$ORPHAN_CHILD" >> "$TMP_ROOT/pids"
record_pid "$ORPHAN" "$ORPHAN_ROOT"
out=$("$LIVE_LAB" down "$ORPHAN" 2>&1)
expect_code 0 "$?" "down waits for a reparented child: $out"
assert_equals rewrote "$(cat "$TMP_ROOT/orphan-rewrote" 2>/dev/null)" "child finished its TERM handler before cleanup"
lab_keys=$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));console.log(Object.keys(j.projects).filter(k=>k.startsWith(process.argv[2])).join(" "))' "$HOME/.claude.json" "$ORPHAN")
assert_equals "" "$lab_keys" "reparented child cannot re-add trust after down"
pass "down waits for captured descendants after their root exits"

test_late_child_cleanup

for fault in missing malformed foreign stale linked fifo; do
  ANCHORED=$(make_lab "anchor-$fault" claude)
  start_group "$LIVE_LAB" launch "$ANCHORED" -- sleep 45
  anchor=$!
  printf '%s\n' "$anchor" >> "$TMP_ROOT/pids"
  for ((i=0; i<50; i++)); do
    [ -f "$ANCHORED/.fm-lab-anchor-$anchor" ] && grep -q '"child"' "$ANCHORED/.fm-lab-anchor-$anchor" && break
    sleep .1
  done
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert type(d.get("child")) is int and d["child"]>1' "$ANCHORED/.fm-lab-anchor-$anchor" || fail 'launch ownership did not commit before the prerequisite bound'
  read -r anchor_guard anchor_child < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["pid"],d["child"])' "$ANCHORED/.fm-lab-anchor-$anchor")
  fm_test_track_child "$anchor_guard" kill
  fm_test_track_child "$anchor_child" kill
  cp "$ANCHORED/.fm-lab-anchor-$anchor" "$TMP_ROOT/anchor-saved" || fail 'cannot preserve the verified launch record'
  python3 - "$ANCHORED/.fm-lab-anchor-$anchor" "$fault" <<'PYFAULT'
import json,os,pathlib,sys
p=pathlib.Path(sys.argv[1]); fault=sys.argv[2]; data=json.loads(p.read_text())
if fault=='missing': p.unlink()
elif fault=='malformed': p.write_text('{')
elif fault=='linked':
    p.unlink()
    p.symlink_to(p.parent.parent / 'anchor-saved')
elif fault=='fifo':
    p.unlink()
    os.mkfifo(p, 0o600)
else:
    if fault=='foreign': data['root']='/foreign-lab'
    if fault=='stale': data['start']='Mon Jan 1 00:00:00 1990'
    p.write_text(json.dumps(data))
PYFAULT
  out=$("$LIVE_LAB" down "$ANCHORED" 2>&1)
  [ "$?" -ne 0 ] || fail "$fault launch ownership was accepted"
  assert_present "$ANCHORED/.fm-live-lab" 'denied launch ownership lost its lab evidence'
  kill -0 "$anchor" || fail 'denied launch record signalled its owner'
  kill -0 "$anchor_guard" || fail 'denied launch record lost its actual guardian'
  rm -f "$ANCHORED/.fm-lab-anchor-$anchor"
  cp "$TMP_ROOT/anchor-saved" "$ANCHORED/.fm-lab-anchor-$anchor"
  out=$("$LIVE_LAB" down "$ANCHORED" 2>&1)
  expect_code 0 "$?" "restored current launch ownership must permit cleanup: $out"
  wait "$anchor" 2>/dev/null || true
  assert_absent "$ANCHORED" 'verified launch fixture was not removed'
done
pass 'missing, malformed, foreign and stale launch ownership refuse before effects; verified records permit retirement'

RETRY_ANCHOR=$(make_lab anchored-retry claude)
cat > "$TMP_ROOT/anchor-retry.py" <<'PYRETRY'
import os, pathlib, signal, sys, time
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
if os.fork() == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
    time.sleep(45)
    sys.exit(0)
while True:
    time.sleep(.1)
PYRETRY
start_group "$LIVE_LAB" launch "$RETRY_ANCHOR" -- python3 "$TMP_ROOT/anchor-retry.py" "$TMP_ROOT/anchor-retry-child"
retry_guard=$!
printf '%s\n' "$retry_guard" >> "$TMP_ROOT/pids"
for ((i=0; i<50; i++)); do [ -s "$TMP_ROOT/anchor-retry-child" ] && break; sleep .1; done
assert_present "$TMP_ROOT/anchor-retry-child" 'anchored retry child did not start'
retry_child=$(cat "$TMP_ROOT/anchor-retry-child")
fm_test_track_child "$retry_child" kill
record_pid "$RETRY_ANCHOR" "$retry_guard"
retry_guard=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$RETRY_ANCHOR/.fm-lab-anchor-$retry_guard")
fm_test_track_child "$retry_guard" kill
mkdir "$TMP_ROOT/retry-ps"
cat > "$TMP_ROOT/retry-ps/ps" <<'SHRETRY'
#!/usr/bin/env bash
"$REAL_PS" "$@"
rc=$?
[ "$rc" = 0 ] || exit "$rc"
if [ "${1:-}" = -axo ] && [ "${2:-}" = 'pid=,ppid=,pgid=,stat=,lstart=' ]; then
  n=$(cat "$RETRY_COUNT" 2>/dev/null || echo 0)
  n=$((n+1)); echo "$n" > "$RETRY_COUNT"
  [ "$n" != 4 ] || exit 1
fi
SHRETRY
chmod +x "$TMP_ROOT/retry-ps/ps"
out=$(REAL_PS="$(command -v ps)" RETRY_COUNT="$TMP_ROOT/retry-count" PATH="$TMP_ROOT/retry-ps:$PATH" "$LIVE_LAB" down "$RETRY_ANCHOR" 2>&1)
[ "$?" -ne 0 ] || fail 'anchored cleanup ignored failed post-TERM observation'
assert_present "$RETRY_ANCHOR/.fm-live-lab" 'anchored failure discarded its custody record'
kill -0 "$retry_guard" || fail 'failed observation lost the continuous owner'
kill -0 "$retry_child" || fail 'retry fixture child did not survive the failed observation'
out=$("$LIVE_LAB" launch "$RETRY_ANCHOR" -- touch "$RETRY_ANCHOR/forbidden" 2>&1)
[ "$?" -ne 0 ] || fail 'sealed cleanup accepted a new launch'
assert_absent "$RETRY_ANCHOR/forbidden" 'sealed launch ran its command'
out=$("$LIVE_LAB" down "$RETRY_ANCHOR" 2>&1)
expect_code 0 "$?" "fresh down lost its anchored descendant: $out"
wait "$retry_guard" 2>/dev/null || true
case "$(ps -o stat= -p "$retry_child" 2>/dev/null | awk '{$1=$1; print}')" in ''|Z*) ;; *) fail 'fresh down left its anchored descendant live' ;; esac
assert_absent "$RETRY_ANCHOR" 'anchored retry did not remove its verified disposable lab'
pass 'a continuous launch owner survives failed observation and fresh cleanup; sealed labs refuse new effects'

test_retirement_effect_boundary
test_guardian_observation_retry
test_guardian_acknowledgement_retry
test_guardian_request_replay
test_guardian_invalid_requests
test_guardian_without_legacy_roots

# A reused PID with a different start time must not own its new process tree.
Y=$(make_lab y claude)
# shellcheck disable=SC2016 # Positional parameters expand in the launched shell.
start_group bash -c 'sleep 600 & echo $! > "$1"; wait' _ "$TMP_ROOT/reused-child"; REUSED=$!
until [ -s "$TMP_ROOT/reused-child" ]; do sleep 0.1; done
REUSED_CHILD=$(cat "$TMP_ROOT/reused-child")
fm_test_track_child "$REUSED_CHILD" kill
printf '%s\n%s\n' "$REUSED" "$REUSED_CHILD" >> "$TMP_ROOT/pids"
printf 'launch_pid=%s\nlaunch_start=Mon Jan  1 00:00:00 1990\n' "$REUSED" >> "$Y/.fm-live-lab"
out=$("$LIVE_LAB" down "$Y" 2>&1)
expect_code 0 "$?" "down skips the mismatched root: $out"
kill -0 "$REUSED" 2>/dev/null || fail "down killed a reused PID"
kill -0 "$REUSED_CHILD" 2>/dev/null || fail "down killed the reused PID's child"
pass "down ignores roots with mismatched start times"

GROUP_REUSE=$(make_lab group-reuse claude)
start_group python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(600)'
GROUP_ROOT=$!
start_group python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(600)'
WAIT_ROOT=$!
sleep 0.2
printf '%s\n%s\n' "$GROUP_ROOT" "$WAIT_ROOT" >> "$TMP_ROOT/pids"
record_pid "$GROUP_REUSE" "$GROUP_ROOT"
record_pid "$GROUP_REUSE" "$WAIT_ROOT"
sleep 600 >/dev/null 2>&1 &
GROUP_OUTSIDER=$!
fm_test_track_child "$GROUP_OUTSIDER"
printf '%s\n' "$GROUP_OUTSIDER" >> "$TMP_ROOT/pids"
GROUP_ID=$(ps -o pgid= -p "$GROUP_ROOT" | awk '{$1=$1; print}')
mkdir -p "$TMP_ROOT/group-ps-bin"
cat > "$TMP_ROOT/group-ps-bin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -axo ] && [ "${2:-}" = 'pid=,ppid=,pgid=,stat=,lstart=' ]; then
  count=$(cat "$PS_SCAN_COUNT" 2>/dev/null || echo 0)
  count=$((count + 1))
  echo "$count" > "$PS_SCAN_COUNT"
  "$REAL_PS" "$@" | awk -v scan="$count" -v root="$PS_GROUP_ROOT" -v outsider="$PS_OUTSIDER" -v group="$PS_GROUP_ID" '
    scan >= 2 && $1 == root { next }
    scan >= 2 && $1 == outsider { $3=group }
    { print }
  '
else
  "$REAL_PS" "$@"
fi
SH
chmod +x "$TMP_ROOT/group-ps-bin/ps"
out=$(REAL_PS="$(command -v ps)" PS_SCAN_COUNT="$TMP_ROOT/group-scan-count" PS_GROUP_ROOT="$GROUP_ROOT" PS_OUTSIDER="$GROUP_OUTSIDER" PS_GROUP_ID="$GROUP_ID" PATH="$TMP_ROOT/group-ps-bin:$PATH" "$LIVE_LAB" down "$GROUP_REUSE" 2>&1)
expect_code 0 "$?" "down ignores a reused group id: $out"
[ "$(cat "$TMP_ROOT/group-scan-count")" -ge 3 ] || fail "fixture did not expose the reused group id"
kill -0 "$GROUP_OUTSIDER" 2>/dev/null || fail "down signalled an unrelated process with a reused group id"
pass "down rejects reused groups without an empty intermediate snapshot"

# Simulate a recorded PID changing identity after TERM: the first process
# snapshot matches its start time, subsequent snapshots describe a reused PID.
Z=$(make_lab z claude)
start_group python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(600)'
REPLACED=$!
printf '%s\n' "$REPLACED" >> "$TMP_ROOT/pids"
record_pid "$Z" "$REPLACED"
mkdir -p "$TMP_ROOT/ps-bin"
printf '%s\n' "$REPLACED" > "$TMP_ROOT/replaced-pid"
cat > "$TMP_ROOT/ps-bin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -axo ] && [ "${2:-}" = 'pid=,ppid=,pgid=,stat=,lstart=' ]; then
  count=$(cat "$PS_COUNT" 2>/dev/null || echo 0)
  count=$((count + 1))
  echo "$count" > "$PS_COUNT"
  "$REAL_PS" "$@" | awk -v count="$count" -v target="$(cat "$PS_TARGET")" '
    count >= 4 && $1 == target { $5="Mon"; $6="Jan"; $7="1"; $8="00:00:00"; $9="1990" }
    {print}
  '
else
  "$REAL_PS" "$@"
fi
SH
chmod +x "$TMP_ROOT/ps-bin/ps"
start=$(date +%s)
out=$(REAL_PS="$(command -v ps)" PS_COUNT="$TMP_ROOT/ps-count" PS_TARGET="$TMP_ROOT/replaced-pid" PATH="$TMP_ROOT/ps-bin:$PATH" "$LIVE_LAB" down "$Z" 2>&1)
expect_code 0 "$?" "down must not treat the changed PID as a survivor: $out"
[ "$(( $(date +%s) - start ))" -lt 8 ] || fail "down waited on a PID with a different start time"
[ "$(cat "$TMP_ROOT/ps-count")" -ge 4 ] || fail "fixture never exposed replacement identity"
kill -0 "$REPLACED" 2>/dev/null || fail "down killed a PID after its recorded identity changed"
kill -KILL "$REPLACED" 2>/dev/null || true
wait "$REPLACED" 2>/dev/null || true
pass "down revalidates process identity during its bounded wait"

printf '{"trusted":["/somewhere"]}\n' > "$HOME/.pi/agent/trust.json"
run_check "$P"
assert_contains "$CHECK_OUT" "fail trust: the Pi trust store changed since up began" "a written Pi trust store is caught"
pass "trust fails on Pi when the lab wrote the persistent Pi trust store"

out=$("$LIVE_LAB" down "$P" 2>&1)
expect_code 1 "$?" "down reports a changed Pi trust store"
assert_contains "$out" "the Pi trust store changed since up began; left as is" "the Pi trust change is named"
assert_absent "$P" "the lab is still removed"
assert_equals '{"trusted":["/somewhere"]}' "$(cat "$HOME/.pi/agent/trust.json")" "down never rewrites the Pi trust store"
pass "down removes the lab but reports, without reverting, a written Pi trust store"

# ---- up argument safety -----------------------------------------------------

EXISTING="$TMP_ROOT/existing"
mkdir -p "$EXISTING/keep"
out=$("$LIVE_LAB" up --harness claude "$EXISTING" 2>&1)
expect_code 1 "$?" "up refuses an existing lab root"
assert_contains "$out" "a lab root must not exist yet" "the refusal names the existing root"
assert_present "$EXISTING/keep" "a refused up touches nothing"
out=$("$LIVE_LAB" up --harness codex "$TMP_ROOT/new" 2>&1)
expect_code 1 "$?" "up refuses an unsupported harness"
assert_absent "$TMP_ROOT/new" "a refused harness creates nothing"
pass "up refuses an existing root and an unsupported harness"

# up persists full-width, distinct task IDs even when checkout fails before
# launching a harness; down can still clean this partial lab.
PARTIAL="$TMP_ROOT/partial-lab"
mkdir -p "$TMP_ROOT/stub-bin"
cat > "$TMP_ROOT/stub-bin/claude" <<'SH'
#!/bin/sh
: > "$FM_HOME/state/.session-start-complete"
exec sleep 45 >/dev/null 2>&1
SH
chmod +x "$TMP_ROOT/stub-bin/claude"
out=$(PATH="$TMP_ROOT/stub-bin:$PATH" "$LIVE_LAB" up --harness claude --source "$TMP_ROOT/missing-origin" "$PARTIAL" 2>&1)
expect_code 1 "$?" "an unavailable source stops up before launch"
assert_present "$PARTIAL/.fm-live-lab" "up recorded its selected task IDs"
ids=$(awk -F= '/^(mate_id|worker_id)=/ {print $2}' "$PARTIAL/.fm-live-lab")
if ! printf '%s\n' "$ids" | grep -Eq '^lab[0-9a-f]{12}-(mate|worker)$'; then fail "task IDs need twelve nonce hex digits: $ids"; fi
assert_equals 2 "$(printf '%s\n' "$ids" | grep -Ec '^lab[0-9a-f]{12}-(mate|worker)$')" "both mate and worker use twelve nonce digits"
out=$($LIVE_LAB down "$PARTIAL" 2>&1)
expect_code 0 "$?" "down cleans a lab whose checkout failed: $out"
assert_absent "$PARTIAL" "partial lab removed"
pass "up gives both task IDs a long nonce and down cleans partial setup"
real_mktemp=$(command -v mktemp)
cat > "$TMP_ROOT/stub-bin/mktemp" <<SHMKTEMP
#!/usr/bin/env bash
if [ "\${2:-}" = /tmp/fmlab.XXXXXX ]; then
  exec "$real_mktemp" -d "$TMP_ROOT/default-fmlab.XXXXXX"
fi
exec "$real_mktemp" "\$@"
SHMKTEMP
chmod +x "$TMP_ROOT/stub-bin/mktemp"
for mask in 002 022; do
  for placement in explicit default; do
    partial="$TMP_ROOT/private-$mask-$placement"
    args=()
    [ "$placement" != explicit ] || args+=("$partial")
    out=$(umask "$mask"; PATH="$TMP_ROOT/stub-bin:$PATH" "$LIVE_LAB" up --harness claude --source "$TMP_ROOT/missing-origin" "${args[@]}" 2>&1)
    expect_code 1 "$?" 'unavailable source must stop private lab setup'
    partial=$(printf '%s\n' "$out" | sed -n 's/^lab: \(.*\) (tear down with:.*$/\1/p')
    [ -n "$partial" ] || fail 'private lab root was not reported'
    python3 - "$partial" <<'PYPERM'
import pathlib, stat, sys
root = pathlib.Path(sys.argv[1])
assert stat.S_IMODE(root.stat().st_mode) == 0o700
assert stat.S_IMODE((root / '.fm-live-lab').stat().st_mode) == 0o600
PYPERM
    out=$("$LIVE_LAB" down "$partial" 2>&1)
    expect_code 0 "$?" "private partial lab must remain cleanable: $out"
    assert_absent "$partial" 'private partial lab removed'
  done
done
pass 'explicit and default lab creation stays private and cleanable under umask 002 and 022'


# A rival Claude writer drops the newly registered primary key once. The
# stand-in primary checks the store on startup, while the readiness probe fails.
UPSRC="$TMP_ROOT/up-source"
mkdir -p "$UPSRC"
cp -R "$ROOT/bin" "$UPSRC/bin"
cp "$ROOT/AGENTS.md" "$UPSRC/AGENTS.md"
git -C "$UPSRC" init -q -b main
git -C "$UPSRC" add -A
git -C "$UPSRC" -c user.name=t -c user.email=t@example.invalid commit -qm source
# A worker can have written its first status while still working. That must
# not hold up the Claude primary; the generated brief must ask it to end its
# turn on the gate instead of running a foreground polling command.
WORKSRC="$TMP_ROOT/worker-source"
cp -R "$UPSRC" "$WORKSRC"
cat > "$WORKSRC/bin/fm-brief.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p "$FM_HOME/data/$1"
printf '{TASK}\n{FIRSTMATE_SPEC}\n' > "$FM_HOME/data/$1/brief.md"
SH
cat > "$WORKSRC/bin/fm-tasks-axi.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$WORKSRC/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
id=$1
tmux new-window -d -t firstmate: -n "fm-$id" -c "$FM_HOME" 'exec sleep 45 >/dev/null 2>&1' || exit 1
# A missing =name can silently resolve to the current window: verify the name.
for (( n=0; n<30; n++ )); do
  if tmux list-windows -t firstmate -F '#{window_name}' | grep -Fxq "fm-$id"; then
    pid=$(tmux display-message -p -t "firstmate:=fm-$id" '#{pane_pid}')
    [ -z "$pid" ] || break
  fi
  sleep 0.1
done
[ -n "${pid:-}" ] || exit 1
printf 'window=firstmate:fm-%s\n' "$id" > "$FM_HOME/state/$id.meta"
printf 'working [at=1]: setting up\n' > "$FM_HOME/state/$id.status"
SH
chmod +x "$WORKSRC/bin/"{fm-brief,fm-tasks-axi,fm-spawn}.sh
git -C "$WORKSRC" add -A
git -C "$WORKSRC" -c user.name=t -c user.email=t@example.invalid commit -qm stubs
W="$TMP_ROOT/worker-up"
out=$(SHELL=/bin/sh PATH="$TMP_ROOT/stub-bin:$PATH" "$LIVE_LAB" up --harness claude --worker --source "$WORKSRC" --timeout 0 "$W" 2>&1)
rc=$?
capture_up_lab "$W" || fail 'cannot retain public-up worker lab ownership before assertions'
expect_code 1 "$rc" "unanswered probe leaves worker lab for inspection: $out"
assert_contains "$out" "primary: claude" "the unparked worker did not block primary launch"
assert_contains "$out" "gate: $W/home/data/" "up shows the gate path"
assert_contains "$out" "then message the worker to resume" "up explains the release message"
worker_id=$(sed -n 's/^worker_id=//p' "$W/.fm-live-lab")
brief=$(<"$W/home/data/$worker_id/brief.md")
assert_contains "$brief" "append one paused status line naming the gate file" "worker declares its wait"
assert_contains "$brief" "and end your turn" "worker ends its waiting turn"
assert_contains "$brief" "Do not poll or sleep in a foreground command" "worker does not run a blocking wait"
assert_contains "$brief" "When a later message resumes you, check that" "worker checks the gate after a message"
assert_contains "$out" "fail worker: the worker is not currently parked" "final readiness remains strict"
node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.exit(j.projects?.[process.argv[2]]?.hasTrustDialogAccepted===true?0:1)' "$HOME/.claude.json" "$W/home" || fail "primary trust was not registered before launch"
out=$("$LIVE_LAB" down "$W" 2>&1)
expect_code 0 "$?" "down cleans the worker lab: $out"
pass "up launches primary after worker status without weakening final parked readiness"

# If a spawn reports success without a pane, fail at the missing PID rather
# than invoking ps with an empty -p argument or waiting for readiness.
cat > "$WORKSRC/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
id=$1
printf 'window=firstmate:fm-%s\n' "$id" > "$FM_HOME/state/$id.meta"
printf 'working [at=1]: setting up\n' > "$FM_HOME/state/$id.status"
SH
git -C "$WORKSRC" add bin/fm-spawn.sh
git -C "$WORKSRC" -c user.name=t -c user.email=t@example.invalid commit -qm missing-pane
NO_PANE="$TMP_ROOT/no-pane"
out=$(SHELL=/bin/sh PATH="$TMP_ROOT/stub-bin:$PATH" "$LIVE_LAB" up --harness claude --worker --source "$WORKSRC" --timeout 0 "$NO_PANE" 2>&1)
rc=$?
capture_up_lab "$NO_PANE" || fail 'cannot retain partial public-up lab ownership before assertions'
expect_code 1 "$rc" "up refuses a worker without a pane PID: $out"
assert_contains "$out" "cannot record lab process: missing or invalid PID ''" "missing pane PID fails at launch recording"
assert_not_contains "$out" "list of process IDs must follow -p" "ps never receives an empty PID"
out=$("$LIVE_LAB" down "$NO_PANE" 2>&1)
expect_code 0 "$?" "down cleans the missing-pane lab: $out"
pass "up fails immediately when a spawned worker has no pane PID"

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
sleep 1.5
if node -e 'const [s,k]=process.argv.slice(1);const j=JSON.parse(require("node:fs").readFileSync(s,"utf8"));process.exit(j.projects?.[k]?.hasTrustDialogAccepted===true?0:1)' "$HOME/.claude.json" "$FM_HOME"; then
  echo present > "$FM_HOME/../claude-launch-trust"
else
  echo absent > "$FM_HOME/../claude-launch-trust"
fi
: > "$FM_HOME/state/.session-start-complete"
exec sleep 45 >/dev/null 2>&1
SH
chmod +x "$FAKEBIN/claude"
U="$TMP_ROOT/up-lab"
(
  end=$(( $(date +%s) + 120 ))
  until node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.exit(j.projects?.[process.argv[2]]?0:1)' "$HOME/.claude.json" "$U/home" 2>/dev/null; do
    [ "$(date +%s)" -lt "$end" ] || exit 1
    sleep 0.05
  done
  sleep 0.5
  node -e 'const fs=require("node:fs");const [s,k]=process.argv.slice(1);const j=JSON.parse(fs.readFileSync(s,"utf8"));delete j.projects[k];fs.writeFileSync(s,JSON.stringify(j))' "$HOME/.claude.json" "$U/home"
  node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.exit(j.projects?.[process.argv[2]]?1:0)' "$HOME/.claude.json" "$U/home" || exit 1
  echo dropped > "$TMP_ROOT/rival-dropped"
) &
RIVAL=$!
fm_test_track_child "$RIVAL"
printf '%s\n' "$RIVAL" >> "$TMP_ROOT/pids"
sleep 1
out=$(SHELL=/bin/sh PATH="$FAKEBIN:$PATH" "$LIVE_LAB" up --harness claude --source "$UPSRC" --ref HEAD --timeout 1 "$U" 2>&1)
rc=$?
capture_up_lab "$U" || fail 'cannot retain public-up primary lab ownership before assertions'
expect_code 1 "$rc" "stand-in primary does not answer probe"
wait "$RIVAL" 2>/dev/null || true
assert_equals dropped "$(cat "$TMP_ROOT/rival-dropped" 2>/dev/null)" "rival dropped primary trust once"
assert_equals present "$(cat "$U/claude-launch-trust" 2>/dev/null)" "primary launched trusted after the rival write"
assert_contains "$out" "ok trust: $U/home is trusted in the Claude store" "readiness sees primary trust"
out=$("$LIVE_LAB" down "$U" 2>&1)
expect_code 0 "$?" "down removes the up-built lab: $out"
pass "up re-registers primary trust after a concurrent Claude write"

# ---- fm-claude-trust.sh --lab-home -------------------------------------------

T="$TMP_ROOT/trust"
mkdir -p "$T/config"
"$ROOT/bin/fm-lab-home.sh" create "$T/home" >/dev/null
cp "$ROOT/AGENTS.md" "$T/home/AGENTS.md"
mkdir -p "$T/home/bin"
git -C "$T/home" init -q -b main
out=$(CLAUDE_CONFIG_DIR="$T/config" "$TRUST" --lab-home "$T/home" 2>&1)
expect_code 0 "$?" "a marked lab primary checkout is trusted: $out"
TH=$(cd -P "$T/home" && pwd -P)
node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.exit(j.projects[process.argv[2]].hasTrustDialogAccepted===true&&!("hasClaudeMdExternalIncludesApproved" in j.projects[process.argv[2]])?0:1)' \
  "$T/config/.claude.json" "$TH" || fail "lab-home trust is trust-only"

mkdir -p "$T/plain/bin"
cp "$ROOT/AGENTS.md" "$T/plain/AGENTS.md"
git -C "$T/plain" init -q -b main
out=$(CLAUDE_CONFIG_DIR="$T/config" "$TRUST" --lab-home "$T/plain" 2>&1)
expect_code 1 "$?" "an unmarked checkout is refused"
assert_contains "$out" "carries no lab-home marker" "the refusal names the missing marker"

fm_git_worktree "$T/proj" "$T/wt" lab-trust-wt
printf 'fm-lab-home v1\n' > "$T/wt/.fm-lab-home"
cp "$ROOT/AGENTS.md" "$T/wt/AGENTS.md"
mkdir -p "$T/wt/bin"
out=$(CLAUDE_CONFIG_DIR="$T/config" "$TRUST" --lab-home "$T/wt" 2>&1)
expect_code 1 "$?" "a linked worktree is refused"
assert_contains "$out" "is a linked worktree" "the refusal names the linked worktree"

rm "$T/home/.fm-lab-home"
ln -s "$T/wt/.fm-lab-home" "$T/home/.fm-lab-home"
out=$(CLAUDE_CONFIG_DIR="$T/config" "$TRUST" --lab-home "$T/home" 2>&1)
expect_code 1 "$?" "a symlinked marker is refused"
assert_contains "$out" "is a symlink" "the refusal names the symlink"
pass "fm-claude-trust.sh --lab-home trusts only a marked lab primary checkout"

python3 - "$LIVE_LAB" "$TMP_ROOT" <<'PYTEST'
import pathlib, subprocess, sys
binary, root = sys.argv[1], pathlib.Path(sys.argv[2])
lab=root/'operand-lab'; lab.mkdir()
(lab/'.fm-live-lab').write_text('fm-live-lab v1\n')
for command, options in [('up', ['--harness','--model','--effort','--supervision-host','--expect-host','--source','--ref','--timeout']), ('pane', ['--window','--lines']), ('say', ['--window'])]:
    for option in options:
        args=[binary, command] + ([] if command=='up' else [str(lab)]) + [option]
        result=subprocess.run(args, text=True, capture_output=True, timeout=3)
        assert result.returncode != 0 and option+' requires a value' in result.stderr, (args,result)
PYTEST
pass 'all valued lab options reject a missing operand promptly'
