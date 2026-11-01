#!/usr/bin/env bash
# Live drive for the "armed merge poll survives repo update + control relaunch"
# change. Real product: bin/fm-lab-home.sh, bin/fm-pr-check.sh (arming),
# bin/fm-watch.sh (validation + dispatch), real gh against a real merged PR.
set -u
WT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M6C487E2ZHH2DPEFHP1KQFNS
FIX=$(mktemp -d /tmp/fm-live-drive.XXXXXX)
PR=https://github.com/cli/cli/pull/1
fails=0
cleanup() { rm -rf "$FIX"; }
trap cleanup EXIT

ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fails=$((fails+1)); }
step() { printf '\n### %s\n' "$*"; }

make_release() {  # <dir> <probe-label|stub>
  local d=$1 variant=$2
  mkdir -p "$d"
  tar -C "$WT" --exclude=./.git --exclude=./tests --exclude=./state -cf - . | tar -C "$d" -xf -
  if [ "$variant" = stub ]; then
    cat > "$d/bin/fm-pr-poll.sh" <<EOF
#!/usr/bin/env bash
# Historical registered generation; the watcher must never execute these bytes.
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

new_lab() {  # <name> -> path
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
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS FM_HOME="$2" FM_ROOT_OVERRIDE="$1" \
    "$1/bin/fm-pr-check.sh" task-a "$PR" >"$FIX/arm.log" 2>&1
}

watch() {  # <release> <lab> <probe> <out-prefix>
  local rel=$1 lab=$2 probe=$3 out=$4
  # Fixture isolation: the lab home's unrelated contributions custom check is
  # bootstrapped by the guard banner at arm time. Drop it so the cycle under
  # test is decided only by the armed PR poll.
  rm -f "$lab/state/contributions.check.sh" "$lab/state/contributions.check-trust"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
    FM_HOME="$lab" FM_ROOT_OVERRIDE="$rel" FM_CHECK_INTERVAL=0 FM_POLL=0.02 \
    FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 FM_LIVE_PROBE="$probe" \
    timeout 120 "$rel/bin/fm-watch.sh" > "$out.out" 2> "$out.err"
}

mkdir -p "$FIX/wt" "$FIX/project"
git -C "$FIX/wt" init -q && git -C "$FIX/wt" commit -q --allow-empty -m init

step "Building disposable release copies (old poll / updated poll / historical stub)"
make_release "$FIX/rel-old" old-generation || exit 1
make_release "$FIX/rel-new" new-generation || exit 1
make_release "$FIX/rel-old-stub" stub || exit 1
grep -h FM_LIVE_PROBE "$FIX/rel-old/bin/fm-pr-poll.sh" "$FIX/rel-new/bin/fm-pr-poll.sh"
cmp -s "$FIX/rel-old/bin/fm-pr-poll.sh" "$FIX/rel-new/bin/fm-pr-poll.sh" && bad "releases identical" || ok "rel-old and rel-new poll bytes differ (repository update)"

poll_retired() {  # <lab>
  local lab=$1 s
  for s in check.sh pr-poll pr-poll-registration; do
    [ ! -e "$lab/state/task-a.$s" ] || { bad "poll artifact task-a.$s still present"; return 1; }
  done
  return 0
}

# ---------------------------------------------------------------- scenario 1
step "S1 template-update: armed poll survives a repository update and the merge is reported"
lab=$(new_lab s1); write_meta "$lab"
arm_poll "$FIX/rel-old" "$lab" || bad "S1 arming failed: $(cat "$FIX/arm.log")"
cmp -s "$FIX/rel-old/bin/fm-pr-poll.sh" "$lab/state/task-a.check.sh" && ok "registered generation is the old poll" || bad "registered check is not the old poll"
rm -f "$FIX/probe-s1.log"
watch "$FIX/rel-new" "$lab" "$FIX/probe-s1.log" "$FIX/watch-s1"; rc=$?
[ "$rc" -eq 0 ] || bad "S1 watcher rc=$rc: $(cat "$FIX/watch-s1.err")"
grep -F 'task-a.check.sh: merged' "$FIX/watch-s1.out" >/dev/null && ok "S1 watcher reported the merge: $(cat "$FIX/watch-s1.out")" || bad "S1 no merged line: $(cat "$FIX/watch-s1.out")"
[ "$(cat "$FIX/probe-s1.log" 2>/dev/null)" = new-generation ] && ok "S1 the updated repository poll ran (probe: $(cat "$FIX/probe-s1.log"))" || bad "S1 updated poll did not run; probe=$(cat "$FIX/probe-s1.log" 2>/dev/null)"
poll_retired "$lab" && ok "S1 validated poll retired after the merge"
grep -F 'merge landed: task-a' "$lab/state/.wake-queue" >/dev/null && ok "S1 merge notification queued: $(cat "$lab/state/.wake-queue")" || bad "S1 no merge wake queued"

# ---------------------------------------------------------------- scenario 2
step "S2 adversarial: the registered state-file poll bytes are never executed"
lab=$(new_lab s2); write_meta "$lab"
arm_poll "$FIX/rel-old-stub" "$lab" || bad "S2 arming failed: $(cat "$FIX/arm.log")"
cmp -s "$FIX/rel-old-stub/bin/fm-pr-poll.sh" "$lab/state/task-a.check.sh" && ok "registered generation is the historical stub" || bad "registered check is not the stub"
rm -f "$FIX/probe-s2.log" "$FIX/historical-ran.log"
watch "$FIX/rel-new" "$lab" "$FIX/probe-s2.log" "$FIX/watch-s2"; rc=$?
[ "$rc" -eq 0 ] || bad "S2 watcher rc=$rc: $(cat "$FIX/watch-s2.err")"
grep -F 'task-a.check.sh: merged' "$FIX/watch-s2.out" >/dev/null && ok "S2 merge reported from the current repository poll" || bad "S2 no merged line: $(cat "$FIX/watch-s2.out")"
[ ! -e "$FIX/historical-ran.log" ] && ok "S2 registered stub bytes never executed (no marker file)" || bad "S2 registered stub executed: $(cat "$FIX/historical-ran.log")"
[ "$(cat "$FIX/probe-s2.log" 2>/dev/null)" = new-generation ] && ok "S2 updated repository poll ran" || bad "S2 updated poll did not run"
grep -F 'merge landed: task-a' "$lab/state/.wake-queue" >/dev/null && ok "S2 merge notification queued" || bad "S2 no merge wake queued"

# ---------------------------------------------------------------- scenario 3
step "S3 control relaunch: control_relaunch_tx metadata leaves the armed poll valid"
for variant in after-pr before-pr; do
  lab=$(new_lab "s3-$variant"); write_meta "$lab"
  arm_poll "$FIX/rel-new" "$lab" || bad "S3/$variant arming failed: $(cat "$FIX/arm.log")"
  if [ "$variant" = after-pr ]; then
    # The shape the user intent names: the relaunch transaction line appended
    # after the armed PR identity region.
    printf 'control_relaunch_tx=114614.20261024T230110Z.26328\n' >> "$lab/state/task-a.meta"
  else
    # A relaunched record's own layout: refreshed harness/model/effort, the
    # transaction line, then the preserved PR identity region last.
    awk '!/^pr=|^pr_head=/' "$lab/state/task-a.meta" > "$lab/state/task-a.meta.new"
    printf 'control_relaunch_tx=114614.20261024T230110Z.26328\n' >> "$lab/state/task-a.meta.new"
    grep -E '^(pr|pr_head)=' "$lab/state/task-a.meta" >> "$lab/state/task-a.meta.new"
    chmod 600 "$lab/state/task-a.meta.new"
    mv -f "$lab/state/task-a.meta.new" "$lab/state/task-a.meta"
  fi
  rm -f "$FIX/probe-s3-$variant.log"
  watch "$FIX/rel-new" "$lab" "$FIX/probe-s3-$variant.log" "$FIX/watch-s3-$variant"; rc=$?
  [ "$rc" -eq 0 ] || bad "S3/$variant watcher rc=$rc: $(cat "$FIX/watch-s3-$variant.err")"
  grep -F 'task-a.check.sh: merged' "$FIX/watch-s3-$variant.out" >/dev/null && ok "S3/$variant merge still reported after relaunch metadata" || bad "S3/$variant lost the merge: $(cat "$FIX/watch-s3-$variant.out")"
  grep -qF 'control_relaunch_tx=' "$lab/state/task-a.meta" && ok "S3/$variant metadata still carries control_relaunch_tx"
  poll_retired "$lab" && ok "S3/$variant poll retired after the merge"
  grep -F 'merge landed: task-a' "$lab/state/.wake-queue" >/dev/null && ok "S3/$variant merge notification queued" || bad "S3/$variant no merge wake queued"
done

# ---------------------------------------------------------------- scenario 4
step "S4 adversarial: tampered check bytes are still refused after a repository update"
lab=$(new_lab s4); write_meta "$lab"
arm_poll "$FIX/rel-old" "$lab" || bad "S4 arming failed: $(cat "$FIX/arm.log")"
printf '# forged after registration\n' >> "$lab/state/task-a.check.sh"
rm -f "$FIX/probe-s4.log"
watch "$FIX/rel-new" "$lab" "$FIX/probe-s4.log" "$FIX/watch-s4"; rc=$?
[ "$rc" -eq 0 ] || bad "S4 watcher rc=$rc: $(cat "$FIX/watch-s4.err")"
! grep -F 'task-a.check.sh: merged' "$FIX/watch-s4.out" >/dev/null && ok "S4 tampered check not reported as merged" || bad "S4 tampered check reported merged"
grep -F 'rejected unauthenticated state checks' "$FIX/watch-s4.out" >/dev/null && ok "S4 watcher refused the tampered check: $(cat "$FIX/watch-s4.out")" || bad "S4 no refusal line: $(cat "$FIX/watch-s4.out")"
[ ! -s "$FIX/probe-s4.log" ] && ok "S4 poll never ran on the tampered generation" || bad "S4 poll ran: $(cat "$FIX/probe-s4.log")"
[ -e "$lab/state/task-a.pr-poll-registration" ] && ok "S4 refused generation left its registration unreplaced" || bad "S4 registration disappeared"
[ ! -e "$lab/state/task-a.pr-poll-merge-notified" ] && ok "S4 no merge notification recorded" || bad "S4 recorded a merge notification"

# ---------------------------------------------------------------- scenario 5
step "S5 adversarial: forged metadata trailing the relaunch marker is refused"
for variant in injected-field duplicate-pr; do
  lab=$(new_lab "s5-$variant"); write_meta "$lab"
  arm_poll "$FIX/rel-new" "$lab" || bad "S5/$variant arming failed: $(cat "$FIX/arm.log")"
  printf 'control_relaunch_tx=114614.20261024T230110Z.26328\n' >> "$lab/state/task-a.meta"
  case "$variant" in
    injected-field) printf 'injected=value\n' >> "$lab/state/task-a.meta" ;;
    duplicate-pr)   printf 'pr=https://github.com/cli/cli/pull/2\n' >> "$lab/state/task-a.meta" ;;
  esac
  rm -f "$FIX/probe-s5-$variant.log"
  watch "$FIX/rel-new" "$lab" "$FIX/probe-s5-$variant.log" "$FIX/watch-s5-$variant"; rc=$?
  [ "$rc" -eq 0 ] || bad "S5/$variant watcher rc=$rc: $(cat "$FIX/watch-s5-$variant.err")"
  ! grep -F 'task-a.check.sh: merged' "$FIX/watch-s5-$variant.out" >/dev/null && ok "S5/$variant forged metadata not reported as merged" || bad "S5/$variant forged metadata reported merged"
  grep -F 'rejected unauthenticated state checks' "$FIX/watch-s5-$variant.out" >/dev/null && ok "S5/$variant watcher refused: $(cat "$FIX/watch-s5-$variant.out")" || bad "S5/$variant no refusal line: $(cat "$FIX/watch-s5-$variant.out")"
  [ ! -s "$FIX/probe-s5-$variant.log" ] && ok "S5/$variant poll never ran" || bad "S5/$variant poll ran"
  [ ! -e "$lab/state/task-a.pr-poll-merge-notified" ] && ok "S5/$variant no merge notification recorded" || bad "S5/$variant recorded a merge notification"
