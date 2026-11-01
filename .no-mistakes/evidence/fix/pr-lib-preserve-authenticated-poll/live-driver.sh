#!/usr/bin/env bash
# Live validation driver for fix/pr-lib-preserve-authenticated-poll.
# Drives the real product CLIs (bin/fm-pr-check.sh, bin/fm-watch.sh,
# bin/fm-pr-poll.sh) in a disposable lab. The only stand-in is `gh`, which
# represents the read-only forge API read (no network/credentialed mutation).
set -u
SRC=${SRC:?worktree}
BASE=${BASE:?base commit}
LAB=${LAB:?lab dir}
OUT=${OUT:?out dir}
export PATH="/run/current-system/sw/bin:$PATH"

log() { printf '\n=== %s\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAILED=$((FAILED+1)); }
FAILED=0

# --- fake forge CLI (read-only state read) --------------------------------
make_fakebin() {  # <dir>
  local d=$1
  mkdir -p "$d"
  cat > "$d/gh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s\n' "${GH_HOST:-}" >> "${FM_TEST_GH_LOG:-/dev/null}"
printf '%s\n' "$*" >> "${FM_TEST_GH_LOG:-/dev/null}"
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *statusCheckRollup*)
        printf '%s\n' "{\"state\":\"OPEN\",\"isDraft\":false,\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"CLEAN\",\"headRefOid\":\"${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}\",\"baseRefName\":\"main\",\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"name\":\"ci\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"}]}"
        exit 0 ;;
      *" --json isDraft "*)
        printf '%s\n' '{"isDraft":false}'; exit 0 ;;
      *headRefOid,reviewDecision*)
        printf '%s\n' "{\"headRefOid\":\"${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}\",\"reviewDecision\":\"APPROVED\"}"; exit 0 ;;
    esac ;;
esac
case " $* " in
  *" api repos/"*"/issues/"*"/comments?per_page=100 "*|*" api repos/"*"/pulls/"*"/reviews?per_page=100 "*|*" api repos/"*"/pulls/"*"/comments?per_page=100 "*) printf '%s\n' '[[]]' ;;
  *" api repos/"*"/commits/"*"/check-runs?filter=all&per_page=100 "*) printf '%s\n' '[{"check_runs":[]}]' ;;
  *" api repos/"*"/commits/"*"/statuses?per_page=100 "*) printf '%s\n' '[[]]' ;;
  *" api --paginate repos/"*"/rules/branches/"*merge_queue*) ;;
  *" api --paginate repos/"*"/rules/branches/"*) printf '%s\n' '[]' ;;
  *" api repos/"*"/branches/"*) printf '%s\n' '{"name":"main","protected":false}' ;;
  *" api repos/"*"/pulls/"*) printf '%s\n' "{\"state\":\"open\",\"user\":{\"login\":\"author\"},\"head\":{\"sha\":\"${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}\"},\"draft\":false,\"mergeable\":true,\"merged_at\":null}" ;;
  *" api repos/"*) printf '%s\n' '{"permissions":{"push":false}}' ;;
  *" headRefOid "*) printf '%s\n' "${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}" ;;
  *" state "*) printf '%s\n' "${FM_TEST_GH_STATE:-OPEN}" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$d/gh"
}

# --- disposable case: repo generation copies + home + fixture worktree ----
make_case() {  # <name> -> prints case dir
  local name=$1
  local d="$LAB/$name"
  mkdir -p "$d/home/state" "$d/home/data" "$d/home/config" "$d/wt" "$d/sentinels" "$d/fakebin"
  make_fakebin "$d/fakebin"
  git -C "$d/wt" init -q -b main
  git -C "$d/wt" -c user.email=fm@example.invalid -c user.name=fm commit -q --allow-empty -m init
  git -C "$d/wt" update-ref refs/remotes/origin/main "$(git -C "$d/wt" rev-parse HEAD)"
  printf 'window=fm-task-a\nendpoint_task_id=task-a\nworktree=%s/wt\nproject=%s/project\nkind=ship\nmode=no-mistakes\n' \
    "$d" "$d" > "$d/home/state/task-a.meta"
  printf '%s\n' "$d"
}

