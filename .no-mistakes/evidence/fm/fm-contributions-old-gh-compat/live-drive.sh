#!/usr/bin/env bash
# Live drive for "keep contribution polling working on a gh too old for api --slurp".
#
# Stands the product up the way the watcher runs it: a disposable FM_HOME, a gh
# on PATH whose `api` paginates over real HTTP against a local GitHub REST
# fixture, and the real bin/fm-contributions.sh. The gh stand-in prints the
# back-to-back page documents an older GitHub CLI prints and hard-fails any read
# that asks for --slurp, so the poll only succeeds if the shipped code no longer
# needs --slurp and assembles the pages itself. Every HTTP request is logged,
# which proves later pages were really fetched.
#
# Usage: ROOT=<worktree> SCRATCH=<empty scratch dir> bash live-drive.sh
set -uo pipefail

ROOT=${ROOT:?worktree root required}
SCRATCH=${SCRATCH:?scratch dir required}
HARNESS=$(cd "$(dirname "$0")" && pwd)
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NOW=2026-09-16T08:00:00Z
FAILED=0
PASSED=0

note() { printf '%s\n' "$*"; }
ok() { PASSED=$((PASSED + 1)); printf '  ok - %s\n' "$*"; }
bad() { FAILED=$((FAILED + 1)); printf '  FAIL - %s\n' "$*"; }
check() { # <description> <exit-status>
  if [ "$2" = 0 ]; then ok "$1"; else bad "$1 (status $2)"; fi
}

say_unavailable() { # poll-output -> 0 when it disclosed an unavailable read
  case "$1" in *'observation unavailable'*) return 0 ;; esac
  return 1
}

start_fixture() { # home store-file [mode] [gh-binary]
  local home=$1 store=$2 mode=${3:-emu} port
  GH_EMU_BIN=${4:-/opt/homebrew/bin/gh}
  export GH_EMU_BIN
  rm -rf "$home"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin" \
    "$home/forge" "$home/root/bin" "$home/wt"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"
  printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  chmod +x "$home/fakebin/tmux" "$home/fakebin/no-mistakes" "$home/root/bin/fm-guard.sh"
  # A delivery worktree is a git copy in real use, and bin/fm-pr-check.sh
  # verifies that before it will register a contribution check.
  git init -q "$home/wt"
  git -C "$home/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture
  printf 'worktree=%s/wt\nkind=ship\n' "$home" > "$home/state/delivery.meta"
  chmod 600 "$home/state/delivery.meta"
  cp "$store" "$home/store.json"
  : > "$home/api-log.txt"
  : > "$home/gh-argv.log"
  API_PORT=0 API_STORE="$home/store.json" API_LOG="$home/api-log.txt" \
    API_PORT_FILE="$home/port" python3 "$HARNESS/api_server.py" &
  echo "$!" > "$home/server.pid"
  local waited=0
  until [ -s "$home/port" ]; do
    waited=$((waited + 1))
    [ "$waited" -lt 50 ] || { bad 'local API fixture never started'; return 1; }
    sleep 0.1
  done
  port=$(cat "$home/port")
  export GH_EMU_BASE="http://127.0.0.1:$port"
  export GH_EMU_PY="$HARNESS/harness-bin/gh_emu.py"
  export GH_EMU_LOG="$home/gh-argv.log"
  export GH_EMU_HEAD="$HEAD_A"
  export GH_EMU_MODE="$mode"
  # Keep any real gh binary off the operator's config and credential store.
  export GH_CONFIG_DIR="$home/ghcfg"
  mkdir -p "$GH_CONFIG_DIR"
  export GH_TOKEN="fixture-token"
  export GH_ENTERPRISE_TOKEN="fixture-token"
  export GH_EMU_REAL="$GH_EMU_BIN"
  cp "$HARNESS/harness-bin/gh" "$home/fakebin/gh"
  chmod +x "$home/fakebin/gh"
}

stop_fixture() {
  local home=$1
  kill "$(cat "$home/server.pid")" 2>/dev/null || true
  wait "$(cat "$home/server.pid")" 2>/dev/null || true
}