done


# ---------------------------------------------------------------- scenario 6
step "S6 adversarial: a byte-identical replacement of the registered check is still refused by file identity"
lab=$(new_lab s6); write_meta "$lab"
arm_poll "$FIX/rel-new" "$lab" || bad "S6 arming failed: $(cat "$FIX/arm.log")"
cp "$lab/state/task-a.check.sh" "$FIX/check-copy.sh"
mv -f "$FIX/check-copy.sh" "$lab/state/task-a.check.sh"   # same bytes, new inode
rm -f "$FIX/probe-s6.log"
watch "$FIX/rel-new" "$lab" "$FIX/probe-s6.log" "$FIX/watch-s6"; rc=$?
[ "$rc" -eq 0 ] || bad "S6 watcher rc=$rc: $(cat "$FIX/watch-s6.err")"
! grep -F 'task-a.check.sh: merged' "$FIX/watch-s6.out" >/dev/null && ok "S6 replaced-inode check not reported as merged" || bad "S6 replaced-inode check reported merged"
grep -F 'rejected unauthenticated state checks' "$FIX/watch-s6.out" >/dev/null && ok "S6 watcher refused the replaced file object" || bad "S6 no refusal line: $(cat "$FIX/watch-s6.out")"
[ ! -s "$FIX/probe-s6.log" ] && ok "S6 poll never ran" || bad "S6 poll ran"

