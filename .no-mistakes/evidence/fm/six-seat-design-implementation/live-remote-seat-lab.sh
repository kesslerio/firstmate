#!/usr/bin/env bash
# Live seat-pool scenarios for the remote secondmate control plane.
#
# The product under test is the real host control plane
# (bin/fm-remote-secondmate-control.sh), the real parent seat ledger
# (bin/fm-fleet-seats.sh), the real remote transport
# (bin/fm-on.sh + bin/fm-remote-entrypoint.sh + the real job worker), and the
# real Herdr backend. The remote secondmate host is an isolated lab: one real
# Herdr lab session (bin/fm-herdr-lab.sh) holding real Pi agents, a real
# secondmate home, and a real remote job queue, all under a disposable root.
# Every herdr call is pinned to that lab session by a PATH wrapper that refuses
# any other session, so the fleet/default sessions can never be touched.
set -u

CODE=${CODE:?}
LAB=${LAB:?}
SESSION=${SESSION:?}
FAILED=0

say() { printf '\n### %s\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAILED=1; }

# --- isolation: only the lab session may ever be addressed ------------------
mkdir -p "$LAB/bin"
cat > "$LAB/bin/herdr" <<SH
#!/usr/bin/env bash
# Refuse any session but this run's lab session; log the attempt as a violation.
name=
prev=
for arg in "\$@"; do
  [ "\$prev" = --session ] && name=\$arg
  case "\$arg" in --session=*) name=\${arg#--session=} ;; esac
  prev=\$arg
done
[ -n "\$name" ] || name=\${HERDR_SESSION:-}
if [ "\$name" != "$SESSION" ]; then
  printf 'VIOLATION: foreign herdr session %s\n' "\${name:-<none>}" >> "$LAB/violations.log"
  echo "lab guard: refusing herdr session '\${name:-<none>}'" >&2
  exit 97
fi
exec $(command -v herdr) "\$@"
SH
chmod +x "$LAB/bin/herdr"

lab() { env -u HERDR_SESSION PATH="$LAB/bin:$PATH" "$CODE/bin/fm-herdr-lab.sh" run "$SESSION" "$@"; }

# A real, idle Pi agent in a fresh pane: a genuine agent process herdr registers
# and the product's own classifier reports alive, with no prompt submitted.
start_agent_pane() { # <label> <cwd> -> sets PANE
  local label=$1 cwd=$2 tab
  mkdir -p "$cwd"
  printf '# %s lab\n' "$label" > "$cwd/AGENTS.md"
  tab=$(lab tab create --workspace "$WS" --cwd "$cwd" --label "$label" --no-focus) || return 1
  PANE=$(printf '%s' "$tab" | jq -er '.result.root_pane.pane_id // .result.pane.pane_id') || return 1
  lab pane run "$PANE" "env PI_CODING_AGENT_DIR=$LAB/pi-$label pi --no-context-files --no-session" >/dev/null || return 1
  local i
  for i in $(seq 1 60); do
    [ "$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent // empty')" = pi ] && return 0
    sleep 0.5
  done
  return 1
}

state_of() { # <session:pane> -> the product's own recovery-grade verdict
  local i verdict
  for i in $(seq 1 20); do
    verdict=$(env HERDR_SESSION="$SESSION" PATH="$LAB/bin:$PATH" bash -c '. "'"$CODE"'/bin/fm-backend.sh"; fm_backend_agent_state herdr "$1"' _ "$1")
    [ "$verdict" = alive ] && { printf '%s' "$verdict"; return 0; }
    sleep 1
  done
  printf '%s' "$verdict"
}

pools() { # <home> <capacity>
  printf '{"pools":[{"name":"shared","capacity":%s,"models":["pool-model-a","pool-model-b"]}]}\n' "$2" > "$1/config/fleet-seats"
}

make_ssh() { # <root>
  cat > "$1/bin/ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$1" = labhost ] || exit 91
[ "$2" = fm-remote-entrypoint.sh ] || exit 92
shift 2
exec "$FM_LAB_ENTRYPOINT" "$@"
SH
  chmod +x "$1/bin/ssh"
}

