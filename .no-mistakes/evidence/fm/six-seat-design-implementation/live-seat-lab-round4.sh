#!/usr/bin/env bash
# Live fleet-seat-pool scenarios, round 4 (HEAD ebad0790).
#
# Product under test: bin/fm-fleet-seats.sh (ledger, capacity, serve), the real
# host control plane bin/fm-remote-secondmate-control.sh, the real remote
# transport (bin/fm-on.sh + fm-remote-entrypoint.sh through a real job worker),
# the real Herdr backend on one isolated fm-lab-* session, and real Pi agents in
# real Herdr panes. S6 additionally provisions a real secondmate home from a
# disposable clone of this checkout and drives the real
# bin/fm-remote-secondmate-relaunch.sh end to end.
#
# Run:  CODE=<repo> LAB=<fresh tmpdir> SESSION=<fm-lab-*> live-seat-lab-round4.sh s1 s2 ...
set -u

CODE=${CODE:?}
LAB=${LAB:?}
SESSION=${SESSION:?}
FAILED=0

say() { printf '\n### %s\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAILED=1; }

cleanup() {
  [ "${KEEP_LAB:-0}" = 1 ] && return 0
  "$CODE/bin/fm-herdr-lab.sh" teardown "$SESSION" >/dev/null 2>&1 || true
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB" /tmp/fm-ios
}
trap cleanup EXIT

# --- isolation: every herdr call is pinned to this run's lab session ---------
mkdir -p "$LAB/bin"
cat > "$LAB/bin/herdr" <<SH
#!/usr/bin/env bash
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

HSETUP=0
SETUP_WS=
setup_lab() {
  [ "$HSETUP" = 1 ] && return 0
  local ws
  make_ssh "$LAB"
  # The host control plane keeps its operation history under FM_ROOT; each
  # scenario is a fresh host lifecycle.
  rm -rf "$LAB/root"
  ws=$(lab workspace create --cwd "$LAB" --label live-seats --no-focus) || return 1
  SETUP_WS=$(printf '%s' "$ws" | jq -er '.result.workspace.workspace_id') || return 1
  HSETUP=1
}

start_agent_pane() { # <label> <cwd> -> sets PANE
  local label=$1 cwd=$2 tab i
  mkdir -p "$cwd"
  printf '# %s lab\n' "$label" > "$cwd/AGENTS.md"
  tab=$(lab tab create --workspace "$SETUP_WS" --cwd "$cwd" --label "$label" --no-focus) || return 1
  PANE=$(printf '%s' "$tab" | jq -er '.result.root_pane.pane_id // .result.pane.pane_id') || return 1
  lab pane run "$PANE" "env PI_CODING_AGENT_DIR=$LAB/pi-$label pi --no-context-files --no-session" >/dev/null || return 1
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

pools() { # <home> <capacity> [models-json]
  printf '{"pools":[{"name":"shared","capacity":%s,"models":%s}]}\n' "$2" "${3:-[\"pool-model-a\",\"pool-model-b\"]}" > "$1/config/fleet-seats"
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

# The real host control plane, run the way a remote host runs it: outside any
# gate worktree, against the lab home, pinned to the lab Herdr session.
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
    FM_SSH_BIN="$LAB/bin/ssh" FM_LAB_ENTRYPOINT="${LAB_ENTRYPOINT:-$CODE/bin/fm-remote-entrypoint.sh}" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$LAB/remote-jobs" \
    "$CODE/bin/fm-fleet-seats.sh" serve-remotes
}

route_file() { # <path> <home> <op> [host]
  (umask 077; jq -cn --arg home "$2" --arg root "$CODE" --arg op "$3" --arg host "${4:-labhost}" \
    '{placement:"remote",backend:"herdr",target:null,home:$home,host:$host,
      remote_root:$root,spawn_gen:null,operation:$op}' > "$1")
}

payload() { # <parent> <id> <gen>
  seats "$1" show "$2" | jq -c --arg g "$3" '{schema, task, incarnations: [.incarnations[] | select(.generation == $g)]}'
}

# reserve+dispatch in one short-lived process, exactly as fm-spawn does.
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

write_meta() { # <home> <id> <pane> <gen> <model> [harness]
  printf 'kind=secondmate\nharness=%s\nbackend=herdr\nwindow=%s:%s\nendpoint_task_id=%s\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\nworktree=%s\nproject=%s\nhome=%s\nmodel=%s\nspawn_gen=%s\nmode=secondmate\n' \
    "${6:-pi}" "$SESSION" "$3" "$2" "$SESSION" "$SETUP_WS" "$SETUP_WS:t2" "$3" "$1" "$CODE" "$1" "$5" "$4" > "$1/state/parent-route/$2.meta"
}

register_remote() { # <parent> <id> <host> <alias>
  printf -- '- %s - Lab remote mate. (host: %s; root: %s; home: %s; scope: lab; projects: ; added 2026-11-01)\n' \
    "$2" "$4" "$CODE" "$3" >> "$1/data/secondmates.md"
}

register_local() { # <parent> <id> <home>
  printf -- '- %s - Lab local mate. (home: %s; scope: lab; projects: ; added 2026-11-01)\n' \
    "$2" "$3" >> "$1/data/secondmates.md"
}

predecessor_of() { # <parent> <id> <home>
  ( . "$CODE/bin/fm-remote-generation-lib.sh"
    fm_remote_launch_predecessor "$(seats "$1" show "$2")" labhost "$CODE" "$3" )
}

host_response() { # <task> <disposition> <requested-gen> <actual-gen> <previous> <target> <spawn-gen> <home> <model>
  jq -cn --arg t "$1" --arg d "$2" --arg g "$3" --arg a "$4" --arg p "$5" --arg tg "$6" \
    --arg s "$7" --arg root "$CODE" --arg home "$8" --arg m "$9" '
    {schema:"fm-remote-seat-operation.v2", complete:true,
     task:$t, operation:$g, requested_generation:$g,
     actual_generation:(if $a == "" then null else $a end),
     previous_generation:(if $p == "" then null else $p end),
     disposition:$d, startup_confirmed:($d == "started"),
     old_stopped:false,
     old_destroyed:false,
     route:{placement:"remote", backend:"herdr", target:$tg, home:$home, host:"labhost",
            remote_root:$root, spawn_gen:(if $s == "" then null else $s end)},
     actual_model:(if $m == "" then null else $m end)}'
}

# ---------------------------------------------------------------------------
# S1: a launch that finds a supervisor already running on ANOTHER model is
# recognized by the receipt that observed it, and enabling pools around that
# pre-pool supervisor does not block pooled launches fleet-wide.
# ---------------------------------------------------------------------------
scenario_observing_receipt() {
  local d="$LAB/s1" parent="$LAB/s1/parent" host="$LAB/s1/host" out rc disp cert verdict
  say "S1 observing receipt recognizes the running model; pools are not blocked fleet-wide"
  mkdir -p "$d"
  setup_lab || { bad "could not create the lab Herdr workspace"; return; }
  "$CODE/bin/fm-lab-home.sh" create "$parent" >/dev/null || bad "could not mark the parent lab home"
  seed_host "$host" ios
  pools "$parent" 3
  register_remote "$parent" ios "$host" labhost
  start_agent_pane s1 "$d/agent" || { bad "could not start a real agent pane"; return; }
  write_meta "$host" ios "$PANE" host.a1 pool-model-a
  verdict=$(state_of "$SESSION:$PANE")
  [ "$verdict" = alive ] && ok "a real Herdr pane with a real agent classifies alive ($SESSION:$PANE)" \
    || bad "the live endpoint classified '$verdict'"

  out=$(serve_remotes "$parent"); printf '%s\n' "$out"
  cert="$parent/state/fleet-seats/remote-ios.cert"
  [ "$(jq -r '.holders | length' "$cert" 2>/dev/null)" = 1 ] \
    && [ "$(jq -r '.holders[0].generation' "$cert" 2>/dev/null)" = host.a1 ] \
    && ok "the primary adopted the pre-pool supervisor once, at generation host.a1" \
    || bad "the pre-pool supervisor was not adopted exactly once"

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
# S2: the host records the generation of a launch that was cancelled before it
# confirmed a startup; the parent must offer THAT generation, the seat ledger
# must accept the replacement end to end, and the host must replace it.
# ---------------------------------------------------------------------------
scenario_cancelled_replacement_generation() {
  local d="$LAB/s2" parent="$LAB/s2/parent" host="$LAB/s2/host" out rc disp prev res
  local d2="$LAB/s2/b" parent2="$LAB/s2/parent2" host2="$LAB/s2/host2"
  say "S2 a replacement replaces the host-recorded generation from a cancelled launch"
  mkdir -p "$d" "$d2"
  setup_lab || { bad "could not create the lab Herdr workspace"; return; }
  "$CODE/bin/fm-lab-home.sh" create "$parent" >/dev/null || bad "could not mark the parent lab home"
  seed_host "$host" ios2
  pools "$parent" 3
  register_remote "$parent" ios2 "$host" labhost
  start_agent_pane s2 "$d/agent" || { bad "could not start a real agent pane"; return; }
  # The host's own record after the cancelled launch reached it: its operation
  # token op4 is the generation this host stores. The endpoint is a real live
  # Herdr pane with a real agent.
  write_meta "$host" ios2 "$PANE" op4 pool-model-a
  [ "$(state_of "$SESSION:$PANE")" = alive ] && ok "a real agent endpoint is alive in the lab session" \
    || bad "the live endpoint is not alive"

  out=$(serve_remotes "$parent" 2>&1); printf '%s\n' "$out"

  # A launch that reached the host and was then cancelled before it confirmed a
  # startup: the host reports the cancellation for the generation the ledger
  # dispatched. The driver supplies that host outcome at the protocol boundary
  # because a real mid-flight cancellation cannot be interrupted deterministically
  # here; the disposition shape is the host's documented seat_disposition.
  route_file "$d/route4.json" "$host" op4
  cycle "$parent" ios2 op4 pool-model-a - "$d/route4.json" >/dev/null 2>&1 || bad "reserve/dispatch op4 failed"
  res=$(host_response ios2 cancelled op4 "" - "$SESSION:$PANE" op4 "$host" pool-model-a)
  printf '%s\n' "$res" > "$d/res4.json"; chmod 600 "$d/res4.json"
  seats "$parent" reconcile-remote ios2 --generation op4 --response-file "$d/res4.json" \
    && ok "the ledger records the cancelled launch as terminal with the route the host reached" \
    || bad "recording the cancelled launch failed"
  seats "$parent" show ios2 | jq -c '[.incarnations[] | {generation, lifecycle, reason: (.disposition.reason // null), route: (.route.target // null)}]' || true

  prev=$(predecessor_of "$parent" ios2 "$host")
  printf 'resolved predecessor: %s\n' "$prev"
  [ "$prev" = op4 ] \
    && ok "the parent offers the cancelled launch as the generation the host records" \
    || bad "the parent offered '$prev' instead of the host-recorded cancelled generation op4"

  # The replacement reserve/dispatch must not be blocked by the cancelled
  # generation it is replacing (this is the end-to-end reservation leg).
  route_file "$d/route7.json" "$host" op7
  if cycle "$parent" ios2 op7 pool-model-a "$prev" "$d/route7.json" >"$d/cycle7.out" 2>&1; then
    ok "the parent reserved and dispatched the replacement against the cancelled predecessor"
  else
    bad "the parent could not reserve the replacement: $(cat "$d/cycle7.out")"
  fi
  seats "$parent" show ios2 | jq -c '[.incarnations[] | {generation, lifecycle, launch_phase, previous_generation}]' || true

  # The host checks the offered predecessor against the generation it records,
  # and replaces THAT generation rather than an older one.
  out=$(payload "$parent" ios2 op7 | control "$host" launch ios2 pi pool-model-a - herdr --operation op7 --previous "$prev")
  rc=$?
  disp=$(printf '%s\n' "$out" | disposition_of)
  printf 'replacement rc=%s\n%s\n' "$rc" "$out"
  case "$out" in
    *generation-mismatch*) bad "the host refused the replacement that named its recorded generation" ;;
    *)
      [ "$rc" -eq 0 ] && printf '%s\n' "$disp" | jq -e --arg g "$prev" \
        '.disposition == "existing" and .actual_generation == $g and .startup_confirmed == true' >/dev/null 2>&1 \
        && ok "the host replaced the generation it recorded for the cancelled launch" \
        || bad "the replacement did not confirm the host-recorded generation: rc=$rc $disp"
      ;;
  esac
  # The declared outcome names the host-recorded generation, so the parent holds
  # evidence bound to the generation the replacement displaced.
  printf '%s\n' "$disp" | jq -e --arg g "$prev" --arg r op7 \
    '.actual_generation == $g and .requested_generation == $r' >/dev/null 2>&1 \
    && ok "the replacement outcome binds the host-recorded generation $prev to the candidate" \
    || bad "the replacement outcome does not bind the host-recorded generation"

  # Adversarial: the same replacement flow naming an OLDER generation than the
  # one the host records must still be refused (the retry loop this change
  # removes), so the host check has not simply been relaxed.
  "$CODE/bin/fm-lab-home.sh" create "$parent2" >/dev/null || bad "could not mark the second parent lab home"
  seed_host "$host2" ios2b
  pools "$parent2" 3
  register_remote "$parent2" ios2b "$host2" labhost
  write_meta "$host2" ios2b "$PANE" op4 pool-model-a
  serve_remotes "$parent2" > "$d2/serve.out" 2>&1
  route_file "$d2/route6.json" "$host2" op6
  cycle "$parent2" ios2b op6 pool-model-a host.a9 "$d2/route6.json" >/dev/null 2>&1 \
    || bad "reserve/dispatch op6 failed"
  out=$(payload "$parent2" ios2b op6 | control "$host2" launch ios2b pi pool-model-a - herdr --operation op6 --previous host.a9)
  rc=$?
  printf 'older-predecessor rc=%s\n%s\n' "$rc" "$out"
  [ "$rc" -eq 6 ] && printf '%s\n' "$out" | grep -q 'generation-mismatch' \
    && ok "the host still refuses a predecessor it does not record" \
    || bad "the host accepted a predecessor it does not record: rc=$rc"
}

# ---------------------------------------------------------------------------
# S5: a generation the serve certificate proves must never be mistaken for one
# the seat ledger failed to issue - the failed-first-spawn shape where the
# parent holds only a released candidate row yet the host supervisor runs a
# certificate-proved generation.
# ---------------------------------------------------------------------------
scenario_certificate_generation() {
  local d="$LAB/s5" parent="$LAB/s5/parent" host="$LAB/s5/host" out rc
  say "S5 a certificate-proved generation is counted, not refused as a ledger-unknown generation"
  mkdir -p "$d"
  setup_lab || { bad "could not create the lab Herdr workspace"; return; }
  "$CODE/bin/fm-lab-home.sh" create "$parent" >/dev/null || bad "could not mark the parent lab home"
  seed_host "$host" ios5
  pools "$parent" 3
  register_remote "$parent" ios5 "$host" labhost
  start_agent_pane s5 "$d/agent" || { bad "could not start a real agent pane"; return; }
  write_meta "$host" ios5 "$PANE" cert.b1 pool-model-a
  [ "$(state_of "$SESSION:$PANE")" = alive ] || bad "the live endpoint is not alive"

  out=$(serve_remotes "$parent" 2>&1); printf '%s\n' "$out"
  local cert="$parent/state/fleet-seats/remote-ios5.cert"
  # A failed first pooled spawn: the ledger holds only a released candidate for
  # this remote, so the generation the running supervisor reports was never
  # issued by the ledger.
  seats "$parent" reserve ios5 --generation fail1 --kind secondmate --harness pi \
    --model pool-model-a --holder-pid "$$" > "$d/fail1.out" 2>&1 \
    || bad "reserve fail1 failed: $(cat "$d/fail1.out")"
  seats "$parent" release ios5 --generation fail1 --reason prelaunch >/dev/null 2>&1 \
    || bad "release fail1 failed"
  [ "$(jq -r '.holders[0].generation' "$cert" 2>/dev/null)" = cert.b1 ] \
    && ok "the serve certificate proves the running supervisor at generation cert.b1" \
    || bad "the certificate does not prove the running supervisor generation"

  # The parent's pre-generation route record for the supervisor: no spawn_gen,
  # so its identity can only come from the certificate.
  mkdir -p "$parent/state"
  printf 'kind=secondmate\nharness=pi\nbackend=herdr\nwindow=%s:%s\nendpoint_task_id=ios5\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s:t1\nherdr_pane_id=%s\nworktree=%s\nproject=%s\nhome=%s\nmodel=pool-model-a\nremote_host=labhost\nremote_root=%s\nremote_target=%s:%s\nremote_backend=herdr\nremote_herdr_session=%s\n' \
    "$SESSION" "$PANE" "$SESSION" "$SETUP_WS" "$SETUP_WS" "$PANE" "$host" "$CODE" "$host" \
    "$CODE" "$SESSION" "$PANE" "$SESSION" > "$parent/state/ios5.meta"

  seats "$parent" reserve contender --generation opc --harness pi --model pool-model-b \
    --holder-pid "$$" > "$d/contender.out" 2>&1
  rc=$?
  printf '%s\n' "$(cat "$d/contender.out")"
  [ "$rc" -eq 0 ] && ok "counting the certificate-proved generation admits a pooled launch (no ledger-history refusal)" \
    || bad "the certificate-proved generation blocked admission: rc=$rc"
  printf '%s\n' "$(cat "$d/contender.out")" | grep -qi 'never issued' \
    && bad "the certificate generation was mistaken for one the ledger failed to issue" \
    || ok "the certificate generation is exempt from the ledger-history check"
  seats "$parent" show ios5 | jq -c '[.incarnations[]? | {generation, lifecycle}]' || true
  seats "$parent" show ios5 | jq -e '[.incarnations[]? | .generation] | index("cert.b1") | not' >/dev/null \
    && ok "the certificate generation stays out of the ledger history" \
    || bad "the certificate generation leaked into the ledger history"
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
  local d="$LAB/s3" root host out rc
  say "S3 a retirement retry refuses to delete a reseeded public home"
  mkdir -p "$d/root/state" "$d/host/bin" "$d/host/state/parent-route"
  root="$d/root"; host="$d/host"
  printf 'ios3\n' > "$d/host/.fm-secondmate-home"
  printf '# lab\n' > "$d/host/AGENTS.md"
  printf 'kind=secondmate\nbackend=herdr\nwindow=fm-remote:w9:p9\nendpoint_task_id=ios3\nherdr_session=fm-remote\nherdr_workspace_id=w9\nherdr_tab_id=w9:t9\nherdr_pane_id=w9:p9\nworktree=%s\nproject=%s\nhome=%s\nmodel=pool-model-a\nspawn_gen=retg1\n' \
    "$host" "$CODE" "$host" > "$host/state/parent-route/ios3.meta"
  pending_evidence "$root" ios3 retg1 "$host"

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

  mkdir -p "$host/state/parent-route"
  printf 'kind=secondmate\nbackend=herdr\nwindow=fm-remote:w9:p9\nendpoint_task_id=ios3\nherdr_session=fm-remote\nherdr_workspace_id=w9\nherdr_tab_id=w9:t9\nherdr_pane_id=w9:p9\nworktree=%s\nproject=%s\nhome=%s\nmodel=pool-model-a\nspawn_gen=retg2\n' \
    "$host" "$CODE" "$host" > "$host/state/parent-route/ios3.meta"
  out=$(retire "$root" "$host" retire ios3 --force --expect-generation retg1)
  rc=$?
  printf 'successor retry rc=%s\n%s\n' "$rc" "$out"
  [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'generation-mismatch' \
    && ok "a successor generation at the same path is refused" || bad "a successor generation was retired: rc=$rc"
  [ -f "$host/sentinel" ] && ok "the successor home survived the refusal" || bad "the successor home was removed"

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

# ---------------------------------------------------------------------------
# S4: one generation-bound capacity shared by the primary, a local secondmate
# home, and a remote secondmate host; a certificate-proved generation must not
# be mistaken for one the ledger failed to issue.
# ---------------------------------------------------------------------------
scenario_shared_capacity() {
  local d="$LAB/s4" parent="$LAB/s4/parent" localmate="$LAB/s4/local" host="$LAB/s4/host" out rc cert
  say "S4 primary, local secondmate and remote host share one capacity without over-dispatching"
  mkdir -p "$d"
  setup_lab || { bad "could not create the lab Herdr workspace"; return; }
  "$CODE/bin/fm-lab-home.sh" create "$parent" >/dev/null || bad "could not mark the parent lab home"
  seed_host "$host" ios4
  pools "$parent" 2
  register_remote "$parent" ios4 "$host" labhost
  start_agent_pane s4 "$d/agent" || { bad "could not start a real agent pane"; return; }
  write_meta "$host" ios4 "$PANE" cert.a1 pool-model-a
  [ "$(state_of "$SESSION:$PANE")" = alive ] || bad "the live endpoint is not alive"

  out=$(serve_remotes "$parent" 2>&1); printf '%s\n' "$out"
  cert="$parent/state/fleet-seats/remote-ios4.cert"
  [ "$(jq -r '.complete' "$cert" 2>/dev/null)" = true ] \
    && ok "the remote serve published a complete certificate holding its supervisor" \
    || bad "the remote serve did not publish a certificate: $out"
  [ "$(jq -r '.holders[0].generation' "$cert" 2>/dev/null)" = cert.a1 ] \
    && ok "the certificate proves the supervisor's generation cert.a1" \
    || bad "the certificate does not name the host generation"

  # A local secondmate home whose parent binding leads to the primary shares
  # the same pools, and its running agent is charged to the same capacity.
  "$CODE/bin/fm-lab-home.sh" create "$localmate" >/dev/null
  printf 'local\n' > "$localmate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$localmate/.fm-secondmate-parent"
  printf '# lab\n' > "$localmate/AGENTS.md"
  mkdir -p "$localmate/state/parent-route"
  register_local "$parent" localmate "$localmate"
  start_agent_pane s4local "$d/agent-local" || bad "could not start the local secondmate agent"
  write_meta "$localmate" localmate "$PANE" local.a1 pool-model-a
  seats "$localmate" reserve localmate --generation local.b1 --harness pi --model pool-model-a \
    --holder-pid "$$" > "$d/local-reserve.out" 2>&1
  rc=$?
  printf 'local seat rc=%s: %s\n' "$rc" "$(cat "$d/local-reserve.out")"
  [ "$rc" -eq 0 ] && ok "the local secondmate home is charged to the shared capacity" \
    || bad "the local secondmate home could not take its seat: rc=$rc"
  seats "$parent" show localmate 2>/dev/null | jq -c '[.incarnations[]? | {generation, lifecycle}]' || true

  # Count: local secondmate holder (1) + adopted remote supervisor (1) = full.
  seats "$parent" reserve overflow --generation op5 --harness pi --model pool-model-b \
    --holder-pid "$$" > "$d/overflow.out" 2>&1
  rc=$?
  printf 'overflow rc=%s: %s\n' "$rc" "$(cat "$d/overflow.out")"
  [ "$rc" -eq 4 ] && ok "a fourth launch is refused as full (exit 4), not as unaccounted (exit 5)" \
    || bad "over-dispatch was not refused as a full pool: rc=$rc"
  printf '%s\n' "$(cat "$d/overflow.out")" | grep -q 'holder remote:ios4:' \
    && printf '%s\n' "$(cat "$d/overflow.out")" | grep -q "holder $localmate/state localmate" \
    && ok "the full-pool refusal lists the remote-host and local-secondmate holders it counted" \
    || bad "the full-pool refusal does not list both shared holders"
  local remote_ledger
  remote_ledger=$(seats "$parent" show ios4 2>/dev/null || true)
  if [ -z "$remote_ledger" ]; then
    ok "the counted host supervisor is not recorded as a ledger-issued generation"
  else
    printf '%s\n' "$remote_ledger" | jq -e '[.incarnations[]? | .generation] | index("cert.a1") | not' >/dev/null \
      && ok "the counted host supervisor is not recorded as a ledger-issued generation" \
      || bad "the certificate generation leaked into the ledger history"
  fi

  # Freeing the local seat admits the next pooled launch; capacity is one
  # generation-bound counter, not per-home.
  seats "$localmate" release localmate --generation local.b1 --reason prelaunch >/dev/null 2>&1 \
    || bad "releasing the local seat failed"
  seats "$parent" reserve overflow --generation op5 --harness pi --model pool-model-b \
    --holder-pid "$$" > "$d/overflow2.out" 2>&1
  rc=$?
  printf 'after release rc=%s: %s\n' "$rc" "$(cat "$d/overflow2.out")"
  [ "$rc" -eq 0 ] && ok "releasing the local seat frees exactly one shared seat" \
    || bad "the shared capacity did not free the released seat: rc=$rc"
}


# ---------------------------------------------------------------------------
# S6: a remote secondmate recorded under an isolated fm-lab session resolves
# its predecessor through that session and relaunches on it. A disposable
# clone of this checkout stands in for the remote host's own code root so the
# remote job worker can start a real agent there; the product code is the
# same commit under test.
# ---------------------------------------------------------------------------
scenario_lab_session_relaunch() {
  local S6="$LAB/s6" CODE_LAB="$LAB/s6/code" HOSTHOME="$LAB/s6/host" MODEL
  local P1="$LAB/s6/p1" P2="$LAB/s6/p2" GEN1 GEN2 GEN3 TARGET1 TARGET2 TARGET3 NEWGEN st rc rc2
  MODEL=qualitycorp-oq/DeepSeek-V4.1-Flash-iQ3-3.0bpw
  say "S6 a lab-session remote secondmate resolves its predecessor and relaunches on that same session"
  mkdir -p "$S6"
  git clone --quiet --no-hardlinks "$CODE" "$CODE_LAB" || { bad "could not clone a disposable remote code root"; return; }
  printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$(command -v pi)" > "$CODE_LAB/bin/pi"
  cp "$LAB/bin/herdr" "$CODE_LAB/bin/herdr"
  chmod +x "$CODE_LAB/bin/pi" "$CODE_LAB/bin/herdr"
  "$CODE/bin/fm-lab-home.sh" create "$S6/seedparent" >/dev/null || bad "could not mark the seed parent home"
  FM_HOME="$S6/seedparent" FM_ROOT_OVERRIDE="$CODE_LAB" FM_SECONDMATE_CHARTER='Own lab delivery.' \
    FM_SECONDMATE_SCOPE='lab' "$CODE_LAB/bin/fm-home-seed.sh" ios "$HOSTHOME" --no-projects >/dev/null 2>&1 \
    || { bad "could not provision the host secondmate home"; return; }
  # The host's own durable binding says its fleet root is a different host, so
  # bin/fm-fleet-seats.sh serves here instead of treating this home as its root.
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=labhost\n' > "$HOSTHOME/.fm-secondmate-parent"

  s6_meta() { sed -n "s/^$2=//p" "$1"; }
  s6_hostctl() { # <home> <args...>
    local home=$1
    shift
    ( cd "$LAB" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE \
        -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_HOME -u FM_ROOT_OVERRIDE \
        PATH="$LAB/bin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$CODE_LAB" \
        "$CODE_LAB/bin/fm-remote-secondmate-control.sh" "$@" --herdr-session "$SESSION" 2>&1 )
  }
  s6_seats() { # <home> <args...>
    local home=$1
    shift
    ( cd "$LAB" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE \
        -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_PROJECTS_OVERRIDE \
        PATH="$LAB/bin:$PATH" FM_HOME="$home" "$CODE/bin/fm-fleet-seats.sh" "$@" )
  }
  s6_write_parent_meta() { # <parent> <target> <model>
    cat > "$1/state/ios.meta" <<META
window=remote:ios
endpoint_task_id=ios
worktree=$HOSTHOME
project=$CODE_LAB
harness=pi
kind=secondmate
mode=secondmate
yolo=off
model=$3
effort=default
home=$HOSTHOME
projects=
remote_host=labhost
remote_root=$CODE_LAB
remote_backend=herdr
remote_herdr_session=$SESSION
remote_target=$2
remote_spawn_gen=$2
META
  }
  s6_register() { # <parent>
    printf -- '- ios - Lab remote mate. (host: labhost; root: %s; home: %s; scope: lab; projects: ; added 2026-11-01)\n' \
      "$CODE_LAB" "$HOSTHOME" > "$1/data/secondmates.md"
  }
  s6_run_wrapper() { # <parent> <model> <effort>
    ( cd "$LAB" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE \
        -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_PROJECTS_OVERRIDE \
        PATH="$LAB/bin:$PATH" FM_HOME="$1" FM_LAB_ENTRYPOINT="$CODE_LAB/bin/fm-remote-entrypoint.sh" \
        FM_REMOTE_JOB_STATE_ROOT="$LAB/remote-jobs" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
        "$CODE/bin/fm-remote-secondmate-relaunch.sh" ios pi "$2" "$3" 2>&1 )
  }
  s6_agent_state() {
    env PATH="$LAB/bin:$PATH" HERDR_SESSION="$SESSION" \
      bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state herdr "$2"' _ "$CODE" "$1"
  }
  s6_composer_state() {
    env PATH="$LAB/bin:$PATH" HERDR_SESSION="$SESSION" \
      bash -c '. "$1/bin/fm-backend.sh"; fm_backend_composer_state herdr "$2"' _ "$CODE" "$1"
  }
  s6_wait_idle() { # <target>
    local i verdict
    for i in $(seq 1 90); do
      verdict=$(s6_composer_state "$1")
      [ "$verdict" = empty ] && return 0
      sleep 2
    done
    printf 'last composer verdict: %s\n' "${verdict:-none}"
    return 1
  }
  s6_wait_alive() { # <target>
    local i verdict
    for i in $(seq 1 45); do
      verdict=$(s6_agent_state "$1")
      [ "$verdict" = alive ] && { printf '%s' "$verdict"; return 0; }
      sleep 2
    done
    printf '%s' "${verdict:-unreadable}"
    return 1
  }

  s6_hostctl "$HOSTHOME" launch ios pi "$MODEL" - herdr > "$S6/launch.out" 2>&1 \
    || { bad "the real host could not launch a supervisor in the lab session"; cat "$S6/launch.out"; return; }
  cat "$S6/launch.out"
  GEN1=$(s6_meta "$HOSTHOME/state/parent-route/ios.meta" spawn_gen)
  TARGET1=$(s6_meta "$HOSTHOME/state/parent-route/ios.meta" window)
  case "$TARGET1" in
    "$SESSION":*) ok "a real host launch runs its supervisor in the lab session ($TARGET1)" ;;
    *) bad "the launched supervisor is outside the lab session: $TARGET1" ;;
  esac
  [ "$(s6_meta "$HOSTHOME/state/parent-route/ios.meta" model)" = "$MODEL" ] \
    && ok "the lab-session endpoint records the requested model" \
    || bad "the lab-session endpoint did not record the requested model"

  # The guard this change must satisfy: without forwarding the recorded session
  # the same host refuses access to the endpoint it owns.
  ( cd "$LAB" && env PATH="$LAB/bin:$PATH" FM_HOME="$HOSTHOME" FM_ROOT_OVERRIDE="$CODE_LAB" \
      "$CODE_LAB/bin/fm-remote-secondmate-control.sh" route ios ) > "$S6/route-default.out" 2>&1 || true
  cat "$S6/route-default.out"
  grep -q "expected 'fm-remote'" "$S6/route-default.out" \
    && ok "route without the recorded lab session is refused, so the wrapper must forward it" \
    || bad "the default-session route did not refuse the lab endpoint"

  # A. Uncapped: the predecessor can only come from the host's route answer on
  # the recorded lab session.
  "$CODE/bin/fm-lab-home.sh" create "$P1" >/dev/null
  s6_write_parent_meta "$P1" "$TARGET1" "$MODEL"
  s6_register "$P1"
  s6_wait_idle "$TARGET1" || bad "the supervisor never reached an idle composer before the uncapped relaunch"
  s6_run_wrapper "$P1" "$MODEL" - > "$S6/uncapped.out" 2>&1
  rc=$?
  tail -6 "$S6/uncapped.out"
  GEN2=$(s6_meta "$HOSTHOME/state/parent-route/ios.meta" spawn_gen)
  TARGET2=$(s6_meta "$HOSTHOME/state/parent-route/ios.meta" window)
  [ "$rc" -eq 0 ] && ok "the uncapped wrapper relaunched the lab-recorded secondmate (rc=0)" \
    || bad "the uncapped wrapper failed (rc=$rc)"
  [ "$GEN2" != "$GEN1" ] && ok "the host recorded a new generation ($GEN1 -> $GEN2)" \
    || bad "the host generation did not change"
  case "$TARGET2" in
    "$SESSION":*) ok "the replacement endpoint stayed on the same lab session ($TARGET2)" ;;
    *) bad "the replacement left the lab session: $TARGET2" ;;
  esac
  [ "$(s6_meta "$P1/state/ios.meta" remote_spawn_gen)" = "$GEN2" ] \
    && ok "the parent republished the generation the host confirmed" \
    || bad "the parent did not republish the host-confirmed generation"
  [ "$(s6_meta "$P1/state/ios.meta" remote_target)" = "$TARGET2" ] \
    && ok "the parent republished the replacement's lab-session target" \
    || bad "the parent did not republish the replacement target"
  st=$(s6_wait_alive "$TARGET2")
  [ "$st" = alive ] && ok "the replacement agent answers alive on that endpoint" \
    || bad "the replacement agent reads '$st'"

  # B. Capped: the predecessor comes from the shared ledger and the relaunch
  # travels as the parent's generation-bound seat operation.
  "$CODE/bin/fm-lab-home.sh" create "$P2" >/dev/null
  s6_write_parent_meta "$P2" "$TARGET2" "$MODEL"
  s6_register "$P2"
  printf '{"pools":[{"name":"shared","capacity":4,"models":["%s"]}]}\n' "$MODEL" > "$P2/config/fleet-seats"
  LAB_ENTRYPOINT="$CODE_LAB/bin/fm-remote-entrypoint.sh" serve_remotes "$P2" > "$S6/serve.out" 2>&1
  cat "$S6/serve.out"
  [ -f "$P2/state/fleet-seats/remote-ios.cert" ] \
    && ok "the primary served the lab host and published its certificate" \
    || bad "the primary did not publish a serve certificate for the lab host"
  s6_seats "$P2" reserve ios --generation "$GEN2" --kind secondmate --harness pi \
    --model "$MODEL" --holder-pid "$$" > "$S6/reserve.out" 2>&1 \
    || bad "could not record the running supervisor's parent generation: $(cat "$S6/reserve.out")"
  (umask 077; jq -cn --arg home "$HOSTHOME" --arg root "$CODE_LAB" --arg op "$GEN2" --arg t "$TARGET2" \
    '{placement:"remote",backend:"herdr",target:$t,home:$home,host:"labhost",remote_root:$root,spawn_gen:$op,operation:$op}' \
    > "$S6/route.json")
  s6_seats "$P2" dispatch ios --generation "$GEN2" --route-file "$S6/route.json" > "$S6/dispatch.out" 2>&1 \
    || bad "could not dispatch the recorded generation: $(cat "$S6/dispatch.out")"
  (umask 077; jq -cn --arg t ios --arg g "$GEN2" --arg home "$HOSTHOME" --arg root "$CODE_LAB" \
    --arg tg "$TARGET2" --arg m "$MODEL" \
    '{schema:"fm-remote-seat-operation.v2",complete:true,task:$t,operation:$g,requested_generation:$g,
      actual_generation:$g,previous_generation:null,disposition:"started",startup_confirmed:true,
      old_stopped:false,old_destroyed:false,
      route:{placement:"remote",backend:"herdr",target:$tg,home:$home,host:"labhost",remote_root:$root,spawn_gen:$g},
      actual_model:$m}' > "$S6/started.json")
  s6_seats "$P2" reconcile-remote ios --generation "$GEN2" --response-file "$S6/started.json" \
    > "$S6/reconcile.out" 2>&1 \
    || bad "could not confirm the recorded generation: $(cat "$S6/reconcile.out")"
  s6_seats "$P2" show ios | jq -c '[.incarnations[] | {generation, lifecycle, launch_phase}]'
  s6_wait_idle "$TARGET2" || bad "the supervisor never reached an idle composer before the capped relaunch"
  s6_run_wrapper "$P2" "$MODEL" - > "$S6/capped.out" 2>&1
  rc2=$?
  tail -8 "$S6/capped.out"
  GEN3=$(s6_meta "$HOSTHOME/state/parent-route/ios.meta" spawn_gen)
  TARGET3=$(s6_meta "$HOSTHOME/state/parent-route/ios.meta" window)
  [ "$rc2" -eq 0 ] && ok "the capped wrapper relaunched through the parent's seat operation (rc=0)" \
    || bad "the capped wrapper failed (rc=$rc2)"
  [ "$GEN3" != "$GEN2" ] && ok "the host recorded the capped replacement generation ($GEN2 -> $GEN3)" \
    || bad "the capped host generation did not change"
  case "$TARGET3" in
    "$SESSION":*) ok "the capped replacement stayed on the same lab session ($TARGET3)" ;;
    *) bad "the capped replacement left the lab session: $TARGET3" ;;
  esac
  NEWGEN=$(s6_meta "$P2/state/ios.meta" fleet_seat_generation)
  s6_seats "$P2" show ios | jq -c '[.incarnations[] | {generation, lifecycle, previous_generation, target: .route.target}]'
  [ -n "$NEWGEN" ] && ok "the parent recorded the replacement's fleet seat generation ($NEWGEN)" \
    || bad "the parent recorded no fleet seat generation"
  s6_seats "$P2" show ios | jq -e --arg g "$GEN2" \
    '[.incarnations[] | select(.generation == $g) | .lifecycle] | .[0] == "released"' >/dev/null \
    && ok "the replaced generation was released" || bad "the replaced generation was not released"
  s6_seats "$P2" show ios | jq -e --arg g "$NEWGEN" --arg s "$GEN3" --arg t "$TARGET3" \
    'any(.incarnations[]; .generation == $g and .lifecycle == "confirmed"
      and .route.spawn_gen == $s and .route.target == $t)' >/dev/null \
    && ok "the replacement is confirmed against the host generation and lab-session target" \
    || bad "the replacement's ledger binding is wrong"
  st=$(s6_wait_alive "$TARGET3")
  [ "$st" = alive ] && ok "the capped replacement agent answers alive on that endpoint" \
    || bad "the capped replacement agent reads '$st'"
  [ ! -e "$LAB/violations.log" ] \
    && ok "no Herdr call outside this run's lab session was attempted" \
    || bad "a foreign Herdr session was addressed: $(cat "$LAB/violations.log")"
}

for s in "$@"; do
  case "$s" in
    s1) scenario_observing_receipt ;;
    s2) scenario_cancelled_replacement_generation ;;
    s3) scenario_reseeded_home_retirement_retry ;;
    s4) scenario_shared_capacity ;;
    s5) scenario_certificate_generation ;;
    s6) scenario_lab_session_relaunch ;;
    *) bad "unknown scenario $s" ;;
  esac
done
printf '\n===\n'
if [ "$FAILED" -eq 0 ]; then echo "RESULT: all driven live scenarios passed"; else echo "RESULT: live scenarios FAILED"; fi
exit "$FAILED"
