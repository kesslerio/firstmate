#!/usr/bin/env bash
# Disposable live drive of the opt-in fleet seat pools against the run worktree.
#
# Every home is a marked disposable lab home minted by bin/fm-lab-home.sh, every
# remote call is a real ssh client to a private loopback sshd running the real
# bin/fm-remote-entrypoint.sh + remote job worker, and every seat decision is the
# real bin/fm-fleet-seats.sh. Nothing outside $LAB is written; the lab, the
# sshd, the remote job worker, and the holder processes are removed on exit.
#
# Usage: ROOT=<worktree> EVID=<evidence dir> fleet-seat-live-drive.sh
set -u

ROOT=${ROOT:?set ROOT to the run worktree}
EVID=${EVID:?set EVID to the evidence directory}
SEATS=$ROOT/bin/fm-fleet-seats.sh
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
BIN=$LAB/bin
JOBS=$LAB/remote-jobs
SSH_DIR=$LAB/ssh
HOLDER_PIDS=
SSHD_PID=
FAILS=0
CURRENT=/dev/null
mkdir -p "$BIN" "$JOBS" "$SSH_DIR"

cleanup() {
  local p
  for p in $HOLDER_PIDS; do kill "$p" 2>/dev/null || true; done
  if [ -f "$JOBS/worker.pid" ]; then
    # shellcheck source=/dev/null
    ( . "$ROOT/bin/fm-remote-job-lib.sh" && fm_remote_job_stop_worker_tree "$(cat "$JOBS/worker.pid")" ) >/dev/null 2>&1 || true
  fi
  [ -z "$SSHD_PID" ] || kill "$SSHD_PID" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

section() {  # <log-name> <title>
  CURRENT="$EVID/$1.log"
  : > "$CURRENT"
  printf '########## %s  (run worktree %s @ %s)\n' "$2" "$ROOT" "$(git -C "$ROOT" rev-parse --short HEAD)" | tee -a "$CURRENT"
}

say() { printf '%s\n' "$*" | tee -a "$CURRENT"; }

check() {  # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    say "PASS $1 (expected $2)"
  else
    say "FAIL $1 (expected $2, got $3)"
    FAILS=$((FAILS + 1))
  fi
}

check_contains() {  # <label> <haystack> <needle>
  case "$2" in
    *"$3"*) say "PASS $1 (found: $3)" ;;
    *) say "FAIL $1 (missing: $3)"; say "  output was: $2"; FAILS=$((FAILS + 1)) ;;
  esac
}

holder() { sleep 600 >/dev/null 2>&1 & HOLDER_PIDS="$HOLDER_PIDS $!"; LAST_HOLDER=$!; }

lab_home() {  # <dir>
  "$ROOT/bin/fm-lab-home.sh" create "$1" >/dev/null || { say "could not mint lab home $1"; exit 1; }
  mkdir -p "$1/user-home"
}

pools() {  # <home> <json>
  printf '%s\n' "$2" > "$1/config/fleet-seats"
}

seat() {  # <home> <args...>
  local home=$1
  shift
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$home" "$SEATS" "$@"
}

run_line() {  # <label> <command...>: run, echo "$ label", show output, return its status
  local label=$1 out rc
  shift
  out=$("$@" 2>&1)
  rc=$?
  say "\$ $label"
  [ -z "$out" ] || say "$out"
  say "exit=$rc"
  return $rc
}

seat_cmd() {  # <home> <label> <args...>: run_line against one home
  local home=$1 label=$2
  shift 2
  run_line "$label   (FM_HOME=${home##*/})" env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$home" "$SEATS" "$@"
}

local_mate() {  # <mate-dir> <root-home> <id>
  [ -f "$1/.fm-lab-home" ] || lab_home "$1"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$2" > "$1/.fm-secondmate-parent"
  printf '%s\n' "$3" > "$1/.fm-secondmate-home"
  printf -- '- %s - Lab mate. (home: %s; scope: tests; projects: ; added 2026-11-01)\n' "$3" "$1" >> "$2/data/secondmates.md"
}

# --- loopback ssh transport -------------------------------------------------------