# The real host control plane, run as the remote host runs it: outside any gate
# worktree, against the lab home, with the selected lab Herdr session.
control() { # <host-home> <args...>
  local home=$1
  shift
  mkdir -p "$LAB/root/state"
  ( cd "$LAB" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE \
      -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_HOME \
      PATH="$LAB/bin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$LAB/root" \
      "$CODE/bin/fm-remote-secondmate-control.sh" "$@" --herdr-session "$SESSION" 2>&1 )
}

seats() { # <home> <args...>
  local home=$1
  shift
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE PATH="$LAB/bin:$PATH" FM_HOME="$home" \
    "$CODE/bin/fm-fleet-seats.sh" "$@"
}

serve_remotes() { # <parent>
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE PATH="$LAB/bin:$PATH" FM_HOME="$1" \
    FM_SSH_BIN="$LAB/bin/ssh" FM_LAB_ENTRYPOINT="$CODE/bin/fm-remote-entrypoint.sh" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$LAB/remote-jobs" \
    "$CODE/bin/fm-fleet-seats.sh" serve-remotes
}

route_file() { # <path> <home> <op>
  (umask 077; jq -cn --arg home "$2" --arg root "$CODE" --arg op "$3" \
    '{placement:"remote",backend:"herdr",target:null,home:$home,host:"labhost",
      remote_root:$root,spawn_gen:null,operation:$op}' > "$1")
}

payload() { # <parent> <id> <gen>
  seats "$1" show "$2" | jq -c --arg g "$3" '{schema, task, incarnations: [.incarnations[] | select(.generation == $g)]}'
}

# reserve+dispatch in one short-lived process, exactly as fm-spawn does, so the
# recorded owner ends and a later launch can reclaim that generation.
cycle() { # <parent> <id> <gen> <model> <previous> <route-file>
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE PATH="$LAB/bin:$PATH" FM_HOME="$1" \
    bash -c '
      seats=$1 id=$2 gen=$3 model=$4 prev=$5 route=$6
      "$seats" reserve "$id" --generation "$gen" --previous-generation "$prev" --kind secondmate \
        --harness pi --model "$model" --holder-pid $$ || exit 1
      "$seats" dispatch "$id" --generation "$gen" --route-file "$route"
    ' _ "$CODE/bin/fm-fleet-seats.sh" "$2" "$3" "$4" "$5" "$6"
}

disposition_of() { sed -n 's/^seat_disposition=//p' | tail -1; }

seed_host() { # <home> <id>
  mkdir -p "$1/bin" "$1/state/parent-route" "$1/config"
  printf '%s\n' "$2" > "$1/.fm-secondmate-home"
  printf '# lab\n' > "$1/AGENTS.md"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=labroot\n' > "$1/.fm-secondmate-parent"
}

write_meta() { # <home> <id> <pane> <gen> <model>
  printf 'kind=secondmate\nharness=pi\nbackend=herdr\nwindow=%s:%s\nendpoint_task_id=%s\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\nworktree=%s\nproject=%s\nhome=%s\nmodel=%s\nspawn_gen=%s\nmode=secondmate\n' \
    "$SESSION" "$3" "$2" "$SESSION" "$WS" "$TAB" "$3" "$1" "$CODE" "$1" "$5" "$4" > "$1/state/parent-route/$2.meta"
}

register_remote() { # <parent> <id> <host> <alias>
  printf -- '- %s - Lab remote mate. (host: %s; root: %s; home: %s; scope: lab; projects: ; added 2026-11-01)\n' \
    "$2" "$4" "$CODE" "$3" >> "$1/data/secondmates.md"
}

HSETUP=0
setup_lab() {
  [ "$HSETUP" = 1 ] && return 0
  make_ssh "$LAB"
  mkdir -p "$LAB/bin"
  local ws
  ws=$(lab workspace create --cwd "$LAB" --label live-seats --no-focus) || return 1
  WS=$(printf '%s' "$ws" | jq -er '.result.workspace.workspace_id') || return 1
  TAB=$(printf '%s' "$ws" | jq -er '.result.tab.tab_id') || return 1
  HSETUP=1
}

