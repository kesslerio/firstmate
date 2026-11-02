#!/usr/bin/env bash
# Live drive: authority boundaries around the pool declaration itself.
set -u
REPO=${REPO:?set REPO to the checkout under test}
ROOT=$(mktemp -d /tmp/fm-lab.XXXXXX)
cleanup() { rm -rf "$ROOT" 2>/dev/null; }
trap cleanup EXIT
"$REPO/bin/fm-lab-home.sh" create "$ROOT" >/dev/null
printf 'tmux\n' > "$ROOT/config/backend"

seats() {
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$ROOT" "$REPO/bin/fm-fleet-seats.sh" "$@"
}
spawn() {
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_BACKEND=tmux FM_HOME="$ROOT" "$REPO/bin/fm-spawn.sh" "$@" 2>&1
}

echo "LAB_ROOT=$ROOT"
echo
echo '=== scenario H1: a malformed pool declaration refuses admission instead of counting seats free'
echo 'config/fleet-seats names one model in two pools (the schema forbids it)'
printf '{"pools":[{"name":"pa","capacity":2,"models":["pool-model-a"]},{"name":"pb","capacity":2,"models":["pool-model-a"]}]}\n' \
  > "$ROOT/config/fleet-seats"
sleep 600 >/dev/null 2>&1 &
HOLDER=$!
seats reserve probe --generation g-probe --harness claude --model pool-model-a --holder-pid "$HOLDER" 2>&1
echo "reserve exit=$?"
spawn probe /tmp --mode local-only --yolo off --harness claude --model pool-model-a 2>&1 | grep -v '^●' | tail -3
echo
echo '=== scenario H2: an unreadable declaration (symlink) is refused'
rm -f "$ROOT/config/fleet-seats"
printf '{"pools":[]}\n' > "$ROOT/config/elsewhere"
ln -s "$ROOT/config/elsewhere" "$ROOT/config/fleet-seats"
seats reserve probe --generation g-probe --harness claude --model pool-model-a --holder-pid "$HOLDER" 2>&1
echo "reserve exit=$?"
kill "$HOLDER" 2>/dev/null
echo
echo '=== scenario H3: removing the declaration returns the home to uncapped launches'
rm -f "$ROOT/config/fleet-seats" "$ROOT/config/elsewhere"
mkdir -p "$ROOT/data/plain"
printf '# Task\n## Captain'"
"'s intent\nPlain launch.\n\n## Firstmate spec\nNothing.\n' > "$ROOT/data/plain/brief.md"
echo '$ fm-spawn.sh plain <nonexistent project> --mode local-only --yolo off --harness claude'
echo '(no --model and no pool declaration: the seat guard is inert, so the spawn reaches its brief/project work)'
spawn plain /tmp/fm-no-such-project --mode local-only --yolo off --harness claude 2>&1 | grep -v '^●' | tail -4
