#!/usr/bin/env bash
# Live drive for fix/pr-lib-preserve-authenticated-poll at head 74f04382.
#
# Real product surface driven end to end:
#   bin/fm-lab-home.sh   - mints the throwaway lab home
#   bin/fm-pr-check.sh   - the public arming entrypoint (registration published)
#   bin/fm-watch.sh      - the supervision watcher (validation + dispatch)
# Forge reads go to the real `gh` CLI against a public merged PR
# (https://github.com/cli/cli/pull/1): one read-only network read, no credential
# mutation and no forge write. The only fixture is the *release copy* of the
# repository, which is how a real "pulled a new release" update looks: the armed
# poll was published by an older repository copy and the watcher now runs newer
# bytes.
set -u
WT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M6C487E2ZHH2DPEFHP1KQFNS
BASE=41a47c095d0d126349ab392158a365c117a2c9d2
PR=https://github.com/cli/cli/pull/1
FIX=$(mktemp -d /tmp/fm-live-drive.XXXXXX)
fails=0
cleanup() { rm -rf "$FIX"; }
trap cleanup EXIT

# The fleet-path overrides and the gate marker stay out of the fixture primary's
# environment so every path resolves inside the disposable lab.
FLEET_ENV=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE
  -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE)

ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
step() { printf '\n### %s\n' "$*"; }

# make_release <dir> <label|stub>
# A full copy of this worktree = one repository generation. The poll body is
# stamped with the generation label (an added side effect only: identical
# provider logic and identical merged/no-output behaviour) so a run can prove
# which generation's poll actually executed.
make_release() {
  local d=$1 variant=$2
  mkdir -p "$d"
  tar -C "$WT" --exclude=./.git --exclude=./tests --exclude=./state -cf - . | tar -C "$d" -xf -
  if [ "$variant" = stub ]; then
    cat > "$d/bin/fm-pr-poll.sh" <<EOF
#!/usr/bin/env bash
# Historical registered generation. The watcher must never execute these bytes.
printf 'historical-generation\n'
printf 'historical-poll-executed\n' >> '$FIX/historical-ran.log'
EOF
  else
    python3 - "$d/bin/fm-pr-poll.sh" "$variant" <<'PY'
import sys
p, label = sys.argv[1], sys.argv[2]
src = open(p).read()
marker = "export LC_ALL\n"
assert marker in src, "poll shape changed"
inject = marker + ("if [ -n \"${FM_LIVE_PROBE:-}\" ]; then printf '%s\\n' '" + label + "' >> \"$FM_LIVE_PROBE\"; fi\n")
open(p, "w").write(src.replace(marker, inject, 1))
PY
  fi
  chmod +x "$d/bin/fm-pr-poll.sh"
}

new_lab() {  # <name> -> lab home path
  local lab="$FIX/$1"
  "$WT/bin/fm-lab-home.sh" create "$lab" >/dev/null || { bad "lab create $1"; return 1; }
  printf '%s' "$lab"
}

write_meta() {  # <lab>
  local lab=$1
  printf 'window=firstmate:fm-task-a\nendpoint_task_id=task-a\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\n' \
    "$FIX/wt" "$FIX/project" > "$lab/state/task-a.meta"
  chmod 600 "$lab/state/task-a.meta"
}

arm_poll() {  # <release> <lab>
  "${FLEET_ENV[@]}" FM_HOME="$2" FM_ROOT_OVERRIDE="$1" \
    "$1/bin/fm-pr-check.sh" task-a "$PR" >"$FIX/arm.log" 2>&1
}

watch() {  # <release-to-run> <lab> <probe|-> <out-prefix>
  local rel=$1 lab=$2 probe=$3 out=$4
  local probe_env=()
  [ "$probe" = - ] || probe_env=("FM_LIVE_PROBE=$probe")
  # Fixture isolation: arming bootstraps the lab home's unrelated contributions
  # custom check. Drop it so the cycle under test is decided only by the armed
  # PR poll.
  rm -f "$lab/state/contributions.check.sh" "$lab/state/contributions.check-trust"
  "${FLEET_ENV[@]}" FM_HOME="$lab" FM_ROOT_OVERRIDE="$rel" FM_CHECK_INTERVAL=0 \
    FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 "${probe_env[@]}" \
    timeout 120 "$rel/bin/fm-watch.sh" > "$out.out" 2> "$out.err"
}