seed_pr_record() { # home
  local home=$1
  mkdir -p "$home/data/delivery"
  printf -- '- [ ] delivery - Contribution delivery https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' \
    >> "$home/data/backlog.md"
  jq -n --arg url "https://github.com/o/r/pull/8" --arg head "$HEAD_A" --arg at "$NOW" '
    {schema:"fm-contributions.v1",task:"delivery",records:[{
      url:$url,kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
      observation:{head:$head,state:"open",draft:false,mergeable:"mergeable",
        review_decision:"APPROVED",can_merge:false,checks:[],reviews:[],events:[]}}]}' \
    > "$home/data/delivery/contributions.json"
}

seed_issue_row() { # home
  printf -- '- [ ] filed - Measured defect https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' \
    >> "$1/data/backlog.md"
}

run_product() { # home -- command...
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CONTRIBUTIONS_NOW="$NOW" "$@"
}

wake_lines() { printf '%s\n' "$1" | grep -c '^contribution-wake: ' || true; }
queue_rows() { [ -s "$1" ] && awk 'END {print NR}' "$1" || printf 0; }
say_poll() { note "  poll stdout: $(printf '%s' "$1" | tr '\n' '|')"; }
preserve() { # home label : keep the durable record + request/argv logs as evidence
  local home=$1 label=$2 dir
  [ -n "${EVIDENCE_DIR:-}" ] || return 0
  dir="$EVIDENCE_DIR/$label"
  mkdir -p "$dir"
  cp "$home/data/delivery/contributions.json" "$dir/contributions.json" 2>/dev/null || true
  [ -f "$home/data/filed/contributions.json" ] \
    && cp "$home/data/filed/contributions.json" "$dir/contributions-issue.json"
  cp "$home/api-log.txt" "$dir/api-request-log.txt" 2>/dev/null || true
  cp "$home/gh-argv.log" "$dir/gh-argv-log.txt" 2>/dev/null || true
  [ -f "$home/state/.wake-queue" ] && cp "$home/state/.wake-queue" "$dir/wake-queue.txt"
  return 0
}

scenario_pr_poll() {
  local home="$SCRATCH/home-pr" out record lanes pending page2 rc
  note "== scenario: a gh that rejects api --slurp still polls an owned PR"
  start_fixture "$home" "$HARNESS/store.pr.json" || return
  seed_pr_record "$home"
  out=$(run_product "$home" "$ROOT/bin/fm-contributions.sh" poll); rc=$?
  record="$home/data/delivery/contributions.json"
  check "poll exits successfully on a gh that rejects --slurp" "$rc"
  say_poll "$out"
  if say_unavailable "$out"; then bad "poll reported the read unavailable"; else
    ok "poll reports no forge unavailability on a gh without --slurp"; fi
  check "poll surfaced two contribution wakes" "$([ "$(wake_lines "$out")" = 2 ]; echo $?)"
  local no_slurp=1
  grep -q -- '--slurp' "$home/gh-argv.log" || no_slurp=0
  check "the product never asked gh for --slurp" "$no_slurp"
  note "  gh calls: $(wc -l < "$home/gh-argv.log" | tr -d ' ') -> $(tr '\n' '|' < "$home/gh-argv.log" | cut -c1-170)"
  page2=$(grep -c 'page=2' "$home/api-log.txt")
  check "later pages were fetched over real HTTP (page=2 requests: $page2)" \
    "$([ "$page2" -ge 3 ]; echo $?)"
  lanes=$(jq -r '[.records[0].observation.checks[].name] | sort | join(",")' "$record")
  check "check lanes from BOTH pages are in the observation ($lanes)" \
    "$([ "$lanes" = "page-one-lane,page-two-lane" ]; echo $?)"
  jq -e '.records[0].error == null' "$record" >/dev/null; rc=$?
  check "the observation carries no read error" "$rc"
  pending=$(jq -c '[.records[0].pending[] | {type, author}]' "$record")
  check "second-page maintainer comment and review are both pending ($pending)" \
    "$(printf '%s' "$pending" | jq -e 'length == 2 and ([.[].type] | sort) == ["comment","review"] and all(.[]; .author == "maintainer")' >/dev/null; echo $?)"
  jq -e '.records[0].notified | length == 2' "$record" >/dev/null; rc=$?
  check "both signals are recorded as notified" "$rc"
  check "the durable wake queue holds exactly two keys" \
    "$([ "$(queue_rows "$home/state/.wake-queue")" = 2 ]; echo $?)"
  note "  fixture requests: $(tr '\n' ' ' < "$home/api-log.txt" | cut -c1-300)"
  preserve "$home" artifact-old-gh-pr-poll
  stop_fixture "$home"
}

