#!/usr/bin/env bash
# Disposable live drive of the fleet seat pool CLI (bin/fm-fleet-seats.sh,
# bin/fm-spawn.sh, bin/fm-remote-generation-lib.sh) against throwaway lab
# homes. Every lab home is removed at the end; no real FM_HOME is touched.
set -u

ROOT=${ROOT:-$(pwd)}
SEATS="$ROOT/bin/fm-fleet-seats.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-seat-live.XXXXXX")
HOLDER_PIDS=
trap 'for p in $HOLDER_PIDS; do kill "$p" 2>/dev/null || true; done; rm -rf "$WORK"' EXIT

holder() { sleep 600 >/dev/null 2>&1 & HOLDER_PIDS="$HOLDER_PIDS $!"; LAST_HOLDER=$!; }
seat() { local home=$1; shift; env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
  FM_HOME="$home" "$SEATS" "$@"; }
make_home() { mkdir -p "$1/state" "$1/config" "$1/data"; }
pools() { printf '{"pools":[{"name":"shared","capacity":%s,"models":["demo/model-a","demo/model-b"]}]}\n' "$2" > "$1/config/fleet-seats"; }
task_record() { printf 'kind=%s\nmodel=%s\nharness=claude\n' "${3:-ship}" "$2" > "$1/state/$1-x.meta"; }

echo "########## Scenario 1: one pool across the primary home and its local secondmate; a pre-pool ship counts once"
P="$WORK/s1/primary"; M="$WORK/s1/android"
make_home "$P"; pools "$P" 2
make_home "$M"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$P" > "$M/.fm-secondmate-parent"
printf 'android\n' > "$M/.fm-secondmate-home"
printf -- '- android - Test mate. (home: %s; scope: tests; projects: ; added 2026-09-28)\n' "$M" >> "$P/data/secondmates.md"
# An agent launched before the pool existed: only a task record, no reservation.
printf 'kind=ship\nmodel=demo/model-a\nharness=claude\n' > "$P/state/legacy-agent.meta"

holder; echo "\$ # live launch owner pid $LAST_HOLDER"
echo "\$ fm-fleet-seats.sh reserve r1 --generation g-r1 --kind ship --harness claude --model demo/model-a --holder-pid $LAST_HOLDER   (FM_HOME=primary)"
seat "$P" reserve r1 --generation g-r1 --kind ship --harness claude --model demo/model-a --holder-pid "$LAST_HOLDER"; echo "exit=$?"
echo
holder
echo "\$ fm-fleet-seats.sh reserve a1 --generation g-a1 --kind ship --harness claude --model demo/model-a --holder-pid $LAST_HOLDER   (FM_HOME=android, the local secondmate)"
seat "$M" reserve a1 --generation g-a1 --kind ship --harness claude --model demo/model-a --holder-pid "$LAST_HOLDER"; echo "exit=$?"
echo
echo "\$ fm-fleet-seats.sh release r1 --generation g-r1 --reason prelaunch   (FM_HOME=primary)"
seat "$P" release r1 --generation g-r1 --reason prelaunch; echo "exit=$?"
echo "\$ fm-fleet-seats.sh reserve a1 ... (retry from android)"
seat "$M" reserve a1 --generation g-a1 --kind ship --harness claude --model demo/model-a --holder-pid "$LAST_HOLDER"; echo "exit=$?"
echo
echo "\$ fm-fleet-seats.sh show legacy-agent   (FM_HOME=primary, read-only)"
seat "$P" show legacy-agent; echo "exit=$?"

echo
echo "########## Scenario 2 (adversarial): six simultaneous launches from two homes never overbook a capacity-two pool"
P2="$WORK/s2/primary"; M2="$WORK/s2/android"
make_home "$P2"; pools "$P2" 2
make_home "$M2"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$P2" > "$M2/.fm-secondmate-parent"
printf 'android\n' > "$M2/.fm-secondmate-home"
printf -- '- android - Test mate. (home: %s; scope: tests; projects: ; added 2026-09-28)\n' "$M2" >> "$P2/data/secondmates.md"
mkdir -p "$WORK/s2/out"
holder; HP=$LAST_HOLDER
i=0; CONTENDERS=
for home in "$P2" "$M2" "$P2" "$M2" "$P2" "$M2"; do
  i=$((i + 1))
  ( seat "$home" reserve "c$i" --generation "g-c$i" --kind ship --harness claude --model demo/model-a --holder-pid "$HP" >"$WORK/s2/out/$i.out" 2>&1; echo $? >"$WORK/s2/out/$i.rc" ) &
  HOLDER_PIDS="$HOLDER_PIDS $!"
  CONTENDERS="$CONTENDERS $!"