# Copy a repository generation (a checkout of release N) into a case.
make_generation() {  # <case> <name> <rev>
  local d=$1 name=$2 rev=$3
  local gen="$1/$2"
  mkdir -p "$gen"
  git -C "$SRC" archive "$rev" | tar -x -C "$gen"
  printf '%s\n' "$gen"
}

run_arm() {  # <case> <generation>
  local d=$1 gen=$2
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
      -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      FM_HOME="$d/home" FM_ROOT_OVERRIDE="$gen" \
      FM_TEST_GH_LOG="$d/gh.log" FM_TEST_GH_STATE=OPEN \
      PATH="$d/fakebin:$PATH" \
      "$gen/bin/fm-pr-check.sh" task-a https://github.com/o/r/pull/1
}

run_watch() {  # <case> <generation> <state-for-gh>
  local d=$1 gen=$2 ghstate=${3:-MERGED}
  : > "$d/gh.log"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
      -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_ROOT_OVERRIDE \
      FM_HOME="$d/home" FM_ROOT_OVERRIDE="$gen" \
      FM_CHECK_INTERVAL=0 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      FM_TEST_GH_LOG="$d/gh.log" FM_TEST_GH_STATE="$ghstate" \
      PATH="$d/fakebin:$PATH" \
      timeout 120 "$gen/bin/fm-watch.sh"
}

poll_state() {  # <case> -> list of surviving poll artifacts
  local d=$1 s
  for s in check.sh pr-poll pr-poll-registration pr-poll-retirement; do
    [ -e "$d/home/state/task-a.$s" ] && printf '%s ' "$s"
  done
  printf '\n'
}

marker() {  # <poll-template> <sentinel-path> <tag>
  local f=$1 s=$2 tag=$3 tmp
  tmp=$(mktemp)
  awk 'NR==1 { prev = $0; next } { print prev; prev = $0 }' "$f" > "$tmp"
  printf '# %s generation marker\nprintf "%s\\n" >> "%s"\nexit 0\n' "$tag" "$tag" "$s" >> "$tmp"
  chmod 0755 "$tmp"
  mv -- "$tmp" "$f"
}

fresh_template() {  # <generation> <rev>
  local gen=$1 rev=$2
  git -C "$SRC" show "$rev:bin/fm-pr-poll.sh" > "$gen/bin/fm-pr-poll.sh"
}

# =========================================================================
# A. An armed poll survives a repository update to a new release template.
# =========================================================================
log "A. armed poll survives a repository template update (new release)"
d=$(make_case A)
gen=$(make_generation "$d" rel-old "$(cd "$SRC" && git rev-parse HEAD)")
# Release N: this generation's poll body carries marker OLD.
marker "$gen/bin/fm-pr-poll.sh" "$d/sentinels/old-generation-ran" OLD
run_arm "$d" "$gen" > "$d/arm.out" 2>&1 || bad "A: arming the poll failed: $(cat "$d/arm.out")"
grep -q '^armed: state/task-a.check.sh$' "$d/arm.out" && ok "A: poll armed" || bad "A: no armed line"
cp "$d/home/state/task-a.check.sh" "$d/armed-check.sh"
cp "$d/home/state/task-a.pr-poll-registration" "$d/armed-registration"
printf 'registered template hash: %s\n' "$(sed -n 8p "$d/armed-registration")"
[ -e "$d/sentinels/old-generation-ran" ] && bad "A: arming executed the poll body" || ok "A: arming executed nothing"
# Repository update: release N+1 poll body carries marker NEW.
fresh_template "$gen" "$(cd "$SRC" && git rev-parse HEAD)"
marker "$gen/bin/fm-pr-poll.sh" "$d/sentinels/new-generation-ran" NEW
if cmp -s "$gen/bin/fm-pr-poll.sh" "$d/home/state/task-a.check.sh"; then
  bad "A: template update did not change the repository poll"
else
  ok "A: repository update changed bin/fm-pr-poll.sh (state check is now the old generation)"