# ---------------------------------------------------------------------------
# S1: a pooled launch that finds an already-running supervisor on another model
# is recognized by the receipt that observed it, and enabling pools around that
# supervisor does not block pooled launches fleet-wide.
# ---------------------------------------------------------------------------
scenario_observing_receipt() {
  local d="$LAB/s1" parent="$LAB/s1/parent" host="$LAB/s1/host" out rc disp cert
  say "S1 observing receipt recognizes the running model; pools are not blocked fleet-wide"
  mkdir -p "$d"
  setup_lab || { bad "could not create the lab Herdr workspace"; return; }
  "$CODE/bin/fm-lab-home.sh" create "$parent" >/dev/null || bad "could not mark the parent lab home"
  seed_host "$host" ios
  pools "$parent" 3
  register_remote "$parent" ios "$host" labhost
  start_agent_pane s1 "$d/agent" || { bad "could not start a real agent pane"; return; }
  write_meta "$host" ios "$PANE" host.a1 pool-model-a
  local verdict
  verdict=$(state_of "$SESSION:$PANE")
  [ "$verdict" = alive ] && ok "a real Herdr pane with a real agent classifies alive ($SESSION:$PANE)" \
    || bad "the live endpoint classified '$verdict'"

  # Pools are enabled around a supervisor that was already running: the primary
  # adopts it once, on the model it runs.
  out=$(serve_remotes "$parent"); printf '%s\n' "$out"
  cert="$parent/state/fleet-seats/remote-ios.cert"
  [ "$(jq -r '.holders | length' "$cert" 2>/dev/null)" = 1 ] \
    && [ "$(jq -r '.holders[0].generation' "$cert" 2>/dev/null)" = host.a1 ] \
    && ok "the primary adopted the pre-pool supervisor once, at generation host.a1" \
    || bad "the pre-pool supervisor was not adopted exactly once"

  # The parent now asks to launch the same task for ANOTHER model. The host finds
  # the supervisor alive and must bind the generation and model it observed.
  seats "$parent" reserve ios --generation op2 --previous-generation host.a1 --kind secondmate \
    --harness pi --model pool-model-b --holder-pid "$$" >/dev/null || bad "reserve op2 failed"
  route_file "$d/route2.json" "$host" op2
  seats "$parent" dispatch ios --generation op2 --route-file "$d/route2.json" >/dev/null || bad "dispatch op2 failed"
  out=$(payload "$parent" ios op2 | control "$host" launch ios pi pool-model-b - herdr --operation op2 --previous host.a1)
  rc=$?
  disp=$(printf '%s\n' "$out" | disposition_of)
  printf 'launch rc=%s\n%s\n' "$rc" "$out"
  [ "$rc" -eq 0 ] || bad "the pooled launch against an alive supervisor failed: rc=$rc"
  printf '%s\n' "$disp" | jq -e '.disposition == "existing" and .actual_generation == "host.a1"
      and .actual_model == "pool-model-a" and .requested_generation == "op2"' >/dev/null 2>&1 \
    && ok "the receipt observed generation host.a1 running model pool-model-a (requested pool-model-b)" \
    || bad "the receipt did not bind the observed generation and model: $disp"
  grep -q '^phase=existing' "$host/state/parent-route/ios.seat-operation.op2" 2>/dev/null \
    && ok "the durable host receipt records the observing phase" \
    || bad "the host did not retain an observing receipt"
  printf '%s\n' "$disp" > "$d/disposition2.json"
  chmod 600 "$d/disposition2.json"
  seats "$parent" reconcile-remote ios --generation op2 --response-file "$d/disposition2.json" || bad "reconcile op2 failed"

  # Enabling pools around that supervisor must not block pooled launches: the
  # next serve accepts it, and a launch for the model the parent asked for gets
  # its seat instead of being refused as unaccounted occupancy.
  rm -f "$parent/state/.fleet-seats-serve-failed-ios"
  out=$(serve_remotes "$parent"); printf '%s\n' "$out"
  case "$out" in
    served*ios*) ok "the primary served the remote after the observing receipt" ;;
    *) bad "the primary could not serve the observed supervisor: $out" ;;
  esac
  printf '%s\n' "$out" | grep -qi 'unaccounted' && bad "the observed supervisor was still unaccounted occupancy"
  seats "$parent" reserve contender --generation op3 --harness pi --model pool-model-b \
    --holder-pid "$$" > "$d/contender.out" 2>&1
  rc=$?
  printf '%s\n' "$(cat "$d/contender.out")"
  [ "$rc" -eq 0 ] && ok "a pooled launch on pool-model-b was granted beside the adopted supervisor" \
    || bad "a pooled launch was still blocked fleet-wide: rc=$rc"

  # A replacement launch that names the generation the host actually records is
  # accepted as replacing it, while the same host refuses one that names an
  # older generation (S2 below shows the cancelled-launch predecessor that the
  # parent must offer instead).
  seats "$parent" release contender --generation op3 --reason prelaunch >/dev/null 2>&1
  seats "$parent" reserve ios --generation op8 --previous-generation host.a1 --kind secondmate \
    --harness pi --model pool-model-a --holder-pid "$$" >/dev/null || bad "reserve op8 failed"
  route_file "$d/route8.json" "$host" op8
  seats "$parent" dispatch ios --generation op8 --route-file "$d/route8.json" >/dev/null || bad "dispatch op8 failed"
  out=$(payload "$parent" ios op8 | control "$host" launch ios pi pool-model-a - herdr --operation op8 --previous host.a1)
  rc=$?
  disp=$(printf '%s\n' "$out" | disposition_of)
  printf 'replacement-of-recorded rc=%s\n%s\n' "$rc" "$out"
  [ "$rc" -eq 0 ] && printf '%s\n' "$disp" | jq -e '.disposition == "existing" and .actual_generation == "host.a1"' >/dev/null 2>&1 \
    && ok "a replacement naming the host-recorded generation host.a1 was accepted" \
    || bad "a replacement naming the host-recorded generation was refused: rc=$rc $disp"
}

