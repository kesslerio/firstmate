#!/usr/bin/env bash
# Direct product drives for the gpt-5.6-luna -> gpt-6-luna codex max-effort
# validation-key swap. Drives the REAL bin/fm-spawn.sh, bin/fm-bootstrap.sh,
# and bin/fm-dispatch-resolve.sh from the worktree, using the repo's own test
# fixture mechanics (fake tmux pane records the literal launch command; no
# real harness is ever started; the resolve cases run with no curl on PATH so
# nothing can reach the network).
set -u

WT=/Users/kesslerio/.no-mistakes/worktrees/8036f35f7c08/01M35CSPDYP15AWF68E5P4TXBB
OUT=/Users/kesslerio/.no-mistakes/evidence/01M35CSPDYP15AWF68E5P4TXBB/drive-transcript.txt
: > "$OUT"
say() { printf '%s\n' "$*" | tee -a "$OUT"; }

# Clean any stale case dirs from earlier driver attempts.
rm -rf "${TMPDIR:-/tmp}"/gpt6drive.* "${TMPDIR:-/tmp}"/gpt6boot.* \
       "${TMPDIR:-/tmp}"/gpt6res.* /tmp/gpt6-toolchain.sh 2>/dev/null

# shellcheck source=tests/lib.sh
. "$WT/tests/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$WT/tests/fixtures.sh"

# Bootstrap toolchain helpers, extracted verbatim from tests/fm-bootstrap.test.sh
# (function definitions only; nothing executes on source).
awk '/^make_fake_toolchain\(\)/,/^}/' "$WT/tests/fm-bootstrap.test.sh" > /tmp/gpt6-toolchain.sh
awk '/^add_quota_axi\(\)/,/^}/' "$WT/tests/fm-bootstrap.test.sh" >> /tmp/gpt6-toolchain.sh
awk '/^add_tasks_axi\(\)/,/^}/' "$WT/tests/fm-bootstrap.test.sh" >> /tmp/gpt6-toolchain.sh
awk '/^add_real_jq\(\)/,/^}/' "$WT/tests/fm-bootstrap.test.sh" >> /tmp/gpt6-toolchain.sh
# shellcheck source=/tmp/gpt6-toolchain.sh
. /tmp/gpt6-toolchain.sh

fail_count=0
check() { # check <label> <exit-code-of-condition: 0=pass>
  if [ "$2" = 0 ]; then
    say "PASS: $1"
  else
    say "FAIL: $1"
    fail_count=$((fail_count + 1))
  fi
}

say "=== worktree: $WT"
say "=== git head: $(git -C "$WT" rev-parse HEAD)"
say ""

# ---------------------------------------------------------------------------
# Spawn fakebin, replicated from tests/fm-spawn-dispatch-profile.test.sh
# ---------------------------------------------------------------------------
make_drive_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$dir")
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  cat > "$fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --list-models ]; then
  [ "${FM_FAKE_CURSOR_LIST_STATUS:-0}" -eq 0 ] || exit "${FM_FAKE_CURSOR_LIST_STATUS}"
  printf '%b\n' "${FM_FAKE_CURSOR_MODELS:-Available models\ncursor-grok-4.5-high - Grok 4.5 High}"
fi
exit 0
SH
  chmod +x "$fakebin/timeout" "$fakebin/cursor-agent"
  for tool in pi pi-signed; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  if [ "${FM_FAKE_PI_VERSION:-0.84.0}" = 0.82.0 ]; then
    printf '%s\n' 'Pi 0.82.0' 'Options: --help'
  else
    printf '%s\n' "Pi ${FM_FAKE_PI_VERSION:-0.84.0}" 'Options: --help --tui-mode <mode>'
  fi
fi
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
  printf '%s\n' "$fakebin"
}

# spawn_case <model> <effort> <tag>: drive the real fm-spawn.sh end to end with
# a fake tmux pane; echoes the case dir. The pane path is the task worktree,
# exactly as the suite drives it; the positional project arg is the parent repo.
spawn_case() {
  local model=$1 effort=$2 tag=$3
  local case_dir home proj wt fakebin launchlog id
  case_dir=$(mktemp -d "${TMPDIR:-/tmp}/gpt6drive.$tag.XXXXXX")
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_drive_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-gpt6-$tag"
  id="gpt6-$tag"
  fm_test_spawn_brief "$home" "$id"
  : > "$launchlog"
  CLAUDE_CONFIG_DIR= FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PI_VERSION=0.84.0 \
    GROK_HOME="$home/grok-home" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$WT/bin/fm-spawn.sh" "$id" "$proj" --harness codex --model "$model" --effort "$effort" \
    --mode no-mistakes --yolo off > "$case_dir/out.txt" 2>&1
  local status=$?
  printf '%s\n' "$case_dir"
}