fi
run_watch "$d" "$gen" MERGED > "$d/watch.out" 2> "$d/watch.err"; rc=$?
printf 'watcher rc=%s\n' "$rc"
printf -- '--- watcher stdout\n'; cat "$d/watch.out"
printf -- '--- watcher stderr\n'; cat "$d/watch.err"
printf -- '--- forge CLI calls\n'; cat "$d/gh.log"
[ "$rc" -eq 0 ] && ok "A: watcher cycle completed" || bad "A: watcher rc=$rc"
grep -qF 'task-a.check.sh: merged' "$d/watch.out" && ok "A: merge detected and reported after the update" \
  || bad "A: merge notification lost after the update"
grep -qF 'rejected unauthenticated state checks' "$d/watch.out" && bad "A: the intact generation was rejected" \
  || ok "A: the intact generation was not rejected"
[ -e "$d/sentinels/new-generation-ran" ] && ok "A: the current repository poll ran" \
  || bad "A: the current repository poll did not run"
[ -e "$d/sentinels/old-generation-ran" ] && bad "A: the registered state-file bytes executed" \
  || ok "A: the registered state-file bytes never executed"
grep -qF 'pr view https://github.com/o/r/pull/1 --json state' "$d/gh.log" && ok "A: poll dispatched the registered PR identity" \
  || bad "A: poll did not read the registered PR identity"
printf 'surviving poll artifacts: %s\n' "$(poll_state "$d")"
[ -z "$(poll_state "$d" | tr -d ' ')" ] && ok "A: merged poll retired its artifacts" || bad "A: poll artifacts survived"
grep -qxF 'pr=https://github.com/o/r/pull/1' "$d/home/state/task-a.meta" && ok "A: task PR identity preserved" || bad "A: PR identity lost"
printf -- '--- wake queue\n'; cat "$d/home/state/.wake-queue" 2>/dev/null || true

# =========================================================================
# A-base. Control: the pre-change code rejects the same intact generation.
# =========================================================================
log "A-base. control: base commit rejects the same intact registered generation"
d=$(make_case A-base)
gen=$(make_generation "$d" rel "$BASE")
marker "$gen/bin/fm-pr-poll.sh" "$d/sentinels/old-generation-ran" OLD
run_arm "$d" "$gen" > "$d/arm.out" 2>&1 || bad "A-base: arming failed: $(cat "$d/arm.out")"
fresh_template "$gen" "$BASE"
marker "$gen/bin/fm-pr-poll.sh" "$d/sentinels/new-generation-ran" NEW
run_watch "$d" "$gen" MERGED > "$d/watch.out" 2> "$d/watch.err"; rc=$?
printf 'watcher rc=%s\n' "$rc"; printf -- '--- watcher stdout\n'; cat "$d/watch.out"
printf 'surviving poll artifacts: %s\n' "$(poll_state "$d")"
grep -qF 'task-a.check.sh: merged' "$d/watch.out" && bad "A-base: base unexpectedly reported the merge" \
  || ok "A-base: base code lost the merge (reproduces the reported failure)"
grep -qF 'rejected unauthenticated state checks' "$d/watch.out" && ok "A-base: base code rejected the intact generation" \
  || bad "A-base: base code did not reject it either"

# =========================================================================
# B. A control relaunch that appends control_relaunch_tx keeps the poll armed.
# =========================================================================
log "B. armed poll survives control_relaunch_tx metadata appended after the PR identity"
d=$(make_case B)
gen=$(make_generation "$d" rel "$(cd "$SRC" && git rev-parse HEAD)")
run_arm "$d" "$gen" > "$d/arm.out" 2>&1 || bad "B: arming failed: $(cat "$d/arm.out")"
grep -qxF 'pr=https://github.com/o/r/pull/1' "$d/home/state/task-a.meta" && ok "B: poll armed with PR identity" || bad "B: no PR identity"
# What a control relaunch appends to the task record.
printf 'control_relaunch_tx=114614.20261024T230110Z.26328\n' >> "$d/home/state/task-a.meta"
printf -- '--- task record after relaunch\n'; cat "$d/home/state/task-a.meta"
run_watch "$d" "$gen" MERGED > "$d/watch.out" 2> "$d/watch.err"; rc=$?
printf 'watcher rc=%s\n' "$rc"; printf -- '--- watcher stdout\n'; cat "$d/watch.out"; printf -- '--- watcher stderr\n'; cat "$d/watch.err"
[ "$rc" -eq 0 ] && ok "B: watcher cycle completed" || bad "B: watcher rc=$rc"
grep -qF 'task-a.check.sh: merged' "$d/watch.out" && ok "B: merge detected after the control relaunch" \
  || bad "B: merge notification lost after the control relaunch"
