#!/usr/bin/env bash
# stat-triple-matrix.sh <tree>
# Drives the real bin/fm-session-lock-lib.sh fm_linux_stat_triple parser from
# <tree> over a fixed /proc stat-line matrix and prints rc + parsed triple, so
# two trees can be diffed for parse parity (this is the code path the lint fix
# renamed a local array in).
set -u
TREE=$1
# shellcheck source=/dev/null
. "$TREE/bin/fm-session-lock-lib.sh"

lines=(
  '1234 (claude) S 1000 1234 1234 0 -1 4194304 1 2 3 4 5'
  '1234 (cl aude) S 1000 1234 1234 0 -1 4194304'
  '1234 (a)b) S 1000 1234 1234 0 -1 4194304'
  '1234 (José) S 1000 1234 1234 0 -1 4194304'
  '1234 (agent) S    1000   1234    1234 0 -1'
  '1234 (claude) S'
  '1234 (claude) S 1000 abc 1234'
  '1234 (claude) S 1000'
  'no-parens-here'
  '1234 (claude) S xyz 1234'
  '1234 (claude) S  1234 4321 1234'
)

i=0
for line in "${lines[@]}"; do
  i=$((i + 1))
  if triple=$(fm_linux_stat_triple "$line" 'claude --resume'); then
    printf 'case%d rc=0 triple=[%s]\n' "$i" "$triple"
  else
    printf 'case%d rc=1 triple=[]\n' "$i"
  fi
done

# The args sanitizer shares the same byte rule; drive it identically.
printf 'args-utf8=[%s]\n' "$(fm_linux_stat_triple '1 (x) S 0 1 1' "$(printf 'caf\303\251\nctl\001end')")"