report_spawn_case() { # report_spawn_case <case-dir> <tag> <task-id>
  local case_dir=$1 tag=$2 id=$3
  say "--- spawn case $tag"
  say "    spawn stdout: $(grep -E '^(spawned|warning|error)' "$case_dir/out.txt" | head -2 | tr '\n' ' ')"
  say "    launch command: $(cat "$case_dir/launch.log")"
  say "    meta: $(grep -E '^(harness|model|effort)=' "$case_dir/home/state/$id.meta" 2>/dev/null | tr '\n' ' ')"
  say ""
}

say "=== Scenario A: fm-spawn.sh codex max-effort gate (launch construction)"
c1=$(spawn_case gpt-6-luna max newkey)
c2=$(spawn_case gpt-5.6-luna max retiredkey)
c3=$(spawn_case gpt-6-sol max othersol)
report_spawn_case "$c1" "newkey (model=gpt-6-luna effort=max)" gpt6-newkey
report_spawn_case "$c2" "retiredkey (model=gpt-5.6-luna effort=max)" gpt6-retiredkey
report_spawn_case "$c3" "othersol (model=gpt-6-sol effort=max)" gpt6-othersol
l1=$(cat "$c1/launch.log"); l2=$(cat "$c2/launch.log"); l3=$(cat "$c3/launch.log")
m1=$(cat "$c1/home/state/gpt6-newkey.meta" 2>/dev/null)
m2=$(cat "$c2/home/state/gpt6-retiredkey.meta" 2>/dev/null)

check "A1: codex gpt-6-luna max spawn succeeds" \
  "$(grep -q 'spawned gpt6-newkey harness=codex' "$c1/out.txt"; echo $?)"
check "A1: launch threads -c 'model_reasoning_effort=\"max\"' for gpt-6-luna" \
  "$(printf '%s' "$l1" | grep -F -- "-c 'model_reasoning_effort=\"max\"'" >/dev/null; echo $?)"
check "A1: launch binds the flag to the gpt-6-luna model flag order" \
  "$(printf '%s' "$l1" | grep -F -- "codex --model 'gpt-6-luna' -c 'model_reasoning_effort=\"max\"'" >/dev/null; echo $?)"
check "A1: meta records model=gpt-6-luna effort=max" \
  "$(printf '%s' "$m1" | grep -q 'model=gpt-6-luna' && printf '%s' "$m1" | grep -q 'effort=max'; echo $?)"
check "A2: retired gpt-5.6-luna max spawn still succeeds (record-and-omit)" \
  "$(grep -q 'spawned gpt6-retiredkey harness=codex' "$c2/out.txt"; echo $?)"
check "A2: launch does NOT thread model_reasoning_effort=max for gpt-5.6-luna" \
  "$(printf '%s' "$l2" | grep -F 'model_reasoning_effort=\"max\"' >/dev/null && echo 1 || echo 0)"
check "A2: meta still records the requested effort=max for traceability" \
  "$(printf '%s' "$m2" | grep -q 'effort=max'; echo $?)"
check "A3: gpt-6-sol (non-key model) max also omits the flag" \
  "$(printf '%s' "$l3" | grep -F 'model_reasoning_effort=\"max\"' >/dev/null && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# Bootstrap crew-dispatch validation: the full real bootstrap run with an
# isolated FM_HOME, driven exactly as tests/fm-bootstrap.test.sh drives it.
# ---------------------------------------------------------------------------
say "=== Scenario B: fm-bootstrap.sh crew-dispatch validation"
boot_case() { # boot_case <rules-json> <tag>
  local body=$1 tag=$2 dir fakebin out
  dir=$(mktemp -d "${TMPDIR:-/tmp}/gpt6boot.$tag.XXXXXX")
  mkdir -p "$dir/home/config"
  printf '%s\n' manual > "$dir/home/config/backlog-backend"
  printf '%s\n' "$body" > "$dir/home/config/crew-dispatch.json"
  fakebin=$(make_fake_toolchain "$dir")
  add_real_jq "$fakebin"
  out=$(cd "$WT" && PATH="$fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_PROJECTS_OVERRIDE="$dir/home/projects" FM_CONFIG_OVERRIDE="$dir/home/config" \
    TYPESAFE_API_KEY=test-key FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$WT/bin/fm-bootstrap.sh" 2>/dev/null)
  local status=$?
  printf '%s' "$out" > "$dir/bootstrap-out.txt"
  say "--- bootstrap case $tag exit=$status output: ${out:-<silent>}"
}

