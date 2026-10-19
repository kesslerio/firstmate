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
    printf 'launch_pid=%s\nlaunch_start=%s\n' "$child" "$(ps -p "$child" -o lstart= | awk '{$1=$1;print}')" >> "$lab/.fm-live-lab"
  fi
  before=$(cksum "$lab/.fm-live-lab")
  rc=0
  out=$(PS_COUNT="$TMP_ROOT/count-$point" PS_FAIL_AT="$point" PATH="$TMP_ROOT/tools:$PATH" "$ROOT/bin/fm-live-lab.sh" down "$lab" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "failed observation $point authorized teardown"
  assert_contains "$out" 'cleanup unverified' 'observation error must be explicit'
  assert_equals "$before" "$(cksum "$lab/.fm-live-lab")" 'unverified cleanup retains ownership record'
  assert_equals preserved "$(cat "$lab/home/state/sentinel")" 'unverified cleanup retains home data'
  if [ "$point" -le 2 ]; then kill -0 "$child" || fail 'unverified discovery signalled the root'; fi
  kill -0 "$foreign" || fail 'observation failure signalled a foreign process'
  PS_COUNT="$TMP_ROOT/count-$point" PS_FAIL_AT=0 PATH="$TMP_ROOT/tools:$PATH" "$ROOT/bin/fm-live-lab.sh" down "$lab" >/dev/null
  assert_absent "$lab" 'successful observation permits owned teardown'
  if [ "$point" -le 3 ]; then wait "$child" 2>/dev/null || true; fi
done
pass 'initial, refresh, verification and final observation failures retain lab authority and data'