# ------------------------------------------------- pre-fix control (discrimination)
step "CONTROL pre-fix: the same template-update fixture is refused by the base library"
mkdir -p "$FIX/rel-prefix"
tar -C "$FIX/rel-new" -cf - . | tar -C "$FIX/rel-prefix" -xf -
git -C "$WT" show 41a47c095d0d126349ab392158a365c117a2c9d2:bin/fm-pr-lib.sh > "$FIX/rel-prefix/bin/fm-pr-lib.sh"
chmod +x "$FIX/rel-prefix/bin/fm-pr-lib.sh"
lab=$(new_lab prefix); write_meta "$lab"
arm_poll "$FIX/rel-old" "$lab" || bad "CONTROL arming failed: $(cat "$FIX/arm.log")"
rm -f "$FIX/probe-prefix.log"
watch "$FIX/rel-prefix" "$lab" "$FIX/probe-prefix.log" "$FIX/watch-prefix"; rc=$?
[ "$rc" -eq 0 ] || bad "CONTROL watcher rc=$rc: $(cat "$FIX/watch-prefix.err")"
! grep -F 'task-a.check.sh: merged' "$FIX/watch-prefix.out" >/dev/null && ok "CONTROL base library refuses the preserved generation (fixture discriminates the fix)" || bad "CONTROL base library still reported merged"
grep -F 'rejected unauthenticated state checks' "$FIX/watch-prefix.out" >/dev/null && ok "CONTROL base library rejected the poll: $(cat "$FIX/watch-prefix.out")" || bad "CONTROL no refusal line: $(cat "$FIX/watch-prefix.out")"
[ ! -s "$FIX/probe-prefix.log" ] && ok "CONTROL base library never ran the poll" || bad "CONTROL base library ran the poll"

printf '\n==== live drive result: %s (%d failures) ====\n' "$([ "$fails" -eq 0 ] && echo PASS || echo FAIL)" "$fails"
exit "$fails"