done
for p in $CONTENDERS; do wait "$p"; done
granted=0; refused=0
for n in 1 2 3 4 5 6; do
  rc=$(cat "$WORK/s2/out/$n.rc")
  printf 'contender c%s (home=%s): exit=%s  %s\n' "$n" "$([ "$n" -eq 1 ] || [ "$n" -eq 3 ] || [ "$n" -eq 5 ] && echo primary || echo android)" "$rc" "$(cat "$WORK/s2/out/$n.out")"
  [ "$rc" -ne 0 ] || granted=$((granted + 1))
  [ "$rc" -ne 4 ] || refused=$((refused + 1))
done
echo "granted=$granted refused_full=$refused"

echo
echo "########## Scenario 3: real fm-spawn.sh refuses a pooled launch into a full pool and publishes no record"
P3="$WORK/s3/home"; PROJ="$WORK/s3/proj"
"$ROOT/bin/fm-lab-home.sh" create "$P3" >/dev/null || { echo "could not mint the marked lab home"; exit 1; }
mkdir -p "$P3/data/spawn-live-t1" "$P3/user-home"
pools "$P3" 1
printf 'kind=ship\nmodel=demo/model-a\nharness=claude\n' > "$P3/state/busy.meta"
mkdir -p "$PROJ" && git -C "$PROJ" init -q -b main && git -C "$PROJ" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cat > "$P3/data/spawn-live-t1/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise the fleet seat refusal.
EOF
echo "\$ fm-spawn.sh spawn-live-t1 <project> --mode local-only --yolo off --harness claude --model demo/model-a"
env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
  FM_HOME="$P3" HOME="$P3/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" spawn-live-t1 "$PROJ" --mode local-only --yolo off --harness claude --model demo/model-a 2>&1
echo "exit=$?"
echo "task record published: $([ -e "$P3/state/spawn-live-t1.meta" ] && echo yes || echo no)"

echo
echo "########## Scenario 4: a replacement launch names the generation the host actually records after a cancelled-before-startup launch"
P4="$WORK/s4/home"; H=$P4; RT=/srv/fm
make_home "$P4"; pools "$P4" 2
printf -- '- ios - iOS delivery (host: shop-host; root: %s; home: %s; scope: iOS; projects: alpha; added 2026-08-01)\n' "$RT" "$H" > "$P4/data/secondmates.md"
printf 'remote_host=shop-host\nremote_root=%s\nhome=%s\nmodel=demo/model-a\n' "$RT" "$H" > "$P4/state/ios.meta"
# The remote has already confirmed the current declaration: the certificate the
# root's own serve pass would publish for an empty holder set.
mkdir -p "$P4/state/fleet-seats"
digest=$(jq -cS . "$P4/config/fleet-seats" | cksum | tr -s ' ' '-' | cut -d- -f1-2)
printf '{"schema":"fm-fleet-seats-serve.v2","policy_digest":"%s","epoch":"live.1","complete":true,"holders":[]}\n' "$digest" > "$P4/state/fleet-seats/remote-ios.cert"
seat "$P4" reserve ios --generation A --kind secondmate --harness claude --model demo/model-a --holder-pid "$$" >/dev/null || echo "reserve A failed"
# The host confirmed A and published its route target.
printf '{"placement":"remote","backend":"herdr","target":"shop:p1","home":"%s","host":"shop-host","remote_root":"%s","spawn_gen":"A","operation":"A"}\n' "$H" "$RT" > "$P4/state/route-a"
chmod 600 "$P4/state/route-a"
seat "$P4" dispatch ios --generation A --route-file "$P4/state/route-a" >/dev/null || echo "dispatch A failed"
jq -n --arg h "$H" --arg rt "$RT" '{schema:"fm-remote-seat-operation.v2",task:"ios",operation:"A",requested_generation:"A",actual_generation:"A",previous_generation:null,disposition:"started",startup_confirmed:true,old_stopped:false,route:{placement:"remote",backend:"herdr",target:"shop:p1",home:$h,remote_root:$rt,spawn_gen:"A"},actual_model:"demo/model-a",complete:true}' > "$P4/state/resp-a"
chmod 600 "$P4/state/resp-a"
seat "$P4" reconcile-remote ios --generation A --response-file "$P4/state/resp-a" || echo "reconcile A failed"