start_sshd() {
  local port=25221
  ssh-keygen -q -t ed25519 -N '' -f "$SSH_DIR/host_ed25519"
  ssh-keygen -q -t ed25519 -N '' -f "$SSH_DIR/id_ed25519"
  cp "$SSH_DIR/id_ed25519.pub" "$SSH_DIR/authorized_keys"
  chmod 600 "$SSH_DIR/authorized_keys"
  cat > "$SSH_DIR/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $SSH_DIR/host_ed25519
AuthorizedKeysFile $SSH_DIR/authorized_keys
PidFile $SSH_DIR/sshd.pid
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
LogLevel ERROR
EOF
  /run/current-system/sw/bin/sshd -f "$SSH_DIR/sshd_config" -E "$SSH_DIR/sshd.log" || {
    say "sshd did not start: $(tail -3 "$SSH_DIR/sshd.log" 2>/dev/null)"
    exit 1
  }
  SSHD_PID=$(cat "$SSH_DIR/sshd.pid" 2>/dev/null || true)
  # The transport wrapper keeps fm-on.sh's ssh contract and pins the loopback
  # account plus a lab-only remote job state root, so the remote side writes
  # nothing outside this lab.
  cat > "$BIN/lab-ssh" <<EOF
#!/usr/bin/env bash
set -u
while [ "\$#" -gt 0 ] && [ "\$1" != -- ]; do shift; done
[ "\$#" -gt 0 ] || exit 90
shift
host=\${1:-}; shift
cmd=\${1:-}; shift
[ "\$host" = shop-host ] || { echo "lab ssh: unknown remote host \$host" >&2; exit 91; }
[ "\$cmd" = fm-remote-entrypoint.sh ] || { echo "lab ssh: unexpected remote command \$cmd" >&2; exit 92; }
args=
for a in "\$@"; do args="\$args \$a"; done
exec /run/current-system/sw/bin/ssh -p $port -i "$SSH_DIR/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes \\
  -o UserKnownHostsFile="$SSH_DIR/known_hosts" -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR \\
  art@127.0.0.1 "env FM_REMOTE_JOB_STATE_ROOT=$JOBS FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux $ROOT/bin/fm-remote-entrypoint.sh\$args"
EOF
  chmod +x "$BIN/lab-ssh"
  say "loopback sshd on 127.0.0.1:$port (pid $SSHD_PID); real bin/fm-remote-entrypoint.sh entrypoint"
}

remote_mate() {  # <dir> <id>
  [ -f "$1/.fm-lab-home" ] || lab_home "$1"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=shop-host\n' > "$1/.fm-secondmate-parent"
  printf '%s\n' "$2" > "$1/.fm-secondmate-home"
  # The host validates a seeded secondmate home as a Firstmate checkout.
  printf '# Lab remote mate\n' > "$1/AGENTS.md"
  mkdir -p "$1/bin" "$1/state/parent-route"
}

register_remote() {  # <root-home> <id> <remote-home>
  printf -- '- %s - Lab remote mate. (host: shop-host; root: %s; home: %s; scope: shop work; projects: ; added 2026-11-01)\n' \
    "$2" "$ROOT" "$3" >> "$1/data/secondmates.md"
}

serve_remotes() {  # <root-home>
  run_line "fm-fleet-seats.sh serve-remotes   (FM_HOME=${1##*/}, real ssh)" \
    env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$1" FM_SSH_BIN="$BIN/lab-ssh" "$SEATS" serve-remotes
}

cert() {  # <root-home> <remote-id> <jq-filter>
  jq -r "$3" "$1/state/fleet-seats/remote-$2.cert" 2>/dev/null
}

# =================================================================================
# Scenario A: one generation-bound capacity across the primary and a local mate
# =================================================================================
scenario_shared_capacity() {
  local P M out rc
  section scenario-a-shared-capacity \
    "A: primary home + local secondmate share one capacity; a pre-pool agent counts once; release frees exactly its generation"
  P=$LAB/a/primary; M=$LAB/a/android
  lab_home "$P"
  pools "$P" '{"pools":[{"name":"shared","capacity":2,"models":["demo/model-a"]}]}'
  local_mate "$M" "$P" android
  # An agent launched before the pool existed: a task record, no reservation.
  printf 'kind=ship\nmodel=demo/model-a\nharness=claude\n' > "$M/state/legacy-ship.meta"
  say "pre-pool agent record in the local mate: $(tr '\n' ' ' < "$M/state/legacy-ship.meta")"

  holder
  seat_cmd "$P" "fm-fleet-seats.sh reserve r1 --generation g-r1 --kind ship --harness claude --model demo/model-a --holder-pid $LAST_HOLDER" \
    reserve r1 --generation g-r1 --kind ship --harness claude --model demo/model-a --holder-pid "$LAST_HOLDER"
  rc=$?
  check "primary launch gets the last seat beside the pre-pool agent" 0 "$rc"

  holder
  out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$M" "$SEATS" reserve a1 --generation g-a1 --kind ship --harness claude \
    --model demo/model-a --holder-pid "$LAST_HOLDER" 2>&1)
  rc=$?
  say "\$ fm-fleet-seats.sh reserve a1   (FM_HOME=android, the local secondmate)"
  say "$out"
  say "exit=$rc"
  check "the local mate is refused at the same shared capacity" 4 "$rc"
  check_contains "the refusal names one row per counted holder" "$out" "holder $M/state legacy-ship"
  check_contains "the primary's own holder is named too" "$out" "holder $P/state r1"

  seat_cmd "$P" "fm-fleet-seats.sh release r1 --generation g-r1 --reason prelaunch" \
    release r1 --generation g-r1 --reason prelaunch >/dev/null
  holder
  out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$M" "$SEATS" reserve a1 --generation g-a1 --kind ship --harness claude \
    --model demo/model-a --holder-pid "$LAST_HOLDER" 2>&1)
  rc=$?
  say "\$ fm-fleet-seats.sh reserve a1   (retry after the primary released exactly g-r1)"
  say "$out"
  say "exit=$rc"
  check "releasing one generation admits the waiting local launch" 0 "$rc"
  out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$M" "$SEATS" show a1 2>&1)
  say "holder of a1 after admission: $(printf '%s' "$out" | jq -c '[.incarnations[] | {generation, lifecycle}]')"
}

