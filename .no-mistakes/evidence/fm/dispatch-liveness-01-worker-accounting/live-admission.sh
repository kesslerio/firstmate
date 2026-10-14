set -euo pipefail
export TMPDIR="$PWD/.test-phase/tmp"
. tests/fixtures.sh
home="$PWD/.test-phase/live-home"
project="$home/project"
mkdir -p "$project" "$home/user-home"
git -C "$project" init -q
fm_git_identity lab lab@example.invalid
printf 'local fixture\n' > "$project/README.md"
git -C "$project" add README.md
git -C "$project" -c commit.gpgsign=false commit --allow-empty -qm 'Local validation fixture'
fm_test_spawn_brief "$home" extra
export FM_HOME="$home" FM_GUARD_READ_ONLY=1 HERDR_CONFIG_PATH="$PWD/.test-phase/herdr/config.toml"
bin/fm-afk-contract.sh propose --words 'local validation only' --spend 1 >/dev/null
bin/fm-afk-contract.sh confirm >/dev/null
before=$(find "$home/state" -name '*.meta' -exec cksum {} \; | sort)
set +e
CODEX_HOME="$home/user-home" CLAUDE_CONFIG_DIR="$home/user-home" bin/fm-spawn.sh extra "$project" --mode local-only --yolo off --harness codex --backend herdr > "$home/admission-output" 2>&1
rc=$?
set -e
cat "$home/admission-output"
printf 'spawn exit=%s\n' "$rc"
[ "$rc" != 0 ]
rg -q 'caps concurrent workers at 1' "$home/admission-output"
[ "$before" = "$(find "$home/state" -name '*.meta' -exec cksum {} \; | sort)" ]
[ ! -e "$home/state/extra.meta" ]
printf 'real cap denial occurred before endpoint and task publication\n'
