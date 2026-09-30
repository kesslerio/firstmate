#!/usr/bin/env bash
# Scenario 2 driver: full pooled local supervisor lifecycle on a real pi harness.
set -u
E=/Users/kesslerio/.no-mistakes/evidence/01M3RP9FKDWJ4VTFQQY8Q2R70E
. "$E/s2-env.sh"
cd "$E/s2c" || exit 1
T="$E/s2-transcript.log"
export FM_CONTROL_LAUNCH_WAIT=45 FM_CONTROL_EXIT_WAIT=30 FM_CONTROL_POLL=0.25
S=bin/fm-fleet-seats.sh
say() { printf '\n## %s\n' "$*" | tee -a "$T"; }
run() { printf '$ %s\n' "$*" >> "$T"; "$@" >> "$T" 2>&1; local rc=$?; printf 'exit=%s\n' "$rc" >> "$T"; return $rc; }
gens() { "$S" show labmate | jq -c '.incarnations[]|{generation,previous_generation,lifecycle,launch_phase,startup_confirmed,disposition:.disposition.reason}' | tee -a "$T"; }
gen() { sed -n 's/^spawn_gen=//p' "$LAB/state/labmate.meta" | tail -1; }
life() { "$S" show labmate | jq -r --arg g "$1" '.incarnations[]|select(.generation==$g)|.lifecycle'; }
confirmed() { "$S" show labmate | jq -r --arg g "$1" '.incarnations[]|select(.generation==$g)|.startup_confirmed'; }
check() { if eval "$1"; then echo "CHECK ok: $1" | tee -a "$T"; else echo "CHECK FAIL: $1" | tee -a "$T"; FAILS=$((FAILS+1)); fi; }
alive() { tmux -L fm-lab capture-pane -p -t primary:fm-labmate >/dev/null 2>&1; }
FAILS=0
wait_idle() { # a real agent mid-turn cannot be stopped safely; wait until its composer is proven empty
  local i
  for i in $(seq 1 180); do
    [ "$(bash -c '. bin/fm-tmux-lib.sh 2>/dev/null; fm_tmux_composer_state primary:fm-labmate')" = empty ] && { echo "(agent idle after ${i}s)" >> "$T"; return 0; }
    sleep 1
  done
  echo "(agent still not idle after 180s)" >> "$T"
}
persist_corr() { grep -l '^request_summary=Firstmate was updated and I am about to restart' "$LAB"/state/pending-replies/* 2>/dev/null | xargs ls -t 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null; }
M1='john-remote/qwen3.8-flash-next'; M2='john-remote/other-model'

say "S2.1 pooled supervisor spawn confirms its exact generation"
run bin/fm-spawn.sh labmate "$MATE" --secondmate --backend tmux
G1=$(gen); gens
check '[ "$(life $G1)" = confirmed ] && [ "$(confirmed $G1)" = true ]'

say "S2.2 same-pool relaunch: replacement reserved before the stop, predecessor released only as replaced"
wait_idle
run bin/fm-control.sh labmate relaunch
G2=$(gen); gens
check '[ "$G2" != "$G1" ] && [ "$(life $G2)" = confirmed ] && [ "$(life $G1)" = released ]'
check '[ "$("$S" show labmate | jq -r --arg g "$G1" ".incarnations[]|select(.generation==\$g)|.disposition.reason")" = replaced ]'

say "S2.3 rollback before touch: cross-pool relaunch into a full destination pool refuses and keeps G2 running"
wait_idle
run "$S" reserve blocker --generation b1 --kind ship --harness pi --model "$M2" --holder-pid $$
run bin/fm-control.sh labmate relaunch --model "$M2"
cat "$LAB/state/labmate.control-relaunch" >> "$T" 2>/dev/null
gens
check '[ "$(gen)" = "$G2" ] && [ "$(life $G2)" = confirmed ]'
check 'grep -q "rollback=instructions-restored" "$LAB/state/labmate.control-relaunch"'
run "$S" release blocker --generation b1 --reason prelaunch

say "S2.4 stale expected generation refuses with exit 6 and touches nothing"
printf '$ fm-control.sh labmate relaunch --expect-generation %s\n' "$G1" >> "$T"
bin/fm-control.sh labmate relaunch --expect-generation "$G1" >> "$T" 2>&1; rc=$?; echo "exit=$rc" >> "$T"
check '[ "$rc" = 6 ] && [ "$(gen)" = "$G2" ] && [ "$(life $G2)" = confirmed ]'

say "S2.5 persistence gate: no answer within the bound means a nudge, never a restart"
printf '$ FM_SECONDMATE_PERSIST_WAIT=4 fm-secondmate-restart.sh labmate\n' >> "$T"
FM_SECONDMATE_PERSIST_WAIT=4 FM_SECONDMATE_PERSIST_POLL=1 bin/fm-secondmate-restart.sh labmate >> "$T" 2>&1; rc=$?; echo "exit=$rc" >> "$T"
check '[ "$rc" = 3 ] && [ "$(gen)" = "$G2" ] && [ "$(life $G2)" = confirmed ]'
C5=$(persist_corr); echo "unanswered S2.5 correlation: $C5" >> "$T"

answer() { # answer the newest pending persist request exactly as the mate's report helper would
  local corr='' i
  for i in $(seq 1 120); do
    corr=$(persist_corr)
    [ -z "$corr" ] || [ "$corr" = "$1" ] || break
    corr=''; sleep 0.5
  done
  echo "pending correlation: ${corr:-none}" >> "$T"
  [ -n "$corr" ] || { LASTCORR=; return; }
  for i in $(seq 1 90); do
    grep -q '^phase=resolved' "$LAB/state/pending-replies/$corr" 2>/dev/null && { echo "the real pi mate answered $corr itself" >> "$T"; LASTCORR=$corr; return; }
    [ -f "$LAB/state/pending-replies/$corr" ] || { echo "record $corr already consumed" >> "$T"; LASTCORR=$corr; return; }
    sleep 1
  done
  echo "the pi mate did not answer $corr within 90s; answering with the mate-side report helper on its behalf" >> "$T"
  run env FM_HOME="$MATE" bin/fm-secondmate-report.sh done "$corr" "no open work is held in conversation; nothing to record"
  LASTCORR=$corr
}

say "S2.6 persistence gate: the mate's correlated answer authorizes a restart bound to G2"
printf '$ fm-secondmate-restart.sh labmate   (background)\n' >> "$T"
FM_SECONDMATE_PERSIST_WAIT=300 FM_SECONDMATE_PERSIST_POLL=45 bin/fm-secondmate-restart.sh labmate > "$E/s2-restart1.out" 2>&1 &
rp=$!
LASTCORR=; answer "$C5"
wait $rp; rc=$?; cat "$E/s2-restart1.out" >> "$T"; echo "exit=$rc" >> "$T"
G3=$(gen); gens
check '[ "$rc" = 0 ] && [ "$G3" != "$G2" ] && [ "$(life $G3)" = confirmed ] && [ "$(life $G2)" = released ]'

say "S2.7 generation race: a newer incarnation replaces the mate while its persist answer is pending; the late answer nudges instead of stopping it"
printf '$ fm-secondmate-restart.sh labmate   (background)\n' >> "$T"
FM_SECONDMATE_PERSIST_WAIT=400 FM_SECONDMATE_PERSIST_POLL=150 bin/fm-secondmate-restart.sh labmate > "$E/s2-restart2.out" 2>&1 &
rp=$!
prev=$LASTCORR
for i in $(seq 1 60); do c=$(persist_corr); [ -n "$c" ] && [ "$c" != "$prev" ] && break; sleep 0.5; done
answer "$prev"
wait_idle
run bin/fm-control.sh labmate relaunch
G4=$(gen)
check '[ "$G4" != "$G3" ] && [ "$(life $G4)" = confirmed ] && [ "$(life $G3)" = released ]' 
wait $rp; rc=$?; cat "$E/s2-restart2.out" >> "$T"; echo "exit=$rc" >> "$T"
gens
check '[ "$rc" = 3 ] && grep -q "^nudged: labmate" "$E/s2-restart2.out" && [ "$(gen)" = "$G4" ] && [ "$(life $G4)" = confirmed ]'

say "S2.7b a late answer to the timed-out S2.5 request restarts nothing"
run env FM_HOME="$MATE" bin/fm-secondmate-report.sh done "$C5" "late answer"
sleep 2
check '[ "$(gen)" = "$G4" ] && [ "$(life $G4)" = confirmed ]'

say "S2.8 teardown releases exactly its own generation"
for i in $(seq 1 120); do grep -l '^phase=awaiting_report' "$LAB"/state/pending-replies/* >/dev/null 2>&1 || break; sleep 1; done
for f in $(grep -l '^phase=awaiting_report' "$LAB"/state/pending-replies/* 2>/dev/null); do
  echo "unanswered routed request $(basename "$f") after 120s; answering via the mate-side report helper" >> "$T"
  run env FM_HOME="$MATE" bin/fm-secondmate-report.sh done "$(basename "$f")" "acknowledged"
done
run bin/fm-teardown.sh labmate
"$S" show labmate | jq -c '.incarnations[]|{generation,lifecycle,disposition:.disposition.reason}' | tee -a "$T"
check '[ "$("$S" show labmate | jq -r --arg g "$G4" ".incarnations[]|select(.generation==\$g)|.lifecycle")" = released ]'
check '[ "$("$S" show labmate | jq -r --arg g "$G4" ".incarnations[]|select(.generation==\$g)|.disposition.reason")" = teardown ]'
run "$S" reserve fresh --generation f1 --kind ship --harness pi --model "$M1" --holder-pid $$
run "$S" release fresh --generation f1 --reason prelaunch
echo "FAILS=$FAILS" | tee -a "$T"