poll_retired() {  # <lab>
  local lab=$1 s
  for s in check.sh pr-poll pr-poll-registration; do
    [ ! -e "$lab/state/task-a.$s" ] || { bad "poll artifact task-a.$s still present"; return 1; }
  done
  return 0
}

mkdir -p "$FIX/wt" "$FIX/project"
git -C "$FIX/wt" init -q
git -C "$FIX/wt" -c user.email=fmtest@example.invalid -c user.name=fmtest commit -q --allow-empty -m init

step "Building disposable repository generations (old / new / historical-stub)"
make_release "$FIX/rel-old" old-generation || exit 1
make_release "$FIX/rel-new" new-generation || exit 1
make_release "$FIX/rel-old-stub" stub || exit 1
cmp -s "$FIX/rel-old/bin/fm-pr-poll.sh" "$FIX/rel-new/bin/fm-pr-poll.sh" \
  && bad "old and new poll bodies are identical" \
  || ok "the repository update changes bin/fm-pr-poll.sh bytes (old != new)"
echo "old poll sha256:     $(shasum -a 256 "$FIX/rel-old/bin/fm-pr-poll.sh" | awk '{print $1}')"
echo "new poll sha256:     $(shasum -a 256 "$FIX/rel-new/bin/fm-pr-poll.sh" | awk '{print $1}')"
echo "worktree poll sha256: $(shasum -a 256 "$WT/bin/fm-pr-poll.sh" | awk '{print $1}')"

# ------------------------------------------------------------------ scenario 1
step "S1  An armed merge poll survives a repository poll update and still reports the merge"
lab=$(new_lab s1); write_meta "$lab"
arm_poll "$FIX/rel-old" "$lab" || bad "S1 arming failed: $(cat "$FIX/arm.log")"
echo "armed: $(grep '^armed:' "$FIX/arm.log" || true)"
cmp -s "$FIX/rel-old/bin/fm-pr-poll.sh" "$lab/state/task-a.check.sh" \
  && ok "S1 registered check is the previous release's poll generation" \
  || bad "S1 registered check is not the previous generation"
cmp -s "$WT/bin/fm-pr-poll.sh" "$lab/state/task-a.check.sh" \
  && bad "S1 fixture did not emulate a repository update" \
  || ok "S1 repository update: the armed check no longer equals the shipped bin/fm-pr-poll.sh"
echo "--- registered generation (task-a.pr-poll-registration)"
cat "$lab/state/task-a.pr-poll-registration"
rm -f "$FIX/probe-s1.log"
watch "$FIX/rel-new" "$lab" "$FIX/probe-s1.log" "$FIX/watch-s1"; rc=$?
echo "--- watcher rc=$rc"
echo "--- watcher stdout"; cat "$FIX/watch-s1.out"
[ "$rc" -eq 0 ] || bad "S1 watcher rc=$rc: $(cat "$FIX/watch-s1.err")"
grep -F 'task-a.check.sh: merged' "$FIX/watch-s1.out" >/dev/null \
  && ok "S1 the watcher reported the merge after the update" \
  || bad "S1 no merged line: $(cat "$FIX/watch-s1.out")"
[ "$(cat "$FIX/probe-s1.log" 2>/dev/null)" = new-generation ] \
  && ok "S1 the updated repository poll executed (probe: new-generation)" \
  || bad "S1 the updated repository poll did not execute; probe=$(cat "$FIX/probe-s1.log" 2>/dev/null)"
grep -F 'merge landed: task-a' "$lab/state/.wake-queue" >/dev/null \
  && ok "S1 merge notification queued: $(cat "$lab/state/.wake-queue")" \
  || bad "S1 no merge wake queued"
poll_retired "$lab" && ok "S1 the merged poll retired its artifacts"
grep -qxF "pr=$PR" "$lab/state/task-a.meta" && ok "S1 task PR identity preserved"