# =================================================================================
# Scenario B (adversarial): simultaneous launches from two homes never overbook
# =================================================================================
scenario_no_overbooking() {
  local P M i hp out dir rc granted=0 refused=0 other=0
  section scenario-b-no-overbooking \
    "B (adversarial): eight simultaneous launches from the primary and its local mate against a capacity-two pool"
  P=$LAB/b/primary; M=$LAB/b/android; dir=$LAB/b/out
  lab_home "$P"; lab_home "$M"; mkdir -p "$dir"
  pools "$P" '{"pools":[{"name":"shared","capacity":2,"models":["demo/model-a"]}]}'
  local_mate "$M" "$P" android
  holder; hp=$LAST_HOLDER
  for i in 1 2 3 4 5 6 7 8; do
    if [ $((i % 2)) -eq 1 ]; then home=$P; else home=$M; fi
    (
      env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
        FM_HOME="$home" "$SEATS" reserve "c$i" --generation "g-c$i" --kind ship --harness claude \
        --model demo/model-a --holder-pid "$hp" > "$dir/$i.out" 2>&1
      echo $? > "$dir/$i.rc"
    ) &
    HOLDER_PIDS="$HOLDER_PIDS $!"
  done
  wait
  for i in 1 2 3 4 5 6 7 8; do
    home=$([ $((i % 2)) -eq 1 ] && echo primary || echo android)
    rc=$(cat "$dir/$i.rc")
    say "contender c$i from $home: exit=$rc  $(cat "$dir/$i.out")"
    case "$rc" in
      0) granted=$((granted + 1)) ;;
      4) refused=$((refused + 1)) ;;
      *) other=$((other + 1)) ;;
    esac
  done
  say "granted=$granted refused_full=$refused other=$other"
  check "exactly two launches are granted" 2 "$granted"
  check "every other launch is refused as full" 6 "$refused"
  check "no contender fails for another reason" 0 "$other"
}