boot_case '{"rules":[{"when":"big feature","use":{"harness":"codex","model":"gpt-6-luna","effort":"max"}}]}' newkey
check "B1: bootstrap accepts codex gpt-6-luna max (no CREW_DISPATCH diagnostic)" \
  "$(grep -q 'CREW_DISPATCH' "$TMPDIR"/gpt6boot.newkey.*/bootstrap-out.txt 2>/dev/null && echo 1 || echo 0)"

boot_case '{"rules":[{"when":"big feature","use":{"harness":"codex","model":"gpt-5.6-luna","effort":"max"}}]}' retiredkey
check "B2: bootstrap REJECTS retired gpt-5.6-luna max with the invalid-effort diagnostic" \
  "$(grep -Fq 'CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: codex:max' "$TMPDIR"/gpt6boot.retiredkey.*/bootstrap-out.txt 2>/dev/null; echo $?)"

boot_case '{"rules":[{"when":"big feature","use":{"harness":"codex","model":"gpt-5","effort":"max"}}]}' plainkey
check "B3: bootstrap still rejects non-key gpt-5 max" \
  "$(grep -Fq 'CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: codex:max' "$TMPDIR"/gpt6boot.plainkey.*/bootstrap-out.txt 2>/dev/null; echo $?)"

# ---------------------------------------------------------------------------
# dispatch-resolve effort gate: no curl on PATH, so neither case can reach the
# network. A REJECTED config dies in validation (exit 2, effort error); an
# ACCEPTED config gets past validation and only then reports the missing
# network tool. The full positive resolution path is covered by the suite.
# ---------------------------------------------------------------------------
say "=== Scenario C: fm-dispatch-resolve.sh effort gate (validation before network)"
resolve_case() { # resolve_case <rules-json> <tag>
  local body=$1 tag=$2 dir nopath t
  dir=$(mktemp -d "${TMPDIR:-/tmp}/gpt6res.$tag.XXXXXX")
  mkdir -p "$dir/config"
  cat > "$dir/brief.md" <<'MD'
# Task
Fix the off-by-one in the pager: root cause is the `<=` on line 40 of pager.sh.
MD
  printf '%s\n' "$body" > "$dir/config/crew-dispatch.json"
  nopath=$(mktemp -d "${TMPDIR:-/tmp}/gpt6res.$tag.bin.XXXXXX")
  # Exact NO_CURL_BIN list from tests/fm-dispatch-resolve.test.sh
  for t in bash chmod cp dirname jq mktemp rm; do
    ln -sf "$(command -v "$t")" "$nopath/$t"
  done
  ( cd "$dir" && PATH="$nopath" FM_HOME="$dir" TYPESAFE_API_KEY=test-key \
      "$WT/bin/fm-dispatch-resolve.sh" "$dir/brief.md" ) > "$dir/out.txt" 2> "$dir/err.txt"
  local status=$?
  say "--- resolve case $tag exit=$status stderr: $(head -2 "$dir/err.txt" | tr '\n' ' ')"
  say "    stdout: $(tr '\n' ' ' < "$dir/out.txt")"
}

resolve_case '{"rules":[{"when":"A simple bug fix with a stated root cause.","use":{"harness":"codex","model":"gpt-5.6-luna","effort":"max"}}],"default":{"harness":"codex"}}' retiredkey
check "C1: resolve REJECTS retired gpt-5.6-luna max with the validation error (exit 2)" \
  "$(grep -Fq 'each use profile effort must be supported by its harness and model' "$TMPDIR"/gpt6res.retiredkey.*/err.txt; echo $?)"
check "C1: the rejection is a validation error, not the missing-curl error" \
  "$(grep -Fq 'curl not installed' "$TMPDIR"/gpt6res.retiredkey.*/out.txt "$TMPDIR"/gpt6res.retiredkey.*/err.txt 2>/dev/null && echo 1 || echo 0)"

resolve_case '{"rules":[{"when":"A simple bug fix with a stated root cause.","use":{"harness":"codex","model":"gpt-6-luna","effort":"max"}}],"default":{"harness":"codex"}}' newkey
check "C2: resolve ACCEPTS gpt-6-luna max (no validation error)" \
  "$(grep -Fq 'each use profile effort must be supported' "$TMPDIR"/gpt6res.newkey.*/err.txt "$TMPDIR"/gpt6res.newkey.*/out.txt 2>/dev/null && echo 1 || echo 0)"
check "C2: the only failure is the absent network tool (expected in this env)" \
  "$(grep -Fq 'curl not installed' "$TMPDIR"/gpt6res.newkey.*/out.txt; echo $?)"

say ""
if [ "$fail_count" -eq 0 ]; then
  say "ALL DIRECT DRIVES PASSED"
else
  say "DIRECT DRIVE FAILURES: $fail_count"
fi
exit "$fail_count"