# ---------------------------------------------------------------------------
# S2: a replacement launch replaces the generation the host actually records,
# even when that generation came from a launch cancelled before it confirmed a
# startup.
# ---------------------------------------------------------------------------
host_response() { # <disposition> <target> <gen> <spawn-gen> <home>
  jq -cn --arg d "$1" --arg t "$2" --arg g "$3" --arg s "$4" --arg root "$CODE" --arg home "$5" '
    {schema:"fm-remote-seat-operation.v2", complete:true,
     task:"ios2", operation:$g, requested_generation:$g, actual_generation:$g,
     previous_generation:null, disposition:$d, startup_confirmed:($d == "started"),
     old_stopped:false, old_destroyed:false,
     route:{placement:"remote", backend:"herdr", target:$t, home:$home, host:"labhost",
            remote_root:$root, spawn_gen:(if $s == "" then null else $s end)},
     actual_model:"pool-model-a"}'
}

predecessor_of() { # <parent> <id> <home>
  ( . "$CODE/bin/fm-remote-generation-lib.sh"
    fm_remote_launch_predecessor "$(seats "$1" show "$2")" labhost "$CODE" "$3" )
}

scenario_cancelled_replacement_generation() {
  local d="$LAB/s2" parent="$LAB/s2/parent" host="$LAB/s2/host" out rc disp target prev
  say "S2 a replacement replaces the host-recorded generation from a cancelled launch"
  mkdir -p "$d"
  setup_lab || { bad "could not create the lab Herdr workspace"; return; }
  "$CODE/bin/fm-lab-home.sh" create "$parent" >/dev/null || bad "could not mark the parent lab home"
  seed_host "$host" ios2
  pools "$parent" 3
  register_remote "$parent" ios2 "$host" labhost
  start_agent_pane s2 "$d/agent" || { bad "could not start a real agent pane"; return; }
  write_meta "$host" ios2 "$PANE" host.a1 pool-model-a
  serve_remotes "$parent" > "$d/serve0.out" 2>&1
  printf '%s\n' "$(cat "$d/serve0.out")"
  target="$SESSION:$PANE"
  [ "$(state_of "$target")" = alive ] || bad "the live endpoint is not alive"

  # (1) an older generation confirmed by an earlier launch (gen host.a1)
  route_file "$d/routea.json" "$host" ops1
  cycle "$parent" ios2 ops1 pool-model-a - "$d/routea.json" >/dev/null || bad "reserve/dispatch opa failed"
  out=$(payload "$parent" ios2 ops1 | control "$host" launch ios2 pi pool-model-a - herdr --operation ops1 --previous -)
  rc=$?
  disp=$(printf '%s\n' "$out" | disposition_of)
  printf 'first launch rc=%s %s\n' "$rc" "$disp"
  printf '%s\n' "$disp" > "$d/resa.json"; chmod 600 "$d/resa.json"
  [ "$rc" -eq 0 ] || bad "the first (observing) launch failed: rc=$rc"
  seats "$parent" reconcile-remote ios2 --generation ops1 --response-file "$d/resa.json" || bad "confirming the older generation failed"

  # The next launch reached the endpoint and was cancelled before it confirmed a
  # startup: the host keeps that generation token as its record.
  write_meta "$host" ios2 "$PANE" op4 pool-model-a

  # (2) a launch that reached the endpoint and was then cancelled before it
  # confirmed a startup. The host still records its generation token.
  route_file "$d/route4.json" "$host" op4
  cycle "$parent" ios2 op4 pool-model-a host.a1 "$d/route4.json" >/dev/null || bad "reserve/dispatch op4 failed"
  host_response cancelled "$target" op4 "" "$host" > "$d/res4.json"; chmod 600 "$d/res4.json"
  seats "$parent" reconcile-remote ios2 --generation op4 --response-file "$d/res4.json" || bad "recording the cancelled launch failed"
  seats "$parent" show ios2 | jq -c '[.incarnations[] | {generation, lifecycle, reason: (.disposition.reason // null), route: .route.target}]' || true

  # The parent reclaims the generation it already holds before starting another,
  # exactly as bin/fm-spawn.sh's remote path does.
  out=$(seats "$parent" reclaim ios2 --generation host.a1); rc=$?
  printf 'reclaim opa rc=%s: %s\n' "$rc" "$out"
  [ "$rc" -eq 0 ] || bad "the parent could not reclaim its earlier generation: $out"
  prev=$(predecessor_of "$parent" ios2 "$host")
  printf 'resolved predecessor: %s\n' "$prev"
  [ "$prev" = op4 ] \
    && ok "the parent resolves the cancelled launch as the generation the host records" \
    || bad "the parent offered '$prev' instead of the host-recorded cancelled generation op4"

  # (3) the replacement names the host-recorded generation and is accepted. A
  # fresh parent home is used so its ledger holds only the cancelled generation
  # this replacement replaces (the earlier home still counts its confirmed one).
  local parent2="$d/parent2" out2
  "$CODE/bin/fm-lab-home.sh" create "$parent2" >/dev/null
  pools "$parent2" 3
  register_remote "$parent2" ios2 "$host" labhost
  serve_remotes "$parent2" > "$d/serve2.out" 2>&1
  route_file "$d/routec.json" "$host" opc
  cycle "$parent2" ios2 opc pool-model-a - "$d/routec.json" >/dev/null || bad "reserve/dispatch opc failed"
  host_response cancelled "$target" opc "" "$host" > "$d/resc.json"; chmod 600 "$d/resc.json"
  seats "$parent2" reconcile-remote ios2 --generation opc --response-file "$d/resc.json" || bad "recording the cancelled launch failed"
  seats "$parent2" show ios2 | jq -c '[.incarnations[] | {generation, lifecycle, reason: (.disposition.reason // null), route: .route.target}]' || true
  prev2=$(predecessor_of "$parent2" ios2 "$host")
  printf 'resolved predecessor (host-recorded): %s\n' "$prev2"
  [ "$prev2" = opc ] && ok "the cancelled launch is the generation the host records" \
    || bad "the parent offered '$prev2' instead of the cancelled host generation opc"
  route_file "$d/route7.json" "$host" op7
  cycle "$parent2" ios2 op7 pool-model-a "$prev2" "$d/route7.json" >/dev/null || bad "reserve/dispatch op7 failed"
  out=$(payload "$parent2" ios2 op7 | control "$host" launch ios2 pi pool-model-a - herdr --operation op7 --previous "$prev2")
  rc=$?
  disp=$(printf '%s\n' "$out" | disposition_of)
  printf 'replacement rc=%s\n%s\n' "$rc" "$out"
  case "$out" in
    *generation-mismatch*) bad "the host refused the replacement that named its recorded generation" ;;
    *) [ "$rc" -eq 0 ] && printf '%s\n' "$disp" | jq -e --arg g "$prev2" '.disposition == "existing" and .actual_generation == $g' >/dev/null 2>&1 \
        && ok "the replacement replaced the host-recorded cancelled generation" \
        || bad "the replacement did not confirm the host-recorded generation: rc=$rc $disp" ;;
  esac

  # (4) the pre-fix offer (the older confirmed generation) is still refused by
  # the host, which is exactly the retry loop this change removes.
  seats "$parent" reserve ios2 --generation op6 --previous-generation opa --kind secondmate \
    --harness pi --model pool-model-a --holder-pid "$$" >/dev/null || bad "reserve op6 failed"
  route_file "$d/route6.json" "$host" op6
  seats "$parent" dispatch ios2 --generation op6 --route-file "$d/route6.json" >/dev/null || bad "dispatch op6 failed"
  out=$(payload "$parent" ios2 op6 | control "$host" launch ios2 pi pool-model-a - herdr --operation op6 --previous opa)
  rc=$?
  printf 'pre-fix predecessor rc=%s\n%s\n' "$rc" "$out"
  [ "$rc" -eq 6 ] && printf '%s\n' "$out" | grep -q 'generation-mismatch' \
    && ok "the older confirmed generation is still refused (the loop the fix removes)" \
    || bad "the host accepted a predecessor it does not record: rc=$rc"
}