# =================================================================================
# Scenario C: a pre-pool remote supervisor is counted exactly once
# =================================================================================
scenario_prepool_remote() {
  local P REM out rc used
  section scenario-c-prepool-supervisor-counted-once \
    "C: a supervisor already running on a remote host before pools existed is counted exactly once"
  P=$LAB/c/primary; REM=$LAB/c/rem
  lab_home "$P"; remote_mate "$REM" rem
  pools "$P" '{"pools":[{"name":"shared","capacity":2,"models":["demo/model-a"]}]}'
  register_remote "$P" rem "$REM"
  # The host supervisor that was already running: no seat reservation, no
  # generation in the primary's own pre-pool route record.
  printf 'kind=secondmate\nharness=claude\nmodel=demo/model-a\nbackend=herdr\nspawn_gen=legacyA\nhome=%s\n' \
    "$REM" > "$REM/state/parent-route/rem.meta"
  printf 'kind=secondmate\nharness=claude\nmodel=demo/model-a\nremote_host=shop-host\nremote_root=%s\nhome=%s\n' \
    "$ROOT" "$REM" > "$P/state/rem.meta"
  say "host supervisor record: $(tr '\n' ' ' < "$REM/state/parent-route/rem.meta")"
  say "primary pre-pool route record (no generation): $(tr '\n' ' ' < "$P/state/rem.meta")"

  out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$P" FM_SSH_BIN="$BIN/lab-ssh" "$SEATS" serve-remotes 2>&1)
  rc=$?
  say "\$ fm-fleet-seats.sh serve-remotes   (FM_HOME=primary, real ssh to the lab host)"
  say "$out"
  say "exit=$rc"
  check "the first pooled serve completes" 0 "$rc"
  check_contains "the remote is served" "$out" "served rem"
  check_contains "the pre-pool supervisor is reported once" "$out" "holders=1"
  say "certificate holders: $(jq -c '.holders' "$P/state/fleet-seats/remote-rem.cert")"

  holder
  out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$P" "$SEATS" reserve spare --generation g-spare --kind ship --harness claude \
    --model demo/model-a --holder-pid "$LAST_HOLDER" 2>&1)
  rc=$?
  say "\$ fm-fleet-seats.sh reserve spare   (capacity 2; the supervisor must spend exactly one seat)"
  say "$out"
  say "exit=$rc"
  check "one more launch fits beside the counted supervisor" 0 "$rc"
  check_contains "the admission counts the supervisor once" "$out" "used=2 capacity=2"

  holder
  out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$P" "$SEATS" reserve over --generation g-over --kind ship --harness claude \
    --model demo/model-a --holder-pid "$LAST_HOLDER" 2>&1)
  rc=$?
  say "\$ fm-fleet-seats.sh reserve over   (the third seat must be refused)"
  say "$out"
  say "exit=$rc"
  check "the pool is refused once full" 4 "$rc"
  say "holder rows named by the refusal: $(printf '%s\n' "$out" | grep -c '^  holder ')"
  check "the refusal names exactly the two counted holders" 2 "$(printf '%s\n' "$out" | grep -c '^  holder ')"

  # A waiting remote worker is granted from the same pool the supervisor spends,
  # and fills it again from the host side.
  seat_cmd "$P" "fm-fleet-seats.sh release spare --generation g-spare --reason prelaunch" \
    release spare --generation g-spare --reason prelaunch >/dev/null
  holder
  (
    env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
      FM_HOME="$REM" FM_FLEET_SEATS_TEST_REMOTE_WAIT=60 "$SEATS" reserve rem-worker \
      --generation g-rw --kind ship --harness claude --model demo/model-a \
      --holder-pid "$LAST_HOLDER" > "$LAB/c/rw.out" 2>&1
    echo $? > "$LAB/c/rw.rc"
  ) &
  RW_PID=$!
  HOLDER_PIDS="$HOLDER_PIDS $RW_PID"
  for _ in $(seq 1 100); do
    [ -n "$(find "$REM/state/fleet-seats" -name '*.req' 2>/dev/null)" ] && break
    sleep 0.1
  done
  say "the remote worker filed a seat request with the fleet root: $(find "$REM/state/fleet-seats" -name '*.req' -printf '%f ' 2>/dev/null)"
  out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$P" FM_SSH_BIN="$BIN/lab-ssh" "$SEATS" serve-remotes 2>&1)
  rc=$?
  say "\$ fm-fleet-seats.sh serve-remotes   (answer the waiting remote worker)"
  say "$out"; say "exit=$rc"
  wait "$RW_PID" 2>/dev/null || true
  say "remote worker result: exit=$(cat "$LAB/c/rw.rc" 2>/dev/null) $(cat "$LAB/c/rw.out" 2>/dev/null)"
  check "a remote worker is granted from the shared pool" 0 "$(cat "$LAB/c/rw.rc" 2>/dev/null)"
  check_contains "the host reports the grant came from the fleet root" "$(cat "$LAB/c/rw.out" 2>/dev/null)" "by the fleet root"
  holder
  out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$P" "$SEATS" reserve over-remote --generation g-over-remote --kind ship --harness claude \
    --model demo/model-a --holder-pid "$LAST_HOLDER" 2>&1)
  rc=$?
  say "\$ fm-fleet-seats.sh reserve over-remote   (the supervisor plus the granted remote worker fill capacity two)"
  say "$out"; say "exit=$rc"
  check "a remote worker spends the same shared capacity" 4 "$rc"
  check "the refusal names the remote worker and the supervisor" 2 "$(printf '%s\n' "$out" | grep -c '^  holder ')"

  # Adversarial: lose the host's certificate and admission must refuse, not free
  # the supervisor's seat.
  rm -f "$P/state/fleet-seats/remote-rem.cert"
  holder
  out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$P" "$SEATS" reserve after-loss --generation g-loss --kind ship --harness claude \
    --model demo/model-a --holder-pid "$LAST_HOLDER" 2>&1)
  rc=$?
  say "\$ fm-fleet-seats.sh reserve after-loss   (the host certificate was removed)"
  say "$out"
  say "exit=$rc"
  check "an uncounted remote host refuses admission instead of freeing seats" 5 "$rc"
  check_contains "the refusal names the unconfirmed policy" "$out" "have not confirmed the current seat policy"
}