scenario_dedupe_ack() {
  local home="$SCRATCH/home-ack" out tokens token rc
  note "== scenario: re-poll does not re-ring, ack clears the second-page signals"
  start_fixture "$home" "$HARNESS/store.pr.json" || return
  seed_pr_record "$home"
  run_product "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null
  out=$(run_product "$home" "$ROOT/bin/fm-contributions.sh" poll)
  check "a repeat poll surfaces nothing new" "$([ -z "$out" ]; echo $?)"
  check "a repeat poll does not duplicate durable wakes" \
    "$([ "$(queue_rows "$home/state/.wake-queue")" = 2 ]; echo $?)"
  run_product "$home" "$ROOT/bin/fm-contributions.sh" pending \
    | jq -e 'length == 2 and all(.[]; .author == "maintainer")' >/dev/null; rc=$?
  check "the supervisor reads both pending signals" "$rc"
  tokens=$(run_product "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -r '.[].token')
  for token in $tokens; do
    run_product "$home" "$ROOT/bin/fm-contributions.sh" ack delivery \
      https://github.com/o/r/pull/8 "$token" >/dev/null || bad "ack failed for $token"
  done
  run_product "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null
  run_product "$home" "$ROOT/bin/fm-contributions.sh" pending \
    | jq -e 'length == 0' >/dev/null; rc=$?
  check "acknowledged second-page signals do not replay" "$rc"
  check "acknowledging does not add wakes" \
    "$([ "$(queue_rows "$home/state/.wake-queue")" = 2 ]; echo $?)"
  stop_fixture "$home"
}

scenario_issue_poll() {
  local home="$SCRATCH/home-issue" out record rc
  note "== scenario: a gh without --slurp reports second-page issue activity"
  start_fixture "$home" "$HARNESS/store.pr.json" || return
  seed_pr_record "$home"
  seed_issue_row "$home"
  # Retire the PR so only the issue read waves run.
  jq '.records[0].observation.state = "merged"' "$home/data/delivery/contributions.json" \
    > "$home/tmp.json" && mv "$home/tmp.json" "$home/data/delivery/contributions.json"
  out=$(run_product "$home" "$ROOT/bin/fm-contributions.sh" poll)
  record="$home/data/filed/contributions.json"
  say_poll "$out"
  check "the filed issue gets a record on a gh without --slurp" "$([ -f "$record" ]; echo $?)"
  jq -e '.records[0].error == null' "$record" >/dev/null; rc=$?
  check "the issue observation has no read error" "$rc"
  jq -e '.records[0].pending | length == 2
    and ([.[].type] | sort) == ["comment","ready-for-pr"]
    and ([.[] | select(.type == "comment") | .author] == ["maintainer"])' "$record" >/dev/null; rc=$?
  check "second-page comment + ready-for-pr surface, author/outsider filtered" "$rc"
  check "two issue wakes surface once" "$([ "$(wake_lines "$out")" = 2 ]; echo $?)"
  out=$(run_product "$home" "$ROOT/bin/fm-contributions.sh" poll)
  check "a repeat issue poll replays nothing" "$([ -z "$out" ]; echo $?)"
  check "a repeat issue poll does not duplicate issue wakes" \
    "$([ "$(queue_rows "$home/state/.wake-queue")" = 2 ]; echo $?)"
  note "  issue requests: $(grep -o 'issues/9[^ ]*' "$home/api-log.txt" | tr '\n' ' ')"
  preserve "$home" artifact-old-gh-issue-poll
  stop_fixture "$home"
}

scenario_modern_gh() {
  local home="$SCRATCH/home-modern" out record lanes rc
  note "== scenario: a current GitHub CLI still polls correctly (real gh binary)"
  start_fixture "$home" "$HARNESS/store.pr.json" real || return
  seed_pr_record "$home"
  out=$(run_product "$home" "$ROOT/bin/fm-contributions.sh" poll); rc=$?
  record="$home/data/delivery/contributions.json"
  check "poll exits successfully with the installed gh binary" "$rc"
  say_poll "$out"
  if say_unavailable "$out"; then bad "modern gh reported the read unavailable"; else
    ok "modern gh reports no unavailability"; fi
  lanes=$(jq -r '[.records[0].observation.checks[].name] | sort | join(",")' "$record")
  check "modern gh assembles check lanes from every page ($lanes)" \
    "$([ "$lanes" = "page-one-lane,page-two-lane" ]; echo $?)"
  jq -e '.records[0].pending | length == 2
    and ([.[].type] | sort) == ["comment","review"]' "$record" >/dev/null; rc=$?
  check "modern gh reports the second-page maintainer comment and review" "$rc"
  note "  real gh: $(/opt/homebrew/bin/gh --version | head -1)"
  preserve "$home" artifact-modern-gh-poll
  stop_fixture "$home"
}

scenario_gh_245_binary() {
  local home="$SCRATCH/home-245" out record lanes rc
  note "== scenario: a real gh 2.45.0 CLI, which has no api --slurp, still polls an owned PR"
  start_fixture "$home" "$HARNESS/store.pr.json" real \
    "${GH_245_BIN:?real gh 2.45 binary required}" || return
  seed_pr_record "$home"
  out=$(run_product "$home" "$ROOT/bin/fm-contributions.sh" poll); rc=$?
  record="$home/data/delivery/contributions.json"
  check "poll exits successfully under gh 2.45.0" "$rc"
  say_poll "$out"
  if say_unavailable "$out"; then bad "gh 2.45.0 reported the read unavailable"; else
    ok "gh 2.45.0 reports no unavailability"; fi
  lanes=$(jq -r '[.records[0].observation.checks[].name] | sort | join(",")' "$record")
  check "gh 2.45.0 assembles check lanes from every page ($lanes)" \
    "$([ "$lanes" = "page-one-lane,page-two-lane" ]; echo $?)"
  jq -e '.records[0].pending | length == 2
    and ([.[].type] | sort) == ["comment","review"]' "$record" >/dev/null; rc=$?
  check "gh 2.45.0 reports the second-page maintainer comment and review" "$rc"
  check "the durable wake queue holds both second-page signals" \
    "$([ "$(queue_rows "$home/state/.wake-queue")" = 2 ]; echo $?)"
  local no_slurp=1
  grep -q -- '--slurp' "$home/gh-argv.log" || no_slurp=0
  check "no read asked gh 2.45.0 for --slurp" "$no_slurp"
  note "  real gh: $("$GH_245_BIN" --version | head -1)"
  note "  later-page fetches: $(grep -c 'page=2' "$home/api-log.txt") page-2 requests"
  preserve "$home" artifact-real-gh-245-poll
  stop_fixture "$home"
}

scenario_registered_check() {
  local home="$SCRATCH/home-check" out out2 rc found=0 total=0 check
  note "== scenario: the authenticated check surfaces second-page signals on a gh without --slurp"
  start_fixture "$home" "$HARNESS/store.pr.json" || return
  seed_pr_record "$home"
  out=$(run_product "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8); rc=$?
  note "  register rc=$rc output: $(printf '%s' "$out" | tr '\n' '|' | cut -c1-200)"
  for check in "$home"/state/*.check.sh; do
    [ -f "$check" ] || continue
    found=$((found + 1))
    out2=$(run_product "$home" bash "$check"); rc=$?
    note "  registered check #$found rc=$rc output: $(printf '%s' "$out2" | tr '\n' '|')"
    check "registered check #$found ran without error on a gh without --slurp" \
      "$([ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; echo $?)"
    total=$((total + $(wake_lines "$out2")))
  done
  check "the registered checks surfaced each second-page signal exactly once ($total)" \
    "$([ "$total" = 2 ]; echo $?)"
  check "contribution checks were registered ($found)" "$([ "$found" -ge 1 ]; echo $?)"
  stop_fixture "$home"
}

scenario_malformed_page() {
  local home="$SCRATCH/home-malformed" out record rc
  note "== scenario: a corrupt page is a read failure, never silence"
  python3 - "$HARNESS" "$SCRATCH" <<'PY'
import json, sys
s = json.load(open(sys.argv[1] + "/store.pr.json"))
s["/repos/o/r/issues/8/comments"] = [
    [{"id": 11, "user": {"login": "passerby"}, "author_association": "NONE",
      "body": "x", "html_url": "https://github.com/o/r/pull/8#issuecomment-11",
      "updated_at": "2026-09-16T08:01:00Z"}],
    "__malformed__"]
json.dump(s, open(sys.argv[2] + "/store.malformed.json", "w"), indent=1)
PY
  start_fixture "$home" "$SCRATCH/store.malformed.json" || return
  seed_pr_record "$home"
  out=$(run_product "$home" "$ROOT/bin/fm-contributions.sh" poll)
  record="$home/data/delivery/contributions.json"
  say_poll "$out"
  if say_unavailable "$out"; then ok "a corrupt assembled page is disclosed as unavailable"; else
    bad "a corrupt page was swallowed as silence"; fi
  jq -e '.records[0].error != null' "$record" >/dev/null; rc=$?
  check "the record keeps a read error instead of a fake observation" "$rc"
  jq -e --arg head "$HEAD_A" '.records[0].observation.head == $head' "$record" >/dev/null; rc=$?
  check "the prior observation is preserved beside the error" "$rc"
  check "a corrupt page queues no wake" "$([ ! -s "$home/state/.wake-queue" ]; echo $?)"
  stop_fixture "$home"
}

scenario_slow_assembly() {
  local home="$SCRATCH/home-slow" out pids pid real_jq started elapsed rc left=0
  note "== scenario: page assembly that never finishes is bounded and harmless"
  start_fixture "$home" "$HARNESS/store.pr.json" || return
  seed_pr_record "$home"
  real_jq=$(command -v jq)
  cat > "$home/fakebin/jq" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -s ] && [ "\${2:-}" = . ] && [[ "\${3:-}" == */pages.* ]]; then
  sleep 30 &
  printf '%s\n' "\$!" >> "$home/assembly-pids"
  wait
fi
exec "$real_jq" "\$@"
SH
  chmod +x "$home/fakebin/jq"
  cp "$home/data/delivery/contributions.json" "$home/prior.json"
  started=$(date +%s)
  out=$(run_product "$home" "$ROOT/bin/fm-contributions.sh" poll); rc=$?
  elapsed=$(( $(date +%s) - started ))
  check "the poll returns successfully with a hung assembly" "$rc"
  check "the hung assembly was actually attempted" "$([ -s "$home/assembly-pids" ]; echo $?)"
  check "the whole poll returns inside the five-second read bound plus setup ($elapsed s < 15 s)" \
    "$([ "$elapsed" -lt 15 ]; echo $?)"
  say_poll "$out"
  check "a slow assembly is budget refusal, not a forge failure" "$([ -z "$out" ]; echo $?)"
  cmp -s "$home/prior.json" "$home/data/delivery/contributions.json"; rc=$?
  check "the slow assembly leaves the prior observation untouched" "$rc"
  check "no wake was queued by the timed-out assembly" \
    "$([ ! -s "$home/state/.wake-queue" ]; echo $?)"
  sleep 0.5
  for pid in $(cat "$home/assembly-pids" 2>/dev/null); do
    kill -0 "$pid" 2>/dev/null && left=$((left + 1))
  done
  check "the bound killed the assembly it owns (children left running: $left)" \
    "$([ "$left" = 0 ]; echo $?)"
  stop_fixture "$home"
}