# ---------------------------------------------------------------- scenario 1b
step "S1b The shipped worktree bytes (no fixture stamp) also report the merge for a preserved poll"
lab=$(new_lab s1b); write_meta "$lab"
arm_poll "$FIX/rel-old" "$lab" || bad "S1b arming failed: $(cat "$FIX/arm.log")"
rm -f "$FIX/probe-s1b.log"
watch "$WT" "$lab" "$FIX/probe-s1b.log" "$FIX/watch-s1b"; rc=$?
echo "--- watcher rc=$rc"; echo "--- watcher stdout"; cat "$FIX/watch-s1b.out"
[ "$rc" -eq 0 ] || bad "S1b watcher rc=$rc: $(cat "$FIX/watch-s1b.err")"
grep -F 'task-a.check.sh: merged' "$FIX/watch-s1b.out" >/dev/null \
  && ok "S1b the real bin/fm-watch.sh + bin/fm-pr-poll.sh reported the merge" \
  || bad "S1b no merged line: $(cat "$FIX/watch-s1b.out")"
[ ! -e "$FIX/probe-s1b.log" ] \
  && ok "S1b the registered (older) generation never executed" \
  || bad "S1b the registered generation executed: $(cat "$FIX/probe-s1b.log")"
grep -F 'merge landed: task-a' "$lab/state/.wake-queue" >/dev/null \
  && ok "S1b merge notification queued" || bad "S1b no merge wake queued"

# ------------------------------------------------------------------ scenario 2
step "S2  Registered state-file poll bytes are never executed; the current repository poll is dispatched"
lab=$(new_lab s2); write_meta "$lab"
arm_poll "$FIX/rel-old-stub" "$lab" || bad "S2 arming failed: $(cat "$FIX/arm.log")"
cmp -s "$FIX/rel-old-stub/bin/fm-pr-poll.sh" "$lab/state/task-a.check.sh" \
  && ok "S2 registered generation is the historical stub" \
  || bad "S2 registered check is not the stub"
rm -f "$FIX/probe-s2.log" "$FIX/historical-ran.log"
watch "$FIX/rel-new" "$lab" "$FIX/probe-s2.log" "$FIX/watch-s2"; rc=$?
echo "--- watcher rc=$rc"; echo "--- watcher stdout"; cat "$FIX/watch-s2.out"
[ "$rc" -eq 0 ] || bad "S2 watcher rc=$rc: $(cat "$FIX/watch-s2.err")"
grep -F 'task-a.check.sh: merged' "$FIX/watch-s2.out" >/dev/null \
  && ok "S2 the merge came from the current repository poll" \
  || bad "S2 no merged line: $(cat "$FIX/watch-s2.out")"
[ ! -e "$FIX/historical-ran.log" ] \
  && ok "S2 the registered stub body never ran (no marker file)" \
  || bad "S2 the registered stub executed: $(cat "$FIX/historical-ran.log")"
[ "$(cat "$FIX/probe-s2.log" 2>/dev/null)" = new-generation ] \
  && ok "S2 the updated repository poll executed" || bad "S2 updated poll did not execute"
grep -F 'merge landed: task-a' "$lab/state/.wake-queue" >/dev/null \
  && ok "S2 merge notification queued" || bad "S2 no merge wake queued"

# ------------------------------------------------------------------ scenario 3
step "S3  A control relaunch appending control_relaunch_tx after the PR identity keeps the poll armed"
lab=$(new_lab s3); write_meta "$lab"
arm_poll "$FIX/rel-new" "$lab" || bad "S3 arming failed: $(cat "$FIX/arm.log")"
printf 'control_relaunch_tx=114614.20261024T230110Z.26328\n' >> "$lab/state/task-a.meta"
echo "--- metadata region after arming + relaunch"
grep -nE '^(pr|pr_head|control_relaunch_tx)=' "$lab/state/task-a.meta"
awk '/^pr=/{seen=1} /^control_relaunch_tx=/{if (seen) found=1} END{exit !found}' "$lab/state/task-a.meta" \
  && ok "S3 control_relaunch_tx is recorded after the PR identity, as the relaunch appends it" \
  || bad "S3 fixture did not place control_relaunch_tx after pr="
rm -f "$FIX/probe-s3.log"
watch "$FIX/rel-new" "$lab" "$FIX/probe-s3.log" "$FIX/watch-s3"; rc=$?
echo "--- watcher rc=$rc"; echo "--- watcher stdout"; cat "$FIX/watch-s3.out"
[ "$rc" -eq 0 ] || bad "S3 watcher rc=$rc: $(cat "$FIX/watch-s3.err")"
grep -F 'task-a.check.sh: merged' "$FIX/watch-s3.out" >/dev/null \
  && ok "S3 the merge was still reported after the relaunch metadata" \
  || bad "S3 lost the merge: $(cat "$FIX/watch-s3.out")"