# =================================================================================
# Scenario D: the receipt that observed an already-running supervisor on another model
# =================================================================================
scenario_observing_receipt() {
  local P REM out rc
  section scenario-d-observing-receipt-model \
    "D: a launch that asked for model-b found a supervisor already running on model-a and is recognized by its observing receipt"
  P=$LAB/d/primary; REM=$LAB/d/rem
  lab_home "$P"; remote_mate "$REM" ios
  pools "$P" '{"pools":[{"name":"pool-a","capacity":1,"models":["demo/model-a"]},{"name":"pool-b","capacity":1,"models":["demo/model-b"]}]}'
  register_remote "$P" ios "$REM"
  out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$P" FM_SSH_BIN="$BIN/lab-ssh" "$SEATS" serve-remotes 2>&1)
  rc=$?
  say "\$ fm-fleet-seats.sh serve-remotes   (empty host: confirms the current declaration)"
  say "$out"; say "exit=$rc"
  check "the remote confirms the declaration before any grant" 0 "$rc"

  seat_cmd "$P" "fm-fleet-seats.sh reserve ios --generation op4 --model demo/model-b   (the launch asks for model-b)" \
    reserve ios --generation op4 --previous-generation - --kind secondmate --harness claude \
    --model demo/model-b --holder-pid "$$"
  check "the launch reserves the model route it asked for" 0 "$?"
  printf '{"placement":"remote","backend":"herdr","target":null,"home":"%s","host":"shop-host","remote_root":"%s","spawn_gen":null,"operation":"op4"}\n' \
    "$REM" "$ROOT" > "$P/state/route-op4"
  chmod 600 "$P/state/route-op4"
  seat_cmd "$P" "fm-fleet-seats.sh dispatch ios --generation op4 --route-file state/route-op4" \
    dispatch ios --generation op4 --route-file "$P/state/route-op4"
  # The host found its own supervisor on model-a and reports the generation and
  # model it observed; the retained reservation keeps the requested model-b.
  printf 'kind=secondmate\nharness=claude\nmodel=demo/model-a\nbackend=herdr\nspawn_gen=host.4\nhome=%s\n' \
    "$REM" > "$REM/state/parent-route/ios.meta"
  printf 'schema=fm-remote-seat-operation.v1\noperation=op4\nverb=launch\nactual_generation=host.4\nactual_model=demo/model-a\n' \
    > "$REM/state/parent-route/ios.seat-operation.op4"
  jq -n --arg h "$REM" '{schema:"fm-fleet-seat-holder.v2", task:"ios",
    incarnations:[{generation:"op4", kind:"secondmate", lifecycle:"reserved",
      launch_phase:"dispatching", model:"demo/model-b",
      route:{placement:"remote", operation:"op4", host:"shop-host", remote_root:"/srv/fm", home:$h}}]}' \
    > "$REM/state/parent-route/ios.seat-reservation.op4"
  chmod 600 "$REM/state/parent-route/ios.seat-reservation.op4" "$REM/state/parent-route/ios.seat-operation.op4"
  say "host supervisor record: $(tr '\n' ' ' < "$REM/state/parent-route/ios.meta")"
  say "host observing receipt: $(tr '\n' ' ' < "$REM/state/parent-route/ios.seat-operation.op4")"

  jq -n --arg h "$REM" --arg rt "$ROOT" '{schema:"fm-remote-seat-operation.v2",task:"ios",operation:"op4",
    requested_generation:"op4",actual_generation:"host.4",previous_generation:null,disposition:"existing",
    startup_confirmed:true,old_stopped:false,route:{placement:"remote",backend:"herdr",target:"fm-remote:w1:p1",
    home:$h,remote_root:$rt,spawn_gen:"host.4"},actual_model:"demo/model-a",complete:true}' > "$P/state/resp-op4"
  chmod 600 "$P/state/resp-op4"
  seat_cmd "$P" "fm-fleet-seats.sh reconcile-remote ios --generation op4 --response-file state/resp-op4" \
    reconcile-remote ios --generation op4 --response-file "$P/state/resp-op4"
  check "the observing disposition applies" 0 "$?"
  say "holder after reconcile: $(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$P" "$SEATS" show ios | jq -c '.incarnations[] | {generation, lifecycle, model, requested_model, target: .route.target}')"

  out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$P" FM_SSH_BIN="$BIN/lab-ssh" "$SEATS" serve-remotes 2>&1)
  rc=$?
  say "\$ fm-fleet-seats.sh serve-remotes   (the host reservation keeps the requested model-b; its receipt proves model-a)"
  say "$out"; say "exit=$rc"
  check "the host serves instead of refusing unaccounted occupancy" 0 "$rc"
  check_contains "the served remote is accepted" "$out" "served ios"

  holder
  out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$P" "$SEATS" reserve other-a --generation g-oa --kind ship --harness claude \
    --model demo/model-a --holder-pid "$LAST_HOLDER" 2>&1)
  rc=$?
  say "\$ fm-fleet-seats.sh reserve other-a --model demo/model-a   (the model the supervisor actually runs)"
  say "$out"; say "exit=$rc"
  check "the observed supervisor spends the seat on the model it runs" 4 "$rc"
  holder
  out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$P" "$SEATS" reserve other-b --generation g-ob --kind ship --harness claude \
    --model demo/model-b --holder-pid "$LAST_HOLDER" 2>&1)
  rc=$?
  say "\$ fm-fleet-seats.sh reserve other-b --model demo/model-b   (the model the launch asked for)"
  say "$out"; say "exit=$rc"
  check "the requested model takes no seat" 0 "$rc"
}