grep -qF 'rejected unauthenticated state checks' "$d/watch.out" && bad "B: poll was rejected for relaunch metadata" \
  || ok "B: poll was not rejected for relaunch metadata"
printf 'surviving poll artifacts: %s\n' "$(poll_state "$d")"
[ -z "$(poll_state "$d" | tr -d ' ')" ] && ok "B: merged poll retired its artifacts" || bad "B: poll artifacts survived"
grep -qxF 'control_relaunch_tx=114614.20261024T230110Z.26328' "$d/home/state/task-a.meta" \
  && ok "B: relaunch transaction preserved in the task record" || bad "B: relaunch metadata lost"

# =========================================================================
# B-adversarial. Forged trailing metadata is still refused.
# =========================================================================
for forged in 'injected=value' 'pr=https://github.com/o/r/pull/2' 'pr_head=not-a-sha'; do
  name="B-forged-$(printf '%s' "$forged" | tr -c 'a-z0-9' '-' | sed 's/-\{2,\}/-/g;s/-$//')"
  log "B-adversarial. forged trailing metadata refused: $forged"
  d=$(make_case "$name")
  gen=$(make_generation "$d" rel "$(cd "$SRC" && git rev-parse HEAD)")
  run_arm "$d" "$gen" > "$d/arm.out" 2>&1 || bad "$name: arming failed: $(cat "$d/arm.out")"
  registration_before=$(shasum -a 256 "$d/home/state/task-a.pr-poll-registration" | awk '{print $1}')
  printf 'control_relaunch_tx=114614.20261024T230110Z.26328\n%s\n' "$forged" >> "$d/home/state/task-a.meta"
  run_watch "$d" "$gen" MERGED > "$d/watch.out" 2> "$d/watch.err"; rc=$?
  printf 'watcher rc=%s\n' "$rc"; printf -- '--- watcher stdout\n'; cat "$d/watch.out"
  printf 'surviving poll artifacts: %s\n' "$(poll_state "$d")"
  [ "$rc" -eq 0 ] || bad "$name: watcher rc=$rc"
  grep -qF 'rejected unauthenticated state checks: ' "$d/watch.out" && ok "$name: forged metadata rejected" \
    || bad "$name: forged metadata was accepted"
  grep -qF 'task-a.check.sh: merged' "$d/watch.out" && bad "$name: forged metadata produced a merge notification" \
    || ok "$name: no merge notification from forged metadata"
  [ -n "$(poll_state "$d" | tr -d ' ')" ] && ok "$name: poll stayed armed for a later honest cycle" \
    || bad "$name: poll was retired on forged metadata"
  registration_after=$(shasum -a 256 "$d/home/state/task-a.pr-poll-registration" | awk '{print $1}')
  [ "$registration_before" = "$registration_after" ] && ok "$name: trust was not rewritten" || bad "$name: trust was rewritten"
done

# =========================================================================
# C. Tampered check bytes are still refused and never executed.
# =========================================================================
log "C. tampered registered check bytes refused and never executed"
d=$(make_case C)
gen=$(make_generation "$d" rel "$(cd "$SRC" && git rev-parse HEAD)")
run_arm "$d" "$gen" > "$d/arm.out" 2>&1 || bad "C: arming failed: $(cat "$d/arm.out")"
cp "$d/home/state/task-a.pr-poll-registration" "$d/registration-before"
printf '\n# forged after registration\nprintf "forged\\n" >> "%s"\n' "$d/sentinels/forged-ran" >> "$d/home/state/task-a.check.sh"
run_watch "$d" "$gen" MERGED > "$d/watch.out" 2> "$d/watch.err"; rc=$?
printf 'watcher rc=%s\n' "$rc"; printf -- '--- watcher stdout\n'; cat "$d/watch.out"
printf 'surviving poll artifacts: %s\n' "$(poll_state "$d")"
[ "$rc" -eq 0 ] || bad "C: watcher rc=$rc"
grep -qF 'rejected unauthenticated state checks: ' "$d/watch.out" && ok "C: tampered check bytes rejected" \
  || bad "C: tampered check bytes accepted"