! grep -F 'rejected unauthenticated state checks' "$FIX/watch-s3.out" >/dev/null \
  && ok "S3 the armed poll was not revoked by the relaunch metadata" \
  || bad "S3 relaunch metadata revoked the armed poll"
grep -F 'merge landed: task-a' "$lab/state/.wake-queue" >/dev/null \
  && ok "S3 merge notification queued" || bad "S3 no merge wake queued"
poll_retired "$lab" && ok "S3 the merged poll retired its artifacts"

# ------------------------------------------------------------------ scenario 4
step "S4  Adversarial: tampered check bytes are still refused after a repository update"
lab=$(new_lab s4); write_meta "$lab"
arm_poll "$FIX/rel-old" "$lab" || bad "S4 arming failed: $(cat "$FIX/arm.log")"
reg_before=$(shasum -a 256 "$lab/state/task-a.pr-poll-registration" | awk '{print $1}')
printf '# forged after registration\n' >> "$lab/state/task-a.check.sh"
rm -f "$FIX/probe-s4.log"
watch "$FIX/rel-new" "$lab" "$FIX/probe-s4.log" "$FIX/watch-s4"; rc=$?
echo "--- watcher rc=$rc"; echo "--- watcher stdout"; cat "$FIX/watch-s4.out"
[ "$rc" -eq 0 ] || bad "S4 watcher rc=$rc: $(cat "$FIX/watch-s4.err")"
! grep -F 'task-a.check.sh: merged' "$FIX/watch-s4.out" >/dev/null \
  && ok "S4 the tampered generation was not reported as merged" \
  || bad "S4 the tampered generation was reported as merged"
grep -F 'rejected unauthenticated state checks' "$FIX/watch-s4.out" >/dev/null \
  && ok "S4 the watcher refused the tampered check" \
  || bad "S4 no refusal line: $(cat "$FIX/watch-s4.out")"
[ ! -s "$FIX/probe-s4.log" ] \
  && ok "S4 no poll ran for the tampered generation" || bad "S4 a poll ran: $(cat "$FIX/probe-s4.log")"
[ "$(shasum -a 256 "$lab/state/task-a.pr-poll-registration" | awk '{print $1}')" = "$reg_before" ] \
  && ok "S4 the refusal did not rewrite trust for the tampered bytes" \
  || bad "S4 the registration was rewritten"
[ ! -e "$lab/state/task-a.pr-poll-merge-notified" ] \
  && ok "S4 no merge notification recorded" || bad "S4 recorded a merge notification"

# ------------------------------------------------------------------ scenario 5
step "S5  Adversarial: forged metadata trailing the relaunch marker is still refused"
for variant in injected-field duplicate-pr; do
  lab=$(new_lab "s5-$variant"); write_meta "$lab"
  arm_poll "$FIX/rel-new" "$lab" || bad "S5/$variant arming failed: $(cat "$FIX/arm.log")"
  printf 'control_relaunch_tx=114614.20261024T230110Z.26328\n' >> "$lab/state/task-a.meta"
  case "$variant" in
    injected-field) printf 'injected=value\n' >> "$lab/state/task-a.meta" ;;
    duplicate-pr)   printf "pr=https://github.com/cli/cli/pull/2\n" >> "$lab/state/task-a.meta" ;;
  esac
  rm -f "$FIX/probe-s5-$variant.log"
  watch "$FIX/rel-new" "$lab" "$FIX/probe-s5-$variant.log" "$FIX/watch-s5-$variant"; rc=$?
  echo "--- $variant watcher rc=$rc"; echo "--- $variant watcher stdout"; cat "$FIX/watch-s5-$variant.out"
  [ "$rc" -eq 0 ] || bad "S5/$variant watcher rc=$rc: $(cat "$FIX/watch-s5-$variant.err")"
  ! grep -F 'task-a.check.sh: merged' "$FIX/watch-s5-$variant.out" >/dev/null \
    && ok "S5/$variant forged metadata was not reported as merged" \
    || bad "S5/$variant forged metadata reported merged"
  grep -F 'rejected unauthenticated state checks' "$FIX/watch-s5-$variant.out" >/dev/null \
    && ok "S5/$variant the watcher refused the record" \
    || bad "S5/$variant no refusal line"
  [ ! -s "$FIX/probe-s5-$variant.log" ] \
    && ok "S5/$variant no poll ran" || bad "S5/$variant a poll ran"
  [ ! -e "$lab/state/task-a.pr-poll-merge-notified" ] \
    && ok "S5/$variant no merge notification recorded" || bad "S5/$variant recorded a merge notification"
