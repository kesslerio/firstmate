#!/usr/bin/env bash
# tests/fm-session-lock-ps-denied.test.sh - the ps-free identity route.
#
# An EDR-style policy can deny the ps BINARY's exec (verified on a hardened
# macOS host: /bin/ps refused even `ps -V`, while kill/head/sysctl/pgrep/lsof
# ran), and before bin/fm-session-lock-lib.sh could fall back to an OS
# provider, that turned every session into a permanent lock-refused
# read-only one, because identity proof walked ancestry through ps.
#
# The unit cases drive the library behind a deterministic fake ps that
# refuses to run (exit 126, bash's refused-exec status) plus a fake OS
# provider, covering the fallback decision table on any host. The e2e case
# blocks ps from a REAL process tree (fake ps on PATH) and resolves a real
# pid through the REAL platform provider, so a regression that only fakes
# would miss is caught here.
# shellcheck disable=SC2016 # single quotes are deliberate where they expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ps-denied)

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# A denied ps: refuses to run at all, exactly like the blocked binary.
make_denied_ps() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
echo "$0: Operation not permitted" >&2
exit 126
SH
  chmod +x "$fakebin/ps"
}

# Run one library expression with a denied ps shadowing PATH and a table
# provider. The table reads FM_TEST_TRIPLE_N records (fake table rows
# "<pid>|<ppid>|<comm>|<args>"); a pid absent from the table is unreadable,
# which is how a dead pid behaves. FM_TEST_KILL_RC decides kill as before.
# CLAUDE identity envs are scrubbed the same way the ancestry suite scrubs
# them, so a suite running inside a real Claude session cannot leak in.
lib_eval_denied() {  # <fakebin> <provider-table-file> <expression>
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_PROVIDER_FILE="$2" PATH="$1:$PATH" bash -c "
    . \"\$0\"
    kill() { return \${FM_TEST_KILL_RC:-0}; }
    _emit_row() {  # <row>
      local ppid rest comm args
      ppid=\${1#*|}; ppid=\${ppid%%|*}
      rest=\${1#*|}; rest=\${rest#*|}
      comm=\${rest%%|*}
      args=\${rest#*|}
      printf '%s\t%s\t%s\n' \"\$ppid\" \"\$comm\" \"\$args\"
    }
    fm_os_proc_triple() {
      local row
      while IFS= read -r row; do
        case \"\$row\" in
          \"\$1|\"*) _emit_row \"\$row\"; return 0 ;;
        esac
      done < \"\$FM_PROVIDER_FILE\"
      while IFS= read -r row; do
        case \"\$row\" in
          \"default|\"*) _emit_row \"\$row\"; return 0 ;;
        esac
      done < \"\$FM_PROVIDER_FILE\"
      return 1
    }
    $3
  " "$LIB"
}

make_table() {  # a version-free claude session at 700, under launchd; any
  # other pid (the child bash the walk starts from) reports bash -> 700.
  # Args stay neutral: a real-looking bash -c command naming python3 and a
  # lib path would be matched as "interpreter running a harness script",
  # which is the matcher being honest, not a bug.
  local file="$TMP_ROOT/table.$$"
  cat > "$file" <<'ROWS'
700|1|claude|claude --resume
1|0|launchd|/sbin/launchd
default|700|bash|bash run.sh
ROWS
  printf '%s\n' "$file"
}

# --- the fallback decision table ---------------------------------------------

test_denied_ps_still_finds_the_harness() {
  local dir fakebin table got
  dir="$TMP_ROOT/denied-found"
  fakebin=$(fm_fakebin "$dir"); make_denied_ps "$fakebin"
  table=$(make_table)
  got=$(lib_eval_denied "$fakebin" "$table" 'fm_harness_ancestry_pid') \
    || fail "with ps denied, the walk found no harness at all"
  [ "$got" = 700 ] \
    || fail "with ps denied, the walk resolved '$got', expected 700"
  lib_eval_denied "$fakebin" "$table" 'fm_harness_pid_alive 700' \
    || fail "with ps denied, a live harness was not recognized"
  pass "ps denied: ancestry and liveness still resolve through the OS provider"
}

test_denied_ps_without_provider_fails_closed() {
  local dir fakebin empty got
  dir="$TMP_ROOT/denied-noprovider"
  fakebin=$(fm_fakebin "$dir"); make_denied_ps "$fakebin"
  empty="$dir/empty-table"; : > "$empty"
  if got=$(lib_eval_denied "$fakebin" "$empty" 'fm_harness_ancestry_pid' 2>&1); then
    fail "with ps denied and no provider data, the walk still printed: $got"
  fi
  pass "ps denied with no provider data: the walk refuses, it never guesses"
}

test_denied_ps_rejects_a_foreign_chain() {
  local dir fakebin file got
  dir="$TMP_ROOT/denied-foreign"
  fakebin=$(fm_fakebin "$dir"); make_denied_ps "$fakebin"
  file="$dir/table"
  cat > "$file" <<'ROWS'
default|700|bash|bash run-task.sh
700|1|bash|bash outer.sh
1|0|launchd|/sbin/launchd
ROWS
  got=$(lib_eval_denied "$fakebin" "$file" 'fm_harness_ancestry_pid' 2>&1) && rc=0 || rc=1
  if [ "$rc" -eq 0 ]; then
    fail "an ancestry with no harness anywhere was still reported as one: $got"
  fi
  pass "ps denied: a chain containing no harness is still no harness"
}

test_ps_primary_never_touches_the_provider() {
  # The regression this guards: the fallback must stay dead code wherever
  # ps works, so identity behavior cannot drift for every working session.
  local dir fakebin marker table
  dir="$TMP_ROOT/ps-primary"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  700:comm=) printf '%s\n' 'claude' ;;
  700:args=) printf '%s\n' 'claude --resume' ;;
  700:ppid=) printf '%s\n' 1 ;;
  1:comm=) printf '%s\n' 'launchd' ;;
  1:args=) printf '%s\n' '/sbin/launchd' ;;
  1:ppid=) printf '%s\n' 0 ;;
  *:comm=) printf '%s\n' 'bash' ;;
  *:args=) printf '%s\n' 'bash run.sh' ;;
  *:ppid=) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  marker="$dir/provider-was-called"; : > "$marker"
  table="$dir/t"; : > "$table"
  # Provider override records any call by writing to the marker file.
  env PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    fm_os_proc_triple() { : > \"\$FM_MARKER_FILE\"; return 1; }
    fm_harness_ancestry_pid >/dev/null || exit 3
  " "$LIB" || fail "the ps-primary walk itself failed"
  [ ! -s "$marker" ] \
    || fail "with a working ps the provider was still consulted"
  pass "ps works: the fallback provider is never consulted"
}

