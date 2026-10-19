#!/usr/bin/env bash
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-lab-observation)
FM_TEST_CHILD_REGISTRY="$TMP_ROOT/children"
export FM_TEST_CHILD_REGISTRY
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/tools"
export HOME="$TMP_ROOT/home"
REAL_PS=$(command -v ps)
export REAL_PS
cat > "$TMP_ROOT/tools/ps" <<'PS'
#!/usr/bin/env bash
if [ "${1:-}" = -axo ]; then
  count=$(cat "$PS_COUNT" 2>/dev/null || echo 0)
  count=$((count+1))
  echo "$count" > "$PS_COUNT"
  "$REAL_PS" "$@"
  [ "$count" != "$PS_FAIL_AT" ] || exit 1
else
  exec "$REAL_PS" "$@"
fi
PS
chmod +x "$TMP_ROOT/tools/ps"
sleep 30 & foreign=$!
fm_test_track_child "$foreign"
for point in 1 2 3 9 10; do
  lab="$TMP_ROOT/lab-$point"
  mkdir -p "$lab/home/state"
  : > "$lab/.treehouse-before"
  printf preserved > "$lab/home/state/sentinel"
  cat > "$lab/.fm-live-lab" <<EOF
fm-live-lab v1
home=$lab/home
pi_trust=absent
pi_trust_store=$HOME/absent-pi
claude_store=$HOME/absent-claude
treehouse_dir=$HOME/absent-treehouse
EOF
  if [ "$point" -le 3 ]; then
    sleep 30 & child=$!
    fm_test_track_child "$child"
    printf 'launch_pid=%s\nlaunch_start=%s\n' "$child" "$(LC_ALL=C TZ=UTC ps -p "$child" -o lstart= | awk '{$1=$1;print}')" >> "$lab/.fm-live-lab"
  fi
  before=$(sed '/^cleanup_/d' "$lab/.fm-live-lab" | cksum)
  rc=0
  out=$(PS_COUNT="$TMP_ROOT/count-$point" PS_FAIL_AT="$point" PATH="$TMP_ROOT/tools:$PATH" "$ROOT/bin/fm-live-lab.sh" down "$lab" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "failed observation $point authorized teardown"
  assert_contains "$out" 'cleanup unverified' 'observation error must be explicit'
  assert_equals "$before" "$(sed '/^cleanup_/d' "$lab/.fm-live-lab" | cksum)" 'unverified cleanup retains ownership record'
  assert_equals preserved "$(cat "$lab/home/state/sentinel")" 'unverified cleanup retains home data'
  if [ "$point" -le 2 ]; then kill -0 "$child" || fail 'unverified discovery signalled the root'; fi
  kill -0 "$foreign" || fail 'observation failure signalled a foreign process'
  PS_COUNT="$TMP_ROOT/count-$point" PS_FAIL_AT=0 PATH="$TMP_ROOT/tools:$PATH" "$ROOT/bin/fm-live-lab.sh" down "$lab" >/dev/null
  assert_absent "$lab" 'successful observation permits owned teardown'
  if [ "$point" -le 3 ]; then wait "$child" 2>/dev/null || true; fi
done
pass 'initial, refresh, verification and final observation failures retain lab authority and data'

lab="$TMP_ROOT/retry"
mkdir -p "$lab/home/state"
printf preserved > "$lab/home/state/sentinel"
: > "$lab/.treehouse-before"
cat > "$TMP_ROOT/root.sh" <<'SCRIPT'
trap 'exit 0' TERM
python3 - "$1" <<'PYCHILD' &
import os, pathlib, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
time.sleep(45)
PYCHILD
wait "$!"
SCRIPT
perl -e 'setpgrp(0,0); exec @ARGV' bash "$TMP_ROOT/root.sh" "$TMP_ROOT/descendant" & root_pid=$!
fm_test_track_child "$root_pid"
for ((i=0; i<200; i++)); do [ -s "$TMP_ROOT/descendant" ] && break; sleep .02; done
assert_present "$TMP_ROOT/descendant" 'owned descendant did not start'
child=$(cat "$TMP_ROOT/descendant")
fm_test_track_child "$child" kill
cat > "$lab/.fm-live-lab" <<EOF
fm-live-lab v1
home=$lab/home
pi_trust=absent
pi_trust_store=$HOME/absent-pi
claude_store=$HOME/absent-claude
treehouse_dir=$HOME/absent-treehouse
launch_pid=$root_pid
launch_start=$(LC_ALL=C TZ=UTC ps -p "$root_pid" -o lstart= | awk '{$1=$1; print}')
EOF
rc=0
out=$(PS_COUNT="$TMP_ROOT/retry-count" PS_FAIL_AT=4 PATH="$TMP_ROOT/tools:$PATH" "$ROOT/bin/fm-live-lab.sh" down "$lab" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'injected post-TERM observation failure was ignored'
wait "$root_pid" 2>/dev/null || true
kill -0 "$child" || fail 'retry fixture descendant must survive its root'
cp "$lab/.fm-live-lab" "$TMP_ROOT/verified-record"
python3 - "$TMP_ROOT/verified-record" "$child" <<'PYCHECK'
import json, pathlib, sys
lines=pathlib.Path(sys.argv[1]).read_text().splitlines()
checkpoint=json.loads(next(line.split('=',1)[1] for line in lines if line.startswith('cleanup_checkpoint=')))
assert int(sys.argv[2]) in [pair[0] for pair in checkpoint['pairs']]
PYCHECK
for fault in malformed missing changed foreign reused; do
  python3 - "$TMP_ROOT/verified-record" "$lab/.fm-live-lab" "$fault" <<'PYFAULT'
import json, pathlib, sys
source, target, fault=sys.argv[1:]
lines=pathlib.Path(source).read_text().splitlines()
for i,line in enumerate(lines):
    if line.startswith('cleanup_checkpoint='):
        data=json.loads(line.split('=',1)[1])
        if fault=='malformed': lines[i]='cleanup_checkpoint={'
        elif fault=='missing': lines.pop(i)
        elif fault=='foreign':
            data['binding']='0'*64
            lines[i]='cleanup_checkpoint='+json.dumps(data)
        elif fault=='reused':
            for pair in data['pairs']: pair[1]='Mon Jan 1 00:00:00 1990'
            lines[i]='cleanup_checkpoint='+json.dumps(data)
        break
if fault=='changed': lines.append('nonce=foreign-generation')
pathlib.Path(target).write_text('\n'.join(lines)+'\n')
PYFAULT
  before=$(cksum "$lab/.fm-live-lab")
  rc=0
  out=$("$ROOT/bin/fm-live-lab.sh" down "$lab" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "unsafe $fault checkpoint authorized cleanup"
  assert_equals "$before" "$(cksum "$lab/.fm-live-lab")" 'failed retry must retain its evidence'
  kill -0 "$child" || fail "unsafe $fault checkpoint signalled an unverified identity"
  kill -0 "$foreign" || fail "unsafe $fault checkpoint signalled a foreign process"
done
cp "$TMP_ROOT/verified-record" "$lab/.fm-live-lab"
"$ROOT/bin/fm-live-lab.sh" down "$lab" >/dev/null || fail 'fresh down lost retained descendant ownership'
assert_absent "$lab" 'successful retry should finish disposal'
case "$(ps -p "$child" -o stat= 2>/dev/null)" in ''|Z*) ;; *) fail 'retry left an owned descendant alive' ;; esac
kill -0 "$foreign" || fail 'successful retry signalled a foreign process'
pass 'checkpoint retains verified descendants across root exit, observation failure and fresh down; unsafe reloads refuse'