# =================================================================================
# Scenario E: a replacement replaces the generation the host actually records
# =================================================================================
scenario_replacement_generation() {
  local P REM out rc pred
  section scenario-e-replacement-host-generation \
    "E: after a replacement was cancelled before it confirmed a startup, the next launch replaces the generation the host records"
  P=$LAB/e/primary; REM=$LAB/e/rem
  lab_home "$P"; remote_mate "$REM" ios
  pools "$P" '{"pools":[{"name":"shared","capacity":2,"models":["demo/model-a","demo/model-b"]}]}'
  register_remote "$P" ios "$REM"
  # Make the fleet root's authority available without needing a live serve.
  mkdir -p "$P/state/fleet-seats"
  local digest
  digest=$(jq -cS . "$P/config/fleet-seats" | cksum | tr -s ' ' '-' | cut -d- -f1-2)
  jq -n --arg d "$digest" '{schema:"fm-fleet-seats-serve.v2",policy_digest:$d,epoch:"lab.1",complete:true,holders:[]}' \
    > "$P/state/fleet-seats/remote-ios.cert"
  # A: the confirmed predecessor the host records.
  seat_cmd "$P" "fm-fleet-seats.sh reserve ios --generation A --kind secondmate --model demo/model-a" \
    reserve ios --generation A --previous-generation - --kind secondmate --harness claude \
    --model demo/model-a --holder-pid "$$" >/dev/null
  printf '{"placement":"remote","backend":"herdr","target":"fm-remote:w1:p1","home":"%s","host":"shop-host","remote_root":"%s","spawn_gen":"A","operation":"A"}\n' \
    "$REM" "$ROOT" > "$P/state/route-a"; chmod 600 "$P/state/route-a"
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$P" \
    "$SEATS" dispatch ios --generation A --route-file "$P/state/route-a" >/dev/null
  jq -n --arg h "$REM" --arg rt "$ROOT" '{schema:"fm-remote-seat-operation.v2",task:"ios",operation:"A",
    requested_generation:"A",actual_generation:"A",previous_generation:null,disposition:"started",
    startup_confirmed:true,old_stopped:false,route:{placement:"remote",backend:"herdr",target:"fm-remote:w1:p1",
    home:$h,remote_root:$rt,spawn_gen:"A"},actual_model:null,complete:true}' > "$P/state/resp-a"
  chmod 600 "$P/state/resp-a"
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$P" \
    "$SEATS" reconcile-remote ios --generation A --response-file "$P/state/resp-a" >/dev/null
  printf 'kind=secondmate\nharness=claude\nmodel=demo/model-a\nbackend=herdr\nspawn_gen=A\nhome=%s\n' \
    "$REM" > "$REM/state/parent-route/ios.meta"

  # B: a replacement that stopped A and was cancelled before it reached the host.
  holder
  seat_cmd "$P" "fm-fleet-seats.sh reserve ios --generation B --previous-generation A --model demo/model-a" \
    reserve ios --generation B --previous-generation A --kind secondmate --harness claude \
    --model demo/model-a --holder-pid "$$" >/dev/null
  printf '{"placement":"remote","backend":"herdr","target":null,"home":"%s","host":"shop-host","remote_root":"%s","spawn_gen":null,"operation":"B"}\n' \
    "$REM" "$ROOT" > "$P/state/route-b"; chmod 600 "$P/state/route-b"
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$P" \
    "$SEATS" dispatch ios --generation B --route-file "$P/state/route-b" >/dev/null
  jq -n '{schema:"fm-remote-seat-operation.v2",task:"ios",operation:"B",requested_generation:"B",
    actual_generation:null,previous_generation:"A",disposition:"cancelled",startup_confirmed:false,
    old_stopped:true,route:null,actual_model:null,complete:true}' > "$P/state/resp-b"
  chmod 600 "$P/state/resp-b"
  seat_cmd "$P" "fm-fleet-seats.sh reconcile-remote ios --generation B --response-file state/resp-b   (cancelled before the host received it)" \
    reconcile-remote ios --generation B --response-file "$P/state/resp-b"
  check "the unsubmitted cancellation is applied" 0 "$?"

  pred=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$P" bash -c '. "$0/bin/fm-remote-generation-lib.sh"; fm_remote_launch_predecessor "$("$0/bin/fm-fleet-seats.sh" show ios)" shop-host "$1" "$2"' \
    "$ROOT" "$ROOT" "$REM")
  say "host-recorded predecessor after the unsubmitted cancellation: $pred"
  check "an unsubmitted cancellation leaves the host-recorded predecessor" A "$pred"

  # C: a cancellation that did reach the host becomes the host's record.
  holder
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$P" \
    "$SEATS" reserve ios --generation C --previous-generation A --kind secondmate --harness claude \
    --model demo/model-a --holder-pid "$$" >/dev/null
  printf '{"placement":"remote","backend":"herdr","target":null,"home":"%s","host":"shop-host","remote_root":"%s","spawn_gen":null,"operation":"C"}\n' \
    "$REM" "$ROOT" > "$P/state/route-c"; chmod 600 "$P/state/route-c"
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$P" \
    "$SEATS" dispatch ios --generation C --route-file "$P/state/route-c" >/dev/null
  jq -n --arg h "$REM" --arg rt "$ROOT" '{schema:"fm-remote-seat-operation.v2",task:"ios",operation:"C",
    requested_generation:"C",actual_generation:null,previous_generation:"A",disposition:"cancelled",
    startup_confirmed:false,old_stopped:false,route:{placement:"remote",backend:"herdr",target:"fm-remote:w1:p1",
    home:$h,remote_root:$rt,spawn_gen:null},actual_model:null,complete:true}' > "$P/state/resp-c"
  chmod 600 "$P/state/resp-c"
  seat_cmd "$P" "fm-fleet-seats.sh reconcile-remote ios --generation C --response-file state/resp-c   (cancelled after the host received it)" \
    reconcile-remote ios --generation C --response-file "$P/state/resp-c"
  pred=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$P" bash -c '. "$0/bin/fm-remote-generation-lib.sh"; fm_remote_launch_predecessor "$("$0/bin/fm-fleet-seats.sh" show ios)" shop-host "$1" "$2"' \
    "$ROOT" "$ROOT" "$REM")
  say "host-recorded predecessor after the submitted cancellation: $pred"
  check "a submitted cancellation becomes the host-recorded predecessor" C "$pred"

  # The host's own fence: a launch naming the cancelled candidate B where the
  # host records A is refused with generation-mismatch; naming A proceeds.
  holder
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$P" \
    "$SEATS" reserve ios --generation E --previous-generation B --kind secondmate --harness claude \
    --model demo/model-a --holder-pid "$$" >/dev/null
  printf '{"placement":"remote","backend":"herdr","target":null,"home":"%s","host":"shop-host","remote_root":"%s","spawn_gen":null,"operation":"E"}\n' \
    "$REM" "$ROOT" > "$P/state/route-e"; chmod 600 "$P/state/route-e"
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$P" \
    "$SEATS" dispatch ios --generation E --route-file "$P/state/route-e" >/dev/null
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$P" \
    "$SEATS" show ios | jq -c '{schema,task,incarnations:[.incarnations[] | select(.generation == "E")]}' > "$P/state/record-e"
  out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
    FM_HOME="$REM" FM_ROOT_OVERRIDE="$REM" \
    timeout 90 "$ROOT/bin/fm-remote-secondmate-control.sh" relaunch ios claude demo/model-a - \
    --operation E --previous B < "$P/state/record-e" 2>&1)
  rc=$?
  say "\$ fm-remote-secondmate-control.sh relaunch ios ... --operation E --previous B   (the host records A)"
  say "$out"; say "exit=$rc"
  check "naming the cancelled candidate is fenced as generation-mismatch" 6 "$rc"
  check_contains "the host names the mismatch" "$out" "generation-mismatch"

  holder
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$P" \
    "$SEATS" reserve ios --generation F --previous-generation A --kind secondmate --harness claude \
    --model demo/model-a --holder-pid "$$" >/dev/null
  printf '{"placement":"remote","backend":"herdr","target":null,"home":"%s","host":"shop-host","remote_root":"%s","spawn_gen":null,"operation":"F"}\n' \
    "$REM" "$ROOT" > "$P/state/route-f"; chmod 600 "$P/state/route-f"
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$P" \
    "$SEATS" dispatch ios --generation F --route-file "$P/state/route-f" >/dev/null
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$P" \
    "$SEATS" show ios | jq -c '{schema,task,incarnations:[.incarnations[] | select(.generation == "F")]}' > "$P/state/record-f"
  out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
    FM_HOME="$REM" FM_ROOT_OVERRIDE="$REM" \
    timeout 90 "$ROOT/bin/fm-remote-secondmate-control.sh" relaunch ios claude demo/model-a - \
    --operation F --previous A < "$P/state/record-f" 2>&1)
  rc=$?
  say "\$ fm-remote-secondmate-control.sh relaunch ios ... --operation F --previous A   (the generation the host records)"
  say "$out"; say "exit=$rc"
  if [ "$rc" = 6 ]; then
    say "FAIL naming the host-recorded generation was still fenced as a mismatch"
    FAILS=$((FAILS + 1))
  else
    say "PASS the host accepts the resolved predecessor (it fails later only because no Herdr endpoint exists: exit=$rc)"
  fi
}