done

# ------------------------------------------------------------------ scenario 6
step "S6  Adversarial: a byte-identical replacement of the registered check is refused by file identity"
lab=$(new_lab s6); write_meta "$lab"
arm_poll "$FIX/rel-new" "$lab" || bad "S6 arming failed: $(cat "$FIX/arm.log")"
cp "$lab/state/task-a.check.sh" "$FIX/check-copy.sh"
mv -f "$FIX/check-copy.sh" "$lab/state/task-a.check.sh"
rm -f "$FIX/probe-s6.log"
watch "$FIX/rel-new" "$lab" "$FIX/probe-s6.log" "$FIX/watch-s6"; rc=$?
echo "--- watcher rc=$rc"; echo "--- watcher stdout"; cat "$FIX/watch-s6.out"
[ "$rc" -eq 0 ] || bad "S6 watcher rc=$rc: $(cat "$FIX/watch-s6.err")"
! grep -F 'task-a.check.sh: merged' "$FIX/watch-s6.out" >/dev/null \
  && ok "S6 the same-bytes new-inode check was not reported as merged" \
  || bad "S6 the replaced file object was accepted"
grep -F 'rejected unauthenticated state checks' "$FIX/watch-s6.out" >/dev/null \
  && ok "S6 the watcher refused the replaced file object" || bad "S6 no refusal line"
[ ! -s "$FIX/probe-s6.log" ] && ok "S6 no poll ran" || bad "S6 a poll ran"

# ------------------------------------------------- pre-fix control (discrimination)
step "CONTROL  The base commit's fm-pr-lib.sh refuses the same preserved generation"
mkdir -p "$FIX/rel-prefix"
tar -C "$FIX/rel-new" -cf - . | tar -C "$FIX/rel-prefix" -xf -
git -C "$WT" show "$BASE:bin/fm-pr-lib.sh" > "$FIX/rel-prefix/bin/fm-pr-lib.sh"
chmod +x "$FIX/rel-prefix/bin/fm-pr-lib.sh"
echo "base fm-pr-lib.sh sha256: $(shasum -a 256 "$FIX/rel-prefix/bin/fm-pr-lib.sh" | awk '{print $1}')"
for variant in template-update relaunch-only; do
  lab=$(new_lab "control-$variant"); write_meta "$lab"
  if [ "$variant" = template-update ]; then
    arm_poll "$FIX/rel-old" "$lab" || bad "CONTROL/$variant arming failed: $(cat "$FIX/arm.log")"
  else
    arm_poll "$FIX/rel-new" "$lab" || bad "CONTROL/$variant arming failed: $(cat "$FIX/arm.log")"
    printf 'control_relaunch_tx=114614.20261024T230110Z.26328\n' >> "$lab/state/task-a.meta"
  fi
  rm -f "$FIX/probe-control-$variant.log"
  watch "$FIX/rel-prefix" "$lab" "$FIX/probe-control-$variant.log" "$FIX/watch-control-$variant"; rc=$?
  echo "--- $variant watcher rc=$rc"; echo "--- $variant watcher stdout"; cat "$FIX/watch-control-$variant.out"
  [ "$rc" -eq 0 ] || bad "CONTROL/$variant watcher rc=$rc: $(cat "$FIX/watch-control-$variant.err")"
  ! grep -F 'task-a.check.sh: merged' "$FIX/watch-control-$variant.out" >/dev/null \
    && ok "CONTROL/$variant base library loses the merge (fixture discriminates the fix)" \
    || bad "CONTROL/$variant base library still reported the merge"
  grep -F 'rejected unauthenticated state checks' "$FIX/watch-control-$variant.out" >/dev/null \
    && ok "CONTROL/$variant base library rejected the intact poll" \
    || bad "CONTROL/$variant no refusal line"
done

printf '\n==== live drive result: %s (%d failures) ====\n' "$([ "$fails" -eq 0 ] && echo PASS || echo FAIL)" "$fails"
exit "$fails"