grep -qF 'task-a.check.sh: merged' "$d/watch.out" && bad "C: tampered check produced a merge notification" \
  || ok "C: no merge notification from tampered bytes"
[ -e "$d/sentinels/forged-ran" ] && bad "C: forged check bytes executed" || ok "C: forged check bytes never executed"
[ -n "$(poll_state "$d" | tr -d ' ')" ] && ok "C: poll stayed armed after the refusal" || bad "C: poll was retired"
cmp -s "$d/registration-before" "$d/home/state/task-a.pr-poll-registration" \
  && ok "C: trust registration unchanged" || bad "C: trust registration rewritten"

# =========================================================================
# A2. Operator recovery: re-arming after the update registers the new generation.
# =========================================================================
log "A2. re-arming after a repository update registers the new generation"
d=$(make_case A2)
gen=$(make_generation "$d" rel-old "$(cd "$SRC" && git rev-parse HEAD)")
marker "$gen/bin/fm-pr-poll.sh" "$d/sentinels/old-generation-ran" OLD
run_arm "$d" "$gen" > "$d/arm.out" 2>&1 || bad "A2: arming failed: $(cat "$d/arm.out")"
cp "$d/home/state/task-a.pr-poll-registration" "$d/registration-old"
fresh_template "$gen" "$(cd "$SRC" && git rev-parse HEAD)"
marker "$gen/bin/fm-pr-poll.sh" "$d/sentinels/new-generation-ran" NEW
run_arm "$d" "$gen" > "$d/rearm.out" 2>&1 || bad "A2: re-arming after the update failed: $(cat "$d/rearm.out")"
cat "$d/rearm.out"
cmp -s "$d/registration-old" "$d/home/state/task-a.pr-poll-registration" \
  && bad "A2: re-arm left the old generation registered" \
  || ok "A2: re-arm registered the new generation"
cmp -s "$gen/bin/fm-pr-poll.sh" "$d/home/state/task-a.check.sh" \
  && ok "A2: published check is byte-identical to the current repository poll" \
  || bad "A2: published check does not match the current repository poll"
run_watch "$d" "$gen" MERGED > "$d/watch.out" 2> "$d/watch.err"; rc=$?
printf 'watcher rc=%s\n' "$rc"; printf -- '--- watcher stdout\n'; cat "$d/watch.out"
grep -qF 'task-a.check.sh: merged' "$d/watch.out" && ok "A2: merge detected after re-arm" || bad "A2: merge lost after re-arm"
[ -e "$d/sentinels/new-generation-ran" ] && ok "A2: the newly armed generation ran" || bad "A2: the newly armed generation did not run"

# =========================================================================
# E. The full reported combination: a new release AND a control relaunch.
# =========================================================================
log "E. repository update and control relaunch together keep the poll armed"
d=$(make_case E)
gen=$(make_generation "$d" rel-old "$(cd "$SRC" && git rev-parse HEAD)")
marker "$gen/bin/fm-pr-poll.sh" "$d/sentinels/old-generation-ran" OLD
run_arm "$d" "$gen" > "$d/arm.out" 2>&1 || bad "E: arming failed: $(cat "$d/arm.out")"
printf 'control_relaunch_tx=114614.20261024T230110Z.26328\n' >> "$d/home/state/task-a.meta"
fresh_template "$gen" "$(cd "$SRC" && git rev-parse HEAD)"
marker "$gen/bin/fm-pr-poll.sh" "$d/sentinels/new-generation-ran" NEW
run_watch "$d" "$gen" MERGED > "$d/watch.out" 2> "$d/watch.err"; rc=$?
printf 'watcher rc=%s\n' "$rc"; printf -- '--- watcher stdout\n'; cat "$d/watch.out"
[ "$rc" -eq 0 ] && ok "E: watcher cycle completed" || bad "E: watcher rc=$rc"
grep -qF 'task-a.check.sh: merged' "$d/watch.out" && ok "E: merge detected after update plus relaunch" \
  || bad "E: merge notification lost after update plus relaunch"