# =================================================================================
# Scenario F (adversarial): pooled launches cannot bypass seat accounting
# =================================================================================
scenario_admission_guards() {
  local H PROJ out rc
  section scenario-f-admission-guards \
    "F (adversarial): a full pool refuses a real spawn, an unverified model cannot slip past, and a pooled host refuses an unaccounted supervisor launch"
  H=$LAB/f/home; PROJ=$LAB/f/project
  lab_home "$H"
  pools "$H" '{"pools":[{"name":"shared","capacity":1,"models":["demo/model-a"]}]}'
  printf 'kind=ship\nmodel=demo/model-a\nharness=claude\n' > "$H/state/busy.meta"
  mkdir -p "$PROJ" "$H/data/spawn-live-t1" "$H/data/spawn-live-t2" "$H/data/spawn-live-t3"
  git -C "$PROJ" init -q -b main
  git -C "$PROJ" -c user.email=lab@lab -c user.name=lab commit -q --allow-empty -m init
  printf '# Task\n## Captain'"'"'s intent\nExercise the fleet seat refusal.\n' > "$H/data/spawn-live-t1/brief.md"
  cp "$H/data/spawn-live-t1/brief.md" "$H/data/spawn-live-t2/brief.md"
  cp "$H/data/spawn-live-t1/brief.md" "$H/data/spawn-live-t3/brief.md"

  out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_TRACE_CONTEXT \
    FM_HOME="$H" HOME="$H/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 DISABLE_AUTOUPDATER=1 \
    "$ROOT/bin/fm-spawn.sh" spawn-live-t1 "$PROJ" --mode local-only --yolo off --harness claude \
    --model demo/model-a 2>&1)
  rc=$?
  say "\$ fm-spawn.sh spawn-live-t1 <project> --mode local-only --yolo off --harness claude --model demo/model-a"
  say "$out"; say "exit=$rc"
  check "a real spawn into a full pool refuses" 1 "$rc"
  check_contains "the refusal names the full pool" "$out" "pool shared is full"
  check "no task record is published for the refused launch" no "$([ -e "$H/state/spawn-live-t1.meta" ] && echo yes || echo no)"

  out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_TRACE_CONTEXT \
    FM_HOME="$H" HOME="$H/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 DISABLE_AUTOUPDATER=1 \
    "$ROOT/bin/fm-spawn.sh" spawn-live-t2 "$PROJ" --mode local-only --yolo off --harness claude 2>&1)
  rc=$?
  say "\$ fm-spawn.sh spawn-live-t2 <project> --mode local-only --yolo off --harness claude   (no explicit model)"
  say "$out"; say "exit=$rc"
  check "a harness-default model cannot slip past the pool" 1 "$rc"
  check_contains "the refusal names the unverified default model" "$out" "unverified default model"
  check "no task record is published for the unverified launch" no "$([ -e "$H/state/spawn-live-t2.meta" ] && echo yes || echo no)"

  # Host-side guard: the same pool declaration on the host refuses a supervisor
  # launch that did not come through the primary's accounting.
  local HOSTHOME=$LAB/f/host
  remote_mate "$HOSTHOME" unaccounted
  pools "$HOSTHOME" '{"pools":[{"name":"shared","capacity":1,"models":["demo/model-a"]}]}'
  out=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
    FM_HOME="$HOSTHOME" FM_ROOT_OVERRIDE="$HOSTHOME" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" launch unaccounted claude demo/model-a - herdr 2>&1)
  rc=$?
  say "\$ fm-remote-secondmate-control.sh launch unaccounted claude demo/model-a - herdr   (host has pools, no seat operation)"
  say "$out"; say "exit=$rc"
  if [ "$rc" -ne 0 ]; then
    say "PASS the pooled host refuses an unaccounted supervisor launch (exit=$rc)"
  else
    say "FAIL the pooled host accepted an unaccounted supervisor launch"
    FAILS=$((FAILS + 1))
  fi
  check_contains "the host refusal names the parent seat operation" "$out" "must come from the parent"
}

# =================================================================================

start_sshd
scenario_shared_capacity
scenario_no_overbooking
scenario_prepool_remote
scenario_observing_receipt
scenario_replacement_generation
scenario_admission_guards

say ""
if [ "$FAILS" -eq 0 ]; then
  say "ALL SCENARIOS PASSED (run worktree $(git -C "$ROOT" rev-parse --short HEAD))"
else
  say "SCENARIO CHECKS FAILED: $FAILS"
fi
exit "$([ "$FAILS" -eq 0 ] && echo 0 || echo 1)"