scenario_prefix_regression() {
  local home="$SCRATCH/home-prefix" out record rc
  note "== scenario: the pre-change script fails on the same real gh 2.45.0 CLI"
  start_fixture "$home" "$HARNESS/store.pr.json" real \
    "${GH_245_BIN:?real gh 2.45 binary required}" || return
  seed_pr_record "$home"
  out=$(run_product "$home" "$SCRATCH/base_pre/bin/fm-contributions.sh" poll)
  record="$home/data/delivery/contributions.json"
  say_poll "$out"
  if say_unavailable "$out"; then ok "the pre-change script reports the read unavailable"; else
    bad "the pre-change script did not disclose the refused read"; fi
  jq -e '.records[0].error != null' "$record" >/dev/null; rc=$?
  check "the pre-change record is left unmeasured with an error" "$rc"
  check "the pre-change poll surfaces no maintainer wake" \
    "$([ "$(wake_lines "$out")" = 0 ]; echo $?)"
  preserve "$home" artifact-pre-change-failure
  stop_fixture "$home"
}

scenario_pr_poll
scenario_dedupe_ack
scenario_issue_poll
scenario_modern_gh
scenario_gh_245_binary
scenario_registered_check
scenario_malformed_page
scenario_slow_assembly
scenario_prefix_regression

note "== totals: $PASSED assertions passed, $FAILED failed"
[ "$FAILED" = 0 ]
