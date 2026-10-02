#!/usr/bin/env bash
set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
ROOT=$PWD
CASE="$ROOT/.test-phase/manual"
PROJ="$CASE/project"
WT="$CASE/pool/slot/repo"
STORE="$CASE/store"
mkdir -p "$PROJ" "$STORE" "$CASE/pool/slot"
git -C "$PROJ" init -q
printf 'fixture\n' > "$PROJ/file.txt"
git -C "$PROJ" add file.txt
git -C "$PROJ" -c user.name='Trust Lab' -c user.email='trust-lab@example.invalid' -c commit.gpgsign=false commit -qm fixture
git -C "$PROJ" worktree add -q -b allowed "$WT"
printf '{}\n' > "$CASE/pool/treehouse-state.json"
cat > "$STORE/config.toml" <<EOF
model_reasoning_effort = "high"
[projects."/unrelated/operator/project"]
trust_level = "trusted"
EOF
printf '\n=== Register a linked pool worktree ===\n'
CODEX_HOME="$STORE" bin/fm-codex-trust.sh "$WT" "$PROJ"
python3 - "$STORE/config.toml" "$PROJ" <<'PY'
import sys, tomllib
from pathlib import Path
config = tomllib.loads(Path(sys.argv[1]).read_text())
assert config['projects'][sys.argv[2]]['trust_level'] == 'trusted'
assert config['projects']['/unrelated/operator/project']['trust_level'] == 'trusted'
assert config['model_reasoning_effort'] == 'high'
assert set(config) == {'model_reasoning_effort', 'projects'}, config
print('Saved repository trust; preserved operator project and effort; no hook-trust state.')
PY
BEFORE=$(sha256sum "$STORE/config.toml")
CODEX_HOME="$STORE" bin/fm-codex-trust.sh "$WT" "$PROJ"
[ "$BEFORE" = "$(sha256sum "$STORE/config.toml")" ]
printf 'Repeat registration leaves the configuration byte-identical.\n'
mkdir -p "$WT/subdirectory" "$CASE/plain"
git -C "$PROJ" worktree add -q -b outside "$CASE/outside"
for TARGET in "$PROJ" "$CASE/outside" "$WT/subdirectory" "$CASE/plain"; do
  printf '\n=== Refuse %s ===\n' "$TARGET"
  if CODEX_HOME="$STORE" bin/fm-codex-trust.sh "$TARGET" "$PROJ"; then
    printf 'ERROR: unexpectedly accepted target\n'; exit 1
  fi
  [ "$BEFORE" = "$(sha256sum "$STORE/config.toml")" ]
  printf 'Refused with existing trust configuration byte-identical.\n'
done
printf '\n=== Refuse an existing operator denial ===\n'
mkdir -p "$CASE/denied-store"
printf '[projects."%s"]\ntrust_level = "untrusted"\n' "$PROJ" > "$CASE/denied-store/config.toml"
DENIED_BEFORE=$(sha256sum "$CASE/denied-store/config.toml")
if CODEX_HOME="$CASE/denied-store" bin/fm-codex-trust.sh "$WT" "$PROJ"; then
  printf 'ERROR: unexpectedly overwrote operator denial\n'; exit 1
fi
[ "$DENIED_BEFORE" = "$(sha256sum "$CASE/denied-store/config.toml")" ]
printf 'Operator denial preserved byte-identically.\n'
printf '\n=== Refuse malformed configuration ===\n'
mkdir -p "$CASE/malformed-store"
printf 'this = [not valid toml\n' > "$CASE/malformed-store/config.toml"
MALFORMED_BEFORE=$(sha256sum "$CASE/malformed-store/config.toml")
if CODEX_HOME="$CASE/malformed-store" bin/fm-codex-trust.sh "$WT" "$PROJ"; then
  printf 'ERROR: unexpectedly accepted malformed store\n'; exit 1
fi
[ "$MALFORMED_BEFORE" = "$(sha256sum "$CASE/malformed-store/config.toml")" ]
printf 'Malformed configuration preserved byte-identically.\n'