# B is a replacement that stopped A, then died before it was ever submitted.
seat "$P4" reserve ios --generation B --previous-generation A --kind secondmate --harness claude --model demo/model-b --holder-pid "$$" >/dev/null || echo "reserve B failed"
printf '{"placement":"remote","backend":"herdr","target":null,"home":"%s","host":"shop-host","remote_root":"%s","spawn_gen":null,"operation":"B"}\n' "$H" "$RT" > "$P4/state/route-b"
chmod 600 "$P4/state/route-b"
seat "$P4" dispatch ios --generation B --route-file "$P4/state/route-b" >/dev/null || echo "dispatch B failed"
jq -n '{schema:"fm-remote-seat-operation.v2",task:"ios",operation:"B",requested_generation:"B",actual_generation:null,previous_generation:"A",disposition:"cancelled",startup_confirmed:false,old_stopped:true,route:null,actual_model:null,complete:true}' > "$P4/state/resp-b"
chmod 600 "$P4/state/resp-b"
echo "\$ fm-fleet-seats.sh reconcile-remote ios --generation B   (host: cancelled, predecessor A stopped, never submitted)"
seat "$P4" reconcile-remote ios --generation B --response-file "$P4/state/resp-b"; echo "exit=$?"
echo "\$ fm-fleet-seats.sh show ios"
seat "$P4" show ios | jq -c '.incarnations[] | {generation, previous_generation, lifecycle, startup_confirmed, target: .route.target, disposition: .disposition.reason}'
echo "\$ fm_remote_launch_predecessor <(fm-fleet-seats.sh show ios) shop-host $RT $H   (real bin/fm-remote-generation-lib.sh)"
# shellcheck source=/dev/null
( . "$ROOT/bin/fm-remote-generation-lib.sh"
  printf 'predecessor=%s\n' "$(fm_remote_launch_predecessor "$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$P4" "$SEATS" show ios)" shop-host "$RT" "$H")" )

# C is the submitted cancellation: it reached the host, so its own bound route
# is what the host records and it must become the predecessor instead.
seat "$P4" reserve ios --generation C --previous-generation A --kind secondmate --harness claude --model demo/model-a --holder-pid "$$" >/dev/null || echo "reserve C failed"
printf '{"placement":"remote","backend":"herdr","target":null,"home":"%s","host":"shop-host","remote_root":"%s","spawn_gen":null,"operation":"C"}\n' "$H" "$RT" > "$P4/state/route-c"
chmod 600 "$P4/state/route-c"
seat "$P4" dispatch ios --generation C --route-file "$P4/state/route-c" >/dev/null || echo "dispatch C failed"
jq -n --arg h "$H" --arg rt "$RT" '{schema:"fm-remote-seat-operation.v2",task:"ios",operation:"C",requested_generation:"C",actual_generation:null,previous_generation:"A",disposition:"cancelled",startup_confirmed:false,old_stopped:true,route:{placement:"remote",backend:"herdr",target:"shop:p1",home:$h,remote_root:$rt,spawn_gen:null},actual_model:null,complete:true}' > "$P4/state/resp-c"
chmod 600 "$P4/state/resp-c"
echo "\$ fm-fleet-seats.sh reconcile-remote ios --generation C   (host: submitted, then cancelled)"
seat "$P4" reconcile-remote ios --generation C --response-file "$P4/state/resp-c"; echo "exit=$?"
( . "$ROOT/bin/fm-remote-generation-lib.sh"
  printf 'predecessor=%s\n' "$(fm_remote_launch_predecessor "$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$P4" "$SEATS" show ios)" shop-host "$RT" "$H")" )