grep -qF 'rejected unauthenticated state checks' "$d/watch.out" && bad "E: poll rejected" || ok "E: poll not rejected"
[ -e "$d/sentinels/new-generation-ran" ] && ok "E: the current repository poll ran" || bad "E: current poll did not run"
[ -e "$d/sentinels/old-generation-ran" ] && bad "E: registered state-file bytes executed" || ok "E: registered state-file bytes never executed"
[ -z "$(poll_state "$d" | tr -d ' ')" ] && ok "E: merged poll retired its artifacts" || bad "E: poll artifacts survived"
printf -- '--- wake queue\n'; cat "$d/home/state/.wake-queue" 2>/dev/null || true

# =========================================================================
# F. Adversarial boundary: a symlinked repository poll is not dispatched.
# =========================================================================
log "F. symlinked repository poll refused, never executed"
d=$(make_case F)
gen=$(make_generation "$d" rel "$(cd "$SRC" && git rev-parse HEAD)")
run_arm "$d" "$gen" > "$d/arm.out" 2>&1 || bad "F: arming failed: $(cat "$d/arm.out")"
mkdir -p "$d/links"
printf '#!/usr/bin/env bash\nprintf "linked\\n" >> "%s"\nprintf "merged\\n"\n' "$d/sentinels/symlink-target-ran" > "$d/links/poll.sh"
chmod 0755 "$d/links/poll.sh"
mv "$gen/bin/fm-pr-poll.sh" "$gen/bin/fm-pr-poll.real"
ln -s "$d/links/poll.sh" "$gen/bin/fm-pr-poll.sh"
run_watch "$d" "$gen" MERGED > "$d/watch.out" 2> "$d/watch.err"; rc=$?
printf 'watcher rc=%s\n' "$rc"; printf -- '--- watcher stdout\n'; cat "$d/watch.out"
[ "$rc" -eq 0 ] || bad "F: watcher rc=$rc"
grep -qF 'rejected unauthenticated state checks: ' "$d/watch.out" && ok "F: symlinked repository poll refused" \
  || bad "F: symlinked repository poll was trusted"
[ -e "$d/sentinels/symlink-target-ran" ] && bad "F: symlink target executed" || ok "F: symlink target never executed"
grep -qF 'task-a.check.sh: merged' "$d/watch.out" && bad "F: merge reported from an unauthenticated template" \
  || ok "F: no merge reported from the symlinked template"
[ -n "$(poll_state "$d" | tr -d ' ')" ] && ok "F: poll stayed armed" || bad "F: poll retired"

# =========================================================================
# D. Real forge (read-only): the current repository poll dispatched with
#    validated data reports the live merged state of a public pull request.
# =========================================================================
log "D. real forge read-only: validated poll dispatch against github.com/cli/cli"
real_poll="$SRC/bin/fm-pr-poll.sh"
for url in https://github.com/cli/cli/pull/1; do
  live_state=$(gh pr view "$url" --json state -q .state 2>/dev/null || true)
  printf 'live forge state for %s: %s\n' "$url" "$live_state"
  provider=github host=github.com path=cli/cli number=1
  poll_out=$(env -u FM_GATE_REFUSE_BYPASS "$real_poll" --validated "$provider" "$url" "$host" "$path" "$number" 2>&1)
  printf 'poll output: %s\n' "$poll_out"
  case "$live_state" in
    MERGED) [ "$poll_out" = merged ] && ok "D: validated poll reported the live merged state" || bad "D: validated poll missed a live merged state" ;;
    *) [ -z "$poll_out" ] && ok "D: validated poll stayed silent for a non-merged state" || bad "D: validated poll reported a merge that did not happen" ;;
  esac
  # A validated record that is not the URL's own identity must stay silent.
  forged=$(env -u FM_GATE_REFUSE_BYPASS "$real_poll" --validated "$provider" https://github.com/cli/cli/pull/2 "$host" "$path" "$number" 2>&1)
  [ -z "$forged" ] && ok "D: an identity that does not reconstruct its URL stayed silent" \
    || bad "D: a mismatched validated identity produced output"
done

printf '\n=== SUMMARY: %s failing assertion(s)\n' "$FAILED"
exit "$FAILED"
