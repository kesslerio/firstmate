#!/usr/bin/env bash
# run-live-lock-matrix.sh <tree> <label>
# Prepares a disposable scratch + marked lab home, denies the ps binary's exec
# in a private mount+user namespace, drives live-lock-matrix.sh, then removes
# the scratch. Nothing outside the scratch dir is written.
set -u
TREE=$1
LABEL=$2
EV=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCR=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-$LABEL.XXXXXX") || exit 1
mkdir -p "$SCR/bin" || exit 1
cp "$(command -v bash)" "$SCR/bin/claude" || exit 1   # a session whose comm is claude
"$TREE/bin/fm-lab-home.sh" create "$SCR/lab" >/dev/null || { echo "lab create failed" >&2; rm -rf "$SCR"; exit 1; }
cleanup() { rm -rf "$SCR"; }
trap cleanup EXIT

unshare -r -m --propagation private bash -c '
  set -u
  mount --bind /dev/null "$(command -v ps)" || { echo "ps denial failed"; exit 1; }
  bash "'"$EV"'/scripts/live-lock-matrix.sh" "'"$TREE"'" "'"$LABEL"'" "'"$SCR"'"
'
echo "SCRATCH removed: $SCR"
