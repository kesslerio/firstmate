#!/usr/bin/env bash
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
. "$ROOT/bin/fm-liveness-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-liveness-budget)
mkdir -p "$TMP_ROOT/home/state" "$TMP_ROOT/home/config" "$TMP_ROOT/bin"
printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$TMP_ROOT/bin/fm-crew-state.sh"
chmod +x "$TMP_ROOT/bin/fm-crew-state.sh"
for id in a b c; do
  printf 'kind=ship\nspawn_gen=s1.2.3\n' > "$TMP_ROOT/home/state/$id.meta"
done
FM_LIVENESS_LIB_DIR="$TMP_ROOT/bin"
started=$SECONDS
fm_liveness_snapshot "$TMP_ROOT/home" "$TMP_ROOT/home/state" 1
[ "$((SECONDS-started))" -lt 5 ] || fail 'aggregate observation exceeded its budget'
assert_equals 3 "$FM_LIVENESS_LIVE" 'unobserved workers must retain occupied seats'
assert_equals 1 "$FM_LIVENESS_FREE" 'unknown workers cannot manufacture free seats'
for id in a b c; do
  assert_contains "$FM_LIVENESS_WARNINGS" "$id: current state unknown; seat retained" 'every unobserved seat is explicit'
done
pass 'aggregate liveness deadline retains all slow and unobserved workers'
