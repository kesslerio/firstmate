#!/usr/bin/env bash
# Live guard for OpenCode's model axis on the installed build.
#
# bin/fm-spawn.sh resolves how a worker's model can be selected from the
# installed build's own CLI, pins a 2.x build through the worktree's project
# configuration, and asserts the model its worker actually ran. All of that
# depends on vendor surface no fixture can prove, so this guard exercises the
# real installed OpenCode and fails naming it and its version.
#
# It spends a model turn on the host's already-configured providers, so it is
# opt-in.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_OPENCODE_MODEL_LIVE opencode jq tmux

OPENCODE_BIN=$(command -v opencode) || fail "opencode resolved by the gate but not on PATH"
case "$OPENCODE_BIN" in
  /*) ;;
  *) OPENCODE_BIN="$(cd "$(dirname "$OPENCODE_BIN")" && pwd)/$(basename "$OPENCODE_BIN")" ;;
esac
QUOTED_OPENCODE_BIN="'${OPENCODE_BIN//\'/\'\\\'\'}'"
VERSION=$("$OPENCODE_BIN" --version 2>/dev/null | head -1) || VERSION=
[ -n "$VERSION" ] || fail "opencode ($OPENCODE_BIN) reported no version"
printf 'ok - installed opencode (%s): %s\n' "$VERSION" "$OPENCODE_BIN"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-opencode-model-live.XXXXXX") || fail "could not create a lab directory"
TMUX_SOCKET=
cleanup() {
  [ -z "$TMUX_SOCKET" ] || tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

fail_named() {
  printf 'not ok - opencode (%s): %s\n' "$VERSION" "$1" >&2
  exit 1
}

# The model a session recorded for one directory, in provider/model form, read
# the same way bin/fm-spawn.sh's assertion reads it.
session_model_for() {  # <dir>
  local dir=$1 sid
  sid=$(cd "$dir" && "$OPENCODE_BIN" session list --standalone --format json 2>/dev/null \
    | jq -r --arg d "$dir" '[.[] | select(.directory == $d)] | sort_by(.updated // 0) | reverse | .[0].id // empty') || return 1
  [ -n "$sid" ] || return 1
  (cd "$dir" && "$OPENCODE_BIN" session export "$sid" --standalone 2>/dev/null) \
    | jq -r '[.messages[]? | select(.type == "assistant" and .model != null and ((.model.providerID // "") != "") and ((.model.id // "") != "")) | .model] | .[0] | if type == "object" then "\(.providerID)/\(.id)" else empty end' 2>/dev/null
}

wait_for_session_model() {  # <dir> <seconds>
  local dir=$1 limit=$2 i=0 model=
  while [ "$i" -lt "$limit" ]; do
    model=$(session_model_for "$dir") || model=
    if [ -n "$model" ]; then
      printf '%s\n' "$model"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# The requested model is chosen from what this build installs, so it is a real
# catalog id rather than a guess. The free tier is skipped because it
# authenticates through the resident service this guard deliberately does not
# own, and a provider this host runs itself is preferred over a remote one.
CANDIDATES=$(
  {
    "$OPENCODE_BIN" models --standalone 2>/dev/null | grep -E '^(john-remote|qualitycorp-glm|ollama-cloud)/'
    "$OPENCODE_BIN" models --standalone 2>/dev/null
  } | awk '!seen[$0]++' | grep -v -E '^opencode/.*-free$'
)
[ -n "$CANDIDATES" ] || fail_named "'opencode models' listed no usable model, so the pin cannot be exercised"

PIN_DIR=
REQUESTED=
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  probe="$LAB/probe-$(printf '%s' "$candidate" | tr '/#' '--')"
  mkdir -p "$probe/.opencode"
  printf '{"model":{"providerID":"%s","model":"%s"}}\n' "${candidate%%/*}" "${candidate#*/}" \
    >"$probe/.opencode/opencode.jsonc"
  parsed=$(cd "$probe" && "$OPENCODE_BIN" debug config 2>/dev/null \
    | jq -r --arg p "$probe/.opencode/opencode.jsonc" '[.[] | select(.path == $p) | .info.model] | .[0] | if type == "object" then "\(.providerID)/\(.model)" else empty end' 2>/dev/null)
  if [ "$parsed" = "$candidate" ]; then
    REQUESTED=$candidate
    PIN_DIR=$probe
    break
  fi
done <<EOF
$CANDIDATES
EOF
[ -n "$REQUESTED" ] || fail_named "no installed model was reported back through 'opencode debug config', so the model pin cannot be exercised"
printf 'ok - opencode (%s): the build parses the pinned model selection (requested=%s)\n' "$VERSION" "$REQUESTED"

# The real launch shape: the worktree project configuration bin/fm-spawn.sh
# writes, the unchanged permission grant it passes, and a standalone TUI in a
# pane so plugin and environment ownership cannot escape to a shared service.
TMUX_SOCKET="fm-opencode-model-live-$$"
tmux -L "$TMUX_SOCKET" new-session -d -s pinned -x 160 -y 48 -c "$PIN_DIR" \
  || fail_named "could not start a tmux pane for the launch probe"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t pinned \
  "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' $QUOTED_OPENCODE_BIN --standalone --prompt 'Reply with exactly: MODEL_PIN_PROBE'" Enter

OBSERVED=$(wait_for_session_model "$PIN_DIR" 90) \
  || fail_named "the launched worker recorded no readable model within 90s (requested '$REQUESTED')"
[ "$OBSERVED" = "$REQUESTED" ] \
  || fail_named "the launched worker ran '$OBSERVED' instead of the requested '$REQUESTED'"
printf 'ok - opencode (%s): a real TUI launch ran the requested model (requested=%s observed=%s)\n' \
  "$VERSION" "$REQUESTED" "$OBSERVED"