# ---------------------------------------------------------------------------
# S3: retrying a remote retirement after the same id was reseeded must not
# delete the newly provisioned home.
# ---------------------------------------------------------------------------
retire() { # <root> <home> <args...>
  local root=$1 home=$2
  shift 2
  ( cd "$LAB" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE \
      -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_HOME \
      PATH="$LAB/bin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
      "$CODE/bin/fm-remote-secondmate-control.sh" "$@" 2>&1 )
}

pending_evidence() { # <root> <id> <gen> <home>
  local dir="$1/state/remote-secondmate-history"
  mkdir -p "$dir"
  (umask 077; printf '{"schema":"fm-remote-retirement-pending.v1","task":%s,"generation":%s,"home":%s,"backend":"herdr","target":"fm-remote:w9:p9","phase":"pending","destroyed":false,"exit_code":0}\n' \
    "$(jq -Rn --arg v "$2" '$v')" "$(jq -Rn --arg v "$3" '$v')" "$(jq -Rn --arg v "$4" '$v')" \
    > "$dir/$2.retirement.$3.pending.json")
}

scenario_reseeded_home_retirement_retry() {
  local d="$LAB/s3" root="$LAB/s3/root" host="$LAB/s3/host" out rc
  say "S3 a retirement retry refuses to delete a reseeded public home"
  mkdir -p "$d/root/state" "$d/host/bin" "$d/host/state/parent-route"
  root="$d/root"; host="$d/host"
  printf 'ios3\n' > "$d/host/.fm-secondmate-home"
  printf '# lab\n' > "$d/host/AGENTS.md"
  printf 'kind=secondmate\nbackend=herdr\nwindow=fm-remote:w9:p9\nendpoint_task_id=ios3\nherdr_session=fm-remote\nherdr_workspace_id=w9\nherdr_tab_id=w9:t9\nherdr_pane_id=w9:p9\nworktree=%s\nproject=%s\nhome=%s\nmodel=pool-model-a\nspawn_gen=retg1\n' \
    "$host" "$CODE" "$host" > "$host/state/parent-route/ios3.meta"
  pending_evidence "$root" ios3 retg1 "$host"

  # The supported seeding command recreates the same id and path after the
  # interrupted retirement: a fresh home with no parent-route record.
  rm -rf "$host/state/parent-route/ios3.meta"
  printf 'replacement data\n' > "$host/sentinel"
  out=$(retire "$root" "$host" retire ios3 --force --expect-generation retg1)
  rc=$?
  printf 'reseeded retry rc=%s\n%s\n' "$rc" "$out"
  [ "$rc" -ne 0 ] && ok "the retirement retry refused instead of deleting the reseeded home" \
    || bad "the retirement retry accepted a home it cannot prove it owns"
  printf '%s\n' "$out" | grep -q 'cannot prove public home ownership' \
    && ok "the refusal names the missing ownership proof" || bad "the refusal was not actionable: $out"
  [ -f "$host/sentinel" ] && [ "$(cat "$host/sentinel")" = 'replacement data' ] \
    && ok "the reseeded home and its data survived the retry" || bad "the retry removed the reseeded home"
  [ -d "$host" ] || bad "the reseeded home directory was removed"

  # A successor that re-provisioned the same path under a different generation
  # is refused as a successor, not deleted.
  mkdir -p "$host/state/parent-route"
  printf 'kind=secondmate\nbackend=herdr\nwindow=fm-remote:w9:p9\nendpoint_task_id=ios3\nherdr_session=fm-remote\nherdr_workspace_id=w9\nherdr_tab_id=w9:t9\nherdr_pane_id=w9:p9\nworktree=%s\nproject=%s\nhome=%s\nmodel=pool-model-a\nspawn_gen=retg2\n' \
    "$host" "$CODE" "$host" > "$host/state/parent-route/ios3.meta"
  out=$(retire "$root" "$host" retire ios3 --force --expect-generation retg1)
  rc=$?
  printf 'successor retry rc=%s\n%s\n' "$rc" "$out"
  [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'generation-mismatch' \
    && ok "a successor generation at the same path is refused" || bad "a successor generation was retired: rc=$rc"
  [ -f "$host/sentinel" ] && ok "the successor home survived the refusal" || bad "the successor home was removed"

  # A home that kept the generation but a different endpoint cannot be retired
  # against the pending route either.
  printf 'kind=secondmate\nbackend=herdr\nwindow=fm-remote:w9:p8\nendpoint_task_id=ios3\nherdr_session=fm-remote\nherdr_workspace_id=w9\nherdr_tab_id=w9:t9\nherdr_pane_id=w9:p8\nworktree=%s\nproject=%s\nhome=%s\nmodel=pool-model-a\nspawn_gen=retg1\n' \
    "$host" "$CODE" "$host" > "$host/state/parent-route/ios3.meta"
  out=$(retire "$root" "$host" retire ios3 --force --expect-generation retg1)
  rc=$?
  printf 'endpoint-mismatch retry rc=%s\n%s\n' "$rc" "$out"
  [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'pending history does not match this endpoint' \
    && ok "a different endpoint cannot consume the pending retirement evidence" \
    || bad "the pending evidence was used for another endpoint: rc=$rc"
  [ -f "$host/sentinel" ] && ok "the home survived the endpoint-mismatch refusal" || bad "the home was removed"
  [ ! -e "$LAB/violations.log" ] \
    && ok "no Herdr call outside this run's lab session was attempted" \
    || bad "a foreign Herdr session was addressed: $(cat "$LAB/violations.log")"
}

setup_lab || bad "could not create the lab Herdr workspace"
scenario_observing_receipt
scenario_cancelled_replacement_generation
scenario_reseeded_home_retirement_retry
printf '\n===\n'
if [ "$FAILED" -eq 0 ]; then echo "RESULT: all live remote seat scenarios passed"; else echo "RESULT: live remote seat scenarios FAILED"; fi
exit "$FAILED"