echo
echo "########## Scenario 5: a launch that found a supervisor already running on another model is recognized by the receipt that observed it"
P5="$WORK/s5/home"; H5=$P5; RT5=/srv/fm
make_home "$P5"
printf '{"pools":[{"name":"pool-a","capacity":1,"models":["demo/model-a"]},{"name":"pool-b","capacity":1,"models":["demo/model-b"]}]}\n' > "$P5/config/fleet-seats"
printf -- '- ios - iOS delivery (host: shop-host; root: %s; home: %s; scope: iOS; projects: alpha; added 2026-08-01)\n' "$RT5" "$H5" > "$P5/data/secondmates.md"
printf 'remote_host=shop-host\nremote_root=%s\nhome=%s\nmodel=demo/model-b\n' "$RT5" "$H5" > "$P5/state/ios.meta"
mkdir -p "$P5/state/fleet-seats"
digest=$(jq -cS . "$P5/config/fleet-seats" | cksum | tr -s ' ' '-' | cut -d- -f1-2)
printf '{"schema":"fm-fleet-seats-serve.v2","policy_digest":"%s","epoch":"live.1","complete":true,"holders":[]}\n' "$digest" > "$P5/state/fleet-seats/remote-ios.cert"
echo "\$ fm-fleet-seats.sh reserve ios --generation op5 --model demo/model-b   (the launch asks for model-b)"
seat "$P5" reserve ios --generation op5 --kind secondmate --harness claude --model demo/model-b --holder-pid "$$"; echo "exit=$?"
printf '{"placement":"remote","backend":"herdr","target":null,"home":"%s","host":"shop-host","remote_root":"%s","spawn_gen":null,"operation":"op5"}\n' "$H5" "$RT5" > "$P5/state/route-op5"
chmod 600 "$P5/state/route-op5"
seat "$P5" dispatch ios --generation op5 --route-file "$P5/state/route-op5" >/dev/null || echo "dispatch op5 failed"
jq -n --arg h "$H5" --arg rt "$RT5" '{schema:"fm-remote-seat-operation.v2",task:"ios",operation:"op5",requested_generation:"op5",actual_generation:"host.9",previous_generation:null,disposition:"existing",startup_confirmed:true,old_stopped:false,route:{placement:"remote",backend:"herdr",target:"shop:p1",home:$h,remote_root:$rt,spawn_gen:"host.9"},actual_model:"demo/model-a",complete:true}' > "$P5/state/resp-op5"
chmod 600 "$P5/state/resp-op5"
echo "\$ fm-fleet-seats.sh reconcile-remote ios --generation op5   (host: an already-running supervisor on demo/model-a)"
seat "$P5" reconcile-remote ios --generation op5 --response-file "$P5/state/resp-op5"; echo "exit=$?"
echo "\$ fm-fleet-seats.sh show ios"
seat "$P5" show ios | jq -c '.incarnations[] | {generation, lifecycle, model, requested_model, generation_from_host: .route.spawn_gen, target: .route.target}'
# The launch publishes the identity the host confirmed (bin/fm-spawn.sh).
printf 'remote_host=shop-host\nremote_root=%s\nhome=%s\nmodel=demo/model-a\nremote_spawn_gen=host.9\nfleet_seat_generation=host.9\n' "$RT5" "$H5" > "$P5/state/ios.meta"
echo "\$ cat state/ios.meta   (the parent published the host-confirmed model and generation)"
cat "$P5/state/ios.meta"
holder
echo "\$ fm-fleet-seats.sh reserve other-a --model demo/model-a   (the imported supervisor must hold pool-a)"
seat "$P5" reserve other-a --generation g-oa --kind ship --harness claude --model demo/model-a --holder-pid "$LAST_HOLDER"; echo "exit=$?"
holder
echo "\$ fm-fleet-seats.sh reserve other-b --model demo/model-b   (the model the launch asked for must hold no seat)"
seat "$P5" reserve other-b --generation g-ob --kind ship --harness claude --model demo/model-b --holder-pid "$LAST_HOLDER"; echo "exit=$?"
seat "$P5" release other-b --generation g-ob --reason prelaunch >/dev/null
echo
echo "########## Scenario 6: a supervisor already running on a remote host before pools existed is counted exactly once"
P6="$WORK/s6/primary"; REM="$WORK/s6/theshop"; RT6="$ROOT"
make_home "$P6"; make_home "$REM"
printf '{"pools":[{"name":"shared","capacity":2,"models":["demo/model-a"]}]}\n' > "$P6/config/fleet-seats"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=shop-host\n' > "$REM/.fm-secondmate-parent"
printf 'theshop\n' > "$REM/.fm-secondmate-home"
printf -- '- theshop - Test remote mate. (host: shop-host; root: %s; home: %s; scope: shop work; projects: ; added 2026-09-28)\n' "$RT6" "$REM" >> "$P6/data/secondmates.md"
mkdir -p "$REM/state/parent-route"
# The supervisor that was already running when the pool was declared: the host
# reports it in the serve certificate, and the primary also keeps its own route
# record for the same mate (written before generations were recorded).
mkdir -p "$P6/state/fleet-seats"
digest=$(jq -cS . "$P6/config/fleet-seats" | cksum | tr -s ' ' '-' | cut -d- -f1-2)
jq -n --arg d "$digest" --arg st "$REM/state/parent-route" \
  '{schema:"fm-fleet-seats-serve.v2",policy_digest:$d,epoch:"live.1",complete:true,
    holders:[{state_dir:$st,task:"theshop",generation:"host.1",model:"demo/model-a"}]}' \
  > "$P6/state/fleet-seats/remote-theshop.cert"
printf 'kind=secondmate\nmodel=demo/model-a\nharness=claude\nremote_host=shop-host\nremote_root=%s\nhome=%s\n' "$RT6" "$REM" > "$P6/state/theshop.meta"
holder
echo "\$ fm-fleet-seats.sh reserve spare --model demo/model-a   (capacity 2; the adopted supervisor must spend exactly one seat)"
seat "$P6" reserve spare --generation g-spare --kind ship --harness claude --model demo/model-a --holder-pid "$LAST_HOLDER"; echo "exit=$?"
holder
echo "\$ fm-fleet-seats.sh reserve over --model demo/model-a   (the third seat must be refused)"
seat "$P6" reserve over --generation g-over --kind ship --harness claude --model demo/model-a --holder-pid "$LAST_HOLDER"; echo "exit=$?"
echo "DONE"