# --- end-to-end: a real tree with a blocked ps -------------------------------

# Build a real parent/child tree: a parent process NAMED claude (a bash
# symlink), a child shell whose PATH shadows ps with a denied stub, running
# the real platform provider against real pids.
test_e2e_real_tree_with_blocked_ps() {
  local dir fakebin path_with_shim named
  dir="$TMP_ROOT/e2e-blocked"
  fakebin=$(fm_fakebin "$dir"); make_denied_ps "$fakebin"

  # Real python3 stays reachable for the Darwin provider while ps is blocked:
  # the provider looks python3 up on PATH, so a shim forwards only python3
  # and ps is shadowed by the denied stub.
  path_with_shim="$fakebin"
  if command -v python3 >/dev/null 2>&1; then
    local shimdir="$dir/shim"; mkdir -p "$shimdir"
    printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$(command -v python3)" > "$shimdir/python3"
    chmod +x "$shimdir/python3"
    path_with_shim="$fakebin:$shimdir:/usr/bin:/bin:/usr/sbin:/sbin"
  fi

  named="$dir/bin"; mkdir -p "$named"
  ln -s /bin/bash "$named/claude"

  # The child resolves the anchor for its real named parent through the
  # REAL platform provider with a blocked ps. The parent stays alive until
  # the child is done, so the real chain exists for the whole walk.
  cat > "$dir/child.sh" <<CHILD
#!/usr/bin/env bash
set -u
. "\$1"
anchor=\$(fm_session_lock_anchor_pid) || { echo anchor-failed; exit 1; }
printf '%s\n' "\$anchor"
CHILD
  chmod +x "$dir/child.sh"

  "$named/claude" -c '
    set -u
    pidfile=$1; child=$2; path=$3; lib=$4
    printf "%s\n" "$$" > "$pidfile"
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID PATH="$path" \
      /bin/bash "$child" "$lib" > "$pidfile.anchor" 2>&1 &
    childpid=$!
    i=0
    while [ ! -s "$pidfile.anchor" ] && [ "$i" -lt 60 ]; do
      sleep 0.25; i=$((i + 1))
    done
    kill "$childpid" 2>/dev/null || true
    wait "$childpid" 2>/dev/null || true
  ' x "$dir/parent.pid" "$dir/child.sh" "$path_with_shim" "$LIB"

  local want got2
  want=$(cat "$dir/parent.pid") || fail "e2e: the named parent did not record its pid"
  got2=$(cat "$dir/parent.pid.anchor") \
    || fail "e2e: no anchor output from the child"
  [ "$got2" = "$want" ] \
    || fail "e2e blocked ps: child resolved '$got2', expected the real named-parent pid $want"
  pass "e2e blocked ps: the real platform provider identified a real harness tree"
}

test_procinfo_helper_reports_real_facts() {
  # Direct contract of bin/fm-procinfo.py on macOS (and the offsets it
  # self-verifies): for a real parent/child pair, ppid must be exact.
  [ "$(uname -s)" = Darwin ] || { pass "fm-procinfo.py: macOS-only, skipped"; return; }
  command -v python3 >/dev/null 2>&1 || { pass "fm-procinfo.py: python3 absent, skipped"; return; }
  sleep 30 &
  local child=$! out ppid comm
  out=$(python3 "$ROOT/bin/fm-procinfo.py" "$child") \
    || { kill "$child" 2>/dev/null; fail "fm-procinfo.py failed for a live pid"; }
  kill "$child" 2>/dev/null
  ppid=${out%%$'\t'*}
  comm=$(printf '%s' "$out" | cut -f2)
  [ "$ppid" = "$$" ] \
    || fail "fm-procinfo.py reported ppid '$ppid', expected $$"
  case "$comm" in */sleep) ;; *) fail "fm-procinfo.py reported comm '$comm', expected a sleep path" ;; esac
  pass "fm-procinfo.py: ppid and exec path verified against a real process"
}

test_denied_ps_still_finds_the_harness
test_denied_ps_without_provider_fails_closed
test_denied_ps_rejects_a_foreign_chain
test_ps_primary_never_touches_the_provider
test_e2e_real_tree_with_blocked_ps
test_procinfo_helper_reports_real_facts

echo "ALL PASS"
