#!/usr/bin/env bash
# Live drive of the fleet seat pool contract in disposable lab homes.
# Every command below is the real product (bin/fm-spawn.sh, bin/fm-fleet-seats.sh)
# against a marked lab home minted by bin/fm-lab-home.sh; the only fixtures are
# disposable homes, a throwaway git project, and task/registry records.
set -u
REPO=${REPO:?set REPO to the checkout under test}
ROOT=$(mktemp -d /tmp/fm-lab.XXXXXX)
MATE=$(mktemp -d /tmp/fm-lab.XXXXXX)
PROJ=$(mktemp -d /tmp/fm-lab-proj.XXXXXX)
cleanup() { rm -rf "$ROOT" "$MATE" "$PROJ" /tmp/fm-* 2>/dev/null; }
trap cleanup EXIT

"$REPO/bin/fm-lab-home.sh" create "$ROOT" >/dev/null
"$REPO/bin/fm-lab-home.sh" create "$MATE" >/dev/null
mkdir -p "$ROOT/tmux"
printf 'tmux\n' > "$ROOT/config/backend"
printf '{"pools":[{"name":"pa","capacity":1,"models":["pool-model-a"]},{"name":"pb","capacity":1,"models":["pool-model-b"]}]}\n' \
  > "$ROOT/config/fleet-seats"

# A local second mate home whose parent binding leads to this lab root.
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$ROOT" > "$MATE/.fm-secondmate-parent"
printf 'mate1\n' > "$MATE/.fm-secondmate-home"
printf -- '- mate1 - Lab second mate. (home: %s; scope: lab; projects: ; added 2026-11-02)\n' "$MATE" \
  >> "$ROOT/data/secondmates.md"

# Throwaway project the spawns would target.
cd "$PROJ" || exit 1
git init -qb main
printf 'lab\n' > README.md
git add -A
git -c user.email=lab@example.invalid -c user.name=lab commit -qm init
cd "$REPO" || exit 1

spawn() { # <home> <id> <model> [project]
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_BACKEND=tmux TMUX_TMPDIR="$ROOT/tmux" FM_HOME="$1" \
    "$REPO/bin/fm-spawn.sh" "$2" "${4:-$PROJ}" --mode local-only --yolo off --harness claude --model "$3" 2>&1
  echo "exit=$?"
}
seats() { # <home> <args...>
  local home=$1; shift
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$home" "$REPO/bin/fm-fleet-seats.sh" "$@"
}

echo "LAB_ROOT=$ROOT"
echo "LAB_MATE=$MATE"
echo 'pools: pa=[pool-model-a] capacity 1, pb=[pool-model-b] capacity 1'
echo
echo '=== scenario C: a pooled record in a local second mate home spends the fleet root seat'
printf 'kind=ship\nmodel=pool-model-a\nharness=pi\n' > "$MATE/state/legacy.meta"
echo '-- spawn from the SECOND MATE home on pool-model-a (root pool is full because the mate home holds its seat)'
spawn "$MATE" mate-task pool-model-a
echo
echo '-- spawn from the ROOT home on the same pool'
spawn "$ROOT" root-task pool-model-a
echo
echo
echo '=== scenario D: an unresolved legacy model occupies every declared pool'
printf 'kind=ship\nharness=pi\n' > "$MATE/state/legacy.meta"
echo '-- model pool-model-b (the record names no model at all)'
spawn "$ROOT" unresolved-task pool-model-b
echo '-- model pool-model-a'
spawn "$ROOT" unresolved-task-a pool-model-a
echo
echo '-- now the legacy record names pool-model-a, so pool-model-b must be free'
printf 'kind=ship\nmodel=pool-model-a\nharness=pi\n' > "$MATE/state/legacy.meta"
spawn "$ROOT" poolb-task pool-model-b
echo
echo
echo '=== scenario E: a registered remote with no served certificate refuses admission instead of counting it free'
rm -f "$MATE/state/legacy.meta"
printf -- '- mate2 - Lab remote mate. (host: shop-host; root: /code; home: /srv/mate; scope: lab; projects: ; added 2026-11-02)\n' \
  >> "$ROOT/data/secondmates.md"
sleep 600 >/dev/null 2>&1 &
HOLDER=$!
echo '-- an otherwise free pool, but the registered remote has never been served'
env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$ROOT" \
  "$REPO/bin/fm-fleet-seats.sh" reserve free-task --generation g-free --harness claude \
  --model pool-model-a --holder-pid "$HOLDER" 2>&1
echo "exit=$?"
echo
echo '-- the operator removes the unreachable remote registration'
sed -i '/^- mate2 - Lab remote mate/d' "$ROOT/data/secondmates.md"
env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$ROOT" \
  "$REPO/bin/fm-fleet-seats.sh" reserve free-task --generation g-free --harness claude \
  --model pool-model-a --holder-pid "$HOLDER" 2>&1
echo "exit=$?"
echo
echo
echo '=== scenario F: generation transitions free exactly the released seat'
echo '-- released generation, then a retry of that same terminal generation'
seats "$ROOT" release free-task --generation g-free --reason teardown 2>&1; echo "release exit=$?"
env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$ROOT" \
  "$REPO/bin/fm-fleet-seats.sh" reserve free-task --generation g-free --harness claude \
  --model pool-model-a --holder-pid "$HOLDER" 2>&1
echo "terminal-generation retry exit=$?"
echo
echo '-- a successor generation on the same holder is admitted on the freed seat'
env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$ROOT" \
  "$REPO/bin/fm-fleet-seats.sh" reserve free-task --generation g2 --previous-generation g-free --harness claude \
  --model pool-model-a --holder-pid "$HOLDER" 2>&1
echo "successor exit=$?"
echo
echo '-- holder record after the transitions'
seats "$ROOT" show free-task | jq -c '{task, incarnations: [.incarnations[] | {generation, previous_generation, lifecycle}]}'
kill "$HOLDER" 2>/dev/null
