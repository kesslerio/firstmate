#!/usr/bin/env bash
# Live fleet-seat-pool scenarios against the real bin/fm-fleet-seats.sh.
#
# The product under test is the seat accounting CLI: every grant, ledger
# record, serve certificate, and policy delivery below is produced by the real
# scripts in the gate worktree. Only the SSH transport is replaced, through the
# product's own documented FM_SSH_BIN seam, because this machine has no second
# host; the real bin/fm-on.sh, bin/fm-remote-entrypoint.sh, the real remote job
# worker, and bin/fm-fleet-seats.sh serve run unchanged against a disposable
# remote home on the same filesystem.
set -u

CODE=${CODE:?}
LAB=${LAB:?}
SEATS="$CODE/bin/fm-fleet-seats.sh"
FAILED=0

say() { printf '\n### %s\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAILED=1; }

seats() {  # <home> <args...>
  local home=$1
  shift
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$home" "$SEATS" "$@"
}

new_holder() {  # sets HOLDER (a live pid, as the product requires)
  sleep 600 >/dev/null 2>&1 &
  HOLDER=$!
  HOLDERS="$HOLDERS $HOLDER"
}

make_home() { mkdir -p "$1/state" "$1/config" "$1/data"; }

pools() {  # <home> <capacity>
  printf '{"pools":[{"name":"shared","capacity":%s,"models":["pool-model-a","pool-model-b"]}]}\n' \
    "$2" > "$1/config/fleet-seats"
}

# ---------------------------------------------------------------------------
# Scenario 1: one generation-bound capacity across the primary and a local
# secondmate, with a full pool refusing the next launch instead of
# over-dispatching.
# ---------------------------------------------------------------------------
scenario_local_capacity() {
  local root="$LAB/local/primary" mate="$LAB/local/android" out status
  say "S1 primary + local secondmate share one capacity"
  make_home "$root"
  make_home "$mate"
  pools "$root" 2
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$root" > "$mate/.fm-secondmate-parent"
  printf 'android\n' > "$mate/.fm-secondmate-home"
  printf -- '- android - Lab mate. (home: %s; scope: lab; projects: ; added 2026-11-01)\n' "$mate" \
    >> "$root/data/secondmates.md"

  new_holder
  out=$(seats "$root" reserve r1 --generation g-r1 --harness pi --model pool-model-a \
    --holder-pid "$HOLDER" 2>&1); status=$?
  printf '%s\n' "$out"
  [ "$status" -eq 0 ] && [ "${out#*used=}" != "$out" ] && ok "primary reserved the first seat (${out##*fleet-seats: })" \
    || bad "primary's first reservation failed: rc=$status"

  new_holder
  out=$(seats "$mate" reserve a1 --generation g-a1 --harness pi --model pool-model-b \
    --holder-pid "$HOLDER" 2>&1); status=$?
  printf '%s\n' "$out"
  [ "$status" -eq 0 ] && grep -q 'used=2 capacity=2' <<<"$out" \
    && ok "the local secondmate's launch was counted in the primary's pool" \
    || bad "second home did not join the primary's capacity: rc=$status $out"

  new_holder
  out=$(seats "$root" reserve r2 --generation g-r2 --harness pi --model pool-model-a \
    --holder-pid "$HOLDER" 2>&1); status=$?
  printf '%s\n' "$out"
  [ "$status" -eq 4 ] && grep -q 'is full (2 of 2 seats held)' <<<"$out" \
    && grep -q 'android' <<<"$out" \
    && ok "a third launch across the two homes was refused, naming the holders" \
    || bad "the full pool admitted a third launch: rc=$status"

  seats "$mate" release a1 --generation g-a1 --reason prelaunch >/dev/null 2>&1 \
    || bad "releasing the secondmate's generation failed"
  new_holder
  out=$(seats "$root" reserve r2 --generation g-r2 --harness pi --model pool-model-a \
    --holder-pid "$HOLDER" 2>&1); status=$?
  printf '%s\n' "$out"
  [ "$status" -eq 0 ] && grep -q 'used=2 capacity=2' <<<"$out" \
    && ok "the released generation freed exactly one seat for the waiting launch" \
    || bad "the waiting launch was not admitted after a release: rc=$status"

  # Generation binding: a same-pool replacement keeps one seat, and the
  # terminal predecessor never revives.
  new_holder
  out=$(seats "$root" reserve r1 --generation g-r1-next --previous-generation g-r1 \
    --harness pi --model pool-model-a --holder-pid "$HOLDER" 2>&1); status=$?
  printf '%s\n' "$out"
  [ "$status" -eq 0 ] && grep -q 'already held' <<<"$out" \
    && ok "a same-pool replacement generation reused its predecessor's seat" \
    || bad "a same-pool replacement took a second seat: rc=$status $out"
  # Without proof that the predecessor stopped, the replacement keeps the
  # old generation counted: a candidate alone never frees capacity.
  seats "$root" show r1 | jq -c '.incarnations[] | {generation, lifecycle, launch_phase}' 2>/dev/null || true
  [ "$(seats "$root" show r1 | jq -r '.incarnations[] | select(.generation=="g-r1") | .lifecycle')" = reserved ] \
    && ok "the unproven predecessor generation stays counted beside its replacement" \
    || bad "a replacement freed its predecessor without proof it stopped"
  seats "$root" release r1 --generation g-r1 --reason replaced >/dev/null 2>&1 \
    && bad "an unproven 'replaced' release was accepted" \
    || ok "an unproven 'replaced' release is refused, so the old seat stays counted"
}

# ---------------------------------------------------------------------------
# Scenario 2: two launches race for the last seat.
# ---------------------------------------------------------------------------
scenario_race_for_last_seat() {
  local root="$LAB/race/primary" mate="$LAB/race/android" d="$LAB/race" out rc_a rc_b
  say "S2 two simultaneous launches race for the last seat"
  make_home "$root"
  make_home "$mate"
  pools "$root" 1
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$root" > "$mate/.fm-secondmate-parent"
  printf 'android\n' > "$mate/.fm-secondmate-home"
  printf -- '- android - Lab mate. (home: %s; scope: lab; projects: ; added 2026-11-01)\n' "$mate" \
    >> "$root/data/secondmates.md"
  mkdir -p "$d"
  new_holder; local ha=$HOLDER
  new_holder; local hb=$HOLDER
  (
    out=$(seats "$root" reserve racer-a --generation g-a --harness pi --model pool-model-a \
      --holder-pid "$ha" 2>&1); echo "$?" > "$d/rc-a"; printf '%s\n' "$out" > "$d/out-a"
  ) &
  local pa=$!
  (
    out=$(seats "$mate" reserve racer-b --generation g-b --harness pi --model pool-model-a \
      --holder-pid "$hb" 2>&1); echo "$?" > "$d/rc-b"; printf '%s\n' "$out" > "$d/out-b"
  ) &
  local pb=$!
  wait "$pa"; wait "$pb"
  rc_a=$(cat "$d/rc-a"); rc_b=$(cat "$d/rc-b")
  printf 'primary rc=%s: %s\nsecondmate rc=%s: %s\n' "$rc_a" "$(cat "$d/out-a")" "$rc_b" "$(cat "$d/out-b")"
  if { [ "$rc_a" = 0 ] && [ "$rc_b" = 4 ]; } || { [ "$rc_a" = 4 ] && [ "$rc_b" = 0 ]; }; then
    ok "exactly one of two simultaneous launches won the single seat"
  else
    bad "the race overbooked or refused both: rc_a=$rc_a rc_b=$rc_b"
  fi
}

# ---------------------------------------------------------------------------
# Scenario 3: a supervisor already running on a remote host before pools were
# declared counts exactly once, and the certificate-proved generation is not
# judged against seat-ledger history.
# ---------------------------------------------------------------------------
make_fake_ssh() {  # <path>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
[ "$1" = shop-host ] || exit 91
[ "$2" = fm-remote-entrypoint.sh ] || exit 92
shift 2
exec "$FM_LAB_ENTRYPOINT" "$@"
SH
  chmod +x "$1"
}

serve_remotes() {  # <root>
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$1" FM_SSH_BIN="$LAB/bin/ssh" FM_LAB_ENTRYPOINT="$CODE/bin/fm-remote-entrypoint.sh" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$LAB/remote-jobs" \
    "$SEATS" serve-remotes
}

scenario_prepool_supervisor_and_certificate_generation() {
  local root="$LAB/remote/primary" remote="$LAB/remote/theshop" out status cert
  say "S3 a pre-pool remote supervisor is counted once; the certificate-proved generation is not treated as unissued"
  make_home "$root"
  make_home "$remote"
  make_fake_ssh "$LAB/bin/ssh"
  pools "$root" 3
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=primary\n' > "$remote/.fm-secondmate-parent"
  printf 'theshop\n' > "$remote/.fm-secondmate-home"
  printf -- '- theshop - Lab remote mate. (host: shop-host; root: %s; home: %s; scope: lab; projects: ; added 2026-11-01)\n' \
    "$CODE" "$remote" >> "$root/data/secondmates.md"
  # The host-side record of a supervisor that was already running before pools
  # existed (the durable parent-route record the host control plane writes).
  mkdir -p "$remote/state/parent-route"
  printf 'kind=secondmate\nmodel=pool-model-a\nspawn_gen=host.1\n' \
    > "$remote/state/parent-route/theshop.meta"

  out=$(serve_remotes "$root" 2>&1); status=$?
  printf '%s\n' "$out"
  [ "$status" -eq 0 ] && grep -q 'served theshop' <<<"$out" \
    && ok "the primary served the remote and adopted the running supervisor" \
    || bad "the first serve failed: rc=$status"

  cert="$root/state/fleet-seats/remote-theshop.cert"
  printf 'certificate holders: %s\n' "$(jq -c '.holders' "$cert" 2>/dev/null)"
  [ "$(jq --arg st "$remote/state/parent-route" \
      '.holders | any(.state_dir == $st and .task == "theshop" and .generation == "host.1" and .model == "pool-model-a")' \
      "$cert" 2>/dev/null)" = true ] \
    && ok "the serve certificate reports the pre-pool supervisor's own generation and model" \
    || bad "the certificate did not report the pre-pool supervisor"

  new_holder
  out=$(seats "$root" reserve contender --generation g-contender --harness pi \
    --model pool-model-a --holder-pid "$HOLDER" 2>&1); status=$?
  printf '%s\n' "$out"
  [ "$status" -eq 0 ] && grep -q 'used=2 capacity=3' <<<"$out" \
    && ok "the adopted supervisor consumed exactly one of three seats" \
    || bad "the adopted supervisor was not counted once: rc=$status $out"

  # The primary's own route record for that same registered remote must not be
  # charged a second seat beside the certificate's holder.
  printf 'kind=secondmate\nmodel=pool-model-a\nremote_host=shop-host\nremote_root=%s\nhome=%s\n' \
    "$CODE" "$remote" > "$root/state/theshop.meta"
  out=$(serve_remotes "$root" 2>&1); status=$?
  printf 'primary route record added; serve: %s\n' "$out"
  seats "$root" release contender --generation g-contender --reason prelaunch >/dev/null 2>&1
  new_holder
  out=$(seats "$root" reserve contender2 --generation g-contender2 --harness pi \
    --model pool-model-a --holder-pid "$HOLDER" 2>&1); status=$?
  printf '%s\n' "$out"
  [ "$status" -eq 0 ] && grep -q 'used=2 capacity=3' <<<"$out" \
    && ok "the primary's own route record was not charged beside the certificate's holder" \
    || bad "one supervisor spent two seats: rc=$status $out"

  new_holder
  out=$(seats "$root" reserve filler --generation g-filler --harness pi \
    --model pool-model-a --holder-pid "$HOLDER" 2>&1); status=$?
  printf '%s\n' "$out"
  [ "$status" -eq 0 ] && grep -q 'used=3 capacity=3' <<<"$out" \
    && ok "the adopted supervisor and two local holders fill exactly three seats" \
    || bad "three seats did not fill the pool: rc=$status $out"
  new_holder
  out=$(seats "$root" reserve overflow --generation g-overflow --harness pi \
    --model pool-model-a --holder-pid "$HOLDER" 2>&1); status=$?
  printf '%s\n' "$out"
  [ "$status" -eq 4 ] && ok "a fourth launch is refused, so the adopted supervisor is counted" \
    || bad "the pool admitted a fourth holder: rc=$status"

  # A failed first spawn can leave a released candidate as the ledger's only
  # row for that supervisor. The certificate-proved generation must still be
  # accepted instead of being read as a generation the ledger never issued.
  new_holder
  out=$(seats "$root" reserve theshop --generation g-abandoned --harness pi \
    --model pool-model-a --holder-pid "$HOLDER" 2>&1)
  printf 'abandoned candidate reserve rc=%s: %s\n' "$?" "$out"
  seats "$root" release theshop --generation g-abandoned --reason prelaunch >/dev/null 2>&1
  seats "$root" release filler --generation g-filler --reason prelaunch >/dev/null 2>&1
  new_holder
  out=$(seats "$root" reserve spare --generation g-spare --harness pi \
    --model pool-model-a --holder-pid "$HOLDER" 2>&1); status=$?
  printf '%s\n' "$out"
  [ "$status" -eq 0 ] && grep -q 'used=3 capacity=3' <<<"$out" \
    && ok "a released candidate did not contradict the certificate-proved generation (the next launch was counted, not refused)" \
    || bad "the certificate-proved generation was rejected as unissued: rc=$status $out"
}

# ---------------------------------------------------------------------------
# Scenario 4: a real remote secondmate launch goes through the same capacity,
# and an unreachable remote keeps its seats counted instead of freeing them.
# ---------------------------------------------------------------------------
scenario_remote_launch_shares_capacity() {
  local root="$LAB/remote2/primary" remote="$LAB/remote2/ios" d="$LAB/remote2" out status
  say "S4 a remote secondmate launch is granted from the same capacity; an unreachable remote is never free"
  make_home "$root"
  make_home "$remote"
  mkdir -p "$LAB/bin"
  make_fake_ssh "$LAB/bin/ssh"
  pools "$root" 2
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=primary\n' > "$remote/.fm-secondmate-parent"
  printf 'ios\n' > "$remote/.fm-secondmate-home"
  printf -- '- ios - Lab remote mate. (host: shop-host; root: %s; home: %s; scope: lab; projects: ; added 2026-11-01)\n' \
    "$CODE" "$remote" >> "$root/data/secondmates.md"
  mkdir -p "$d"
  serve_remotes "$root" >/dev/null 2>&1 || bad "initial policy delivery failed"

  new_holder
  out=$(seats "$root" reserve primary-worker --generation g-primary --harness pi \
    --model pool-model-a --holder-pid "$HOLDER" 2>&1); status=$?
  printf '%s\n' "$out"
  [ "$status" -eq 0 ] || bad "the primary's own launch was refused: rc=$status"

  new_holder
  ( seats "$remote" reserve ios-worker --generation g-ios --harness pi --model pool-model-a \
      --holder-pid "$HOLDER" > "$d/ios.out" 2>&1; echo "$?" > "$d/ios.rc" ) &
  local pa=$!
  sleep 1
  serve_remotes "$root" >/dev/null 2>&1
  wait "$pa"
  printf 'remote launch rc=%s: %s\n' "$(cat "$d/ios.rc")" "$(cat "$d/ios.out")"
  [ "$(cat "$d/ios.rc")" = 0 ] && grep -q 'granted by the fleet root' "$d/ios.out" \
    && ok "the remote secondmate's launch was granted from the primary's shared capacity" \
    || bad "the remote launch was not granted: $(cat "$d/ios.out")"

  new_holder
  ( seats "$remote" reserve ios-worker-2 --generation g-ios2 --harness pi --model pool-model-a \
      --holder-pid "$HOLDER" > "$d/ios2.out" 2>&1; echo "$?" > "$d/ios2.rc" ) &
  local pb=$!
  sleep 1
  serve_remotes "$root" >/dev/null 2>&1
  wait "$pb"
  printf 'second remote launch rc=%s: %s\n' "$(cat "$d/ios2.rc")" "$(cat "$d/ios2.out")"
  [ "$(cat "$d/ios2.rc")" = 4 ] \
    && ok "a second remote launch was refused because the shared pool was full" \
    || bad "the remote over-dispatched past the shared capacity: $(cat "$d/ios2.out")"

  # The transport now fails: the primary must keep the remote's seats counted
  # and refuse new pooled launches instead of treating them as free.
  printf '#!/usr/bin/env bash\nexit 255\n' > "$LAB/bin/ssh"
  chmod +x "$LAB/bin/ssh"
  serve_remotes "$root" >/dev/null 2>&1 || true
  new_holder
  out=$(seats "$root" reserve after-outage --generation g-outage --harness pi \
    --model pool-model-a --holder-pid "$HOLDER" 2>&1); status=$?
  printf '%s\n' "$out"
  [ "$status" -eq 5 ] && grep -q 'have not confirmed the current seat policy' <<<"$out" \
    && ok "an unreachable remote refused new launches instead of freeing its seats" \
    || bad "an unreachable remote was treated as free: rc=$status $out"
  printf 'last certificate holders: %s\n' "$(jq -c '.holders | map({task, generation, model})' \
    "$root/state/fleet-seats/remote-ios.cert" 2>/dev/null)"
  make_fake_ssh "$LAB/bin/ssh"
}

HOLDERS=
trap 'for p in $HOLDERS; do kill "$p" 2>/dev/null || true; done' EXIT
scenario_local_capacity
scenario_race_for_last_seat
scenario_prepool_supervisor_and_certificate_generation
scenario_remote_launch_shares_capacity
printf '\n===\n'
if [ "$FAILED" -eq 0 ]; then echo "RESULT: all live seat-pool scenarios passed"; else echo "RESULT: live seat-pool scenarios FAILED"; fi
exit "$FAILED"
