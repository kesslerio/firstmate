#!/usr/bin/env bash
# Drive the real watcher over a home that opts into record hygiene and holds an
# orphan status log, proving the upstream record-hygiene heartbeat block still
# surfaces its check wake after the rebase.
# Usage: drive-record-hygiene.sh <repo-root> <evidence-out-dir>
set -u
ROOT=$(cd "$1" && pwd)
OUT=$(cd "$2" && pwd)
D=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-hygiene.XXXXXX")
INERT=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-inert.XXXXXX")
trap 'rm -rf "$D" "$INERT"' EXIT
mkdir -p "$D"/{data,config,state}
cat > "$D/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
printf '## In flight\n\n## Queued\n\n## Done\n' > "$D/data/backlog.md"
: > "$D/config/record-hygiene"
# A metadata record with no window line is a reportable hygiene finding and,
# unlike an orphan .status log, does not also trigger the signal wake path.
printf 'kind=ship\nbackend=tmux\npr=https://example.test/pull/1\n' > "$D/state/hygiene.meta"
printf 'kind=ship\nbackend=tmux\npr=https://example.test/pull/1\n' > "$D/state/hygiene2.meta"

PATH="$PATH" FM_HOME="$D" FM_STATE_OVERRIDE="$D/state" FM_CONFIG_OVERRIDE="$D/config" \
  FM_ROOT_OVERRIDE="$INERT" FM_POLL=0.2 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
  FM_RECORD_HYGIENE_TIMEOUT=30 \
  timeout 90 "$ROOT/bin/fm-watch.sh" > "$D/watch.stdout" 2>"$D/watch.stderr"
rc=$?
{
  echo "=== record-hygiene check wake (posture=attended, config/record-hygiene present)"
  echo "watcher-exit: $rc"
  echo "watcher-stdout: $(cat "$D/watch.stdout")"
  echo "wake-queue-rows: $(tr '\n' ';' < "$D/state/.wake-queue" 2>/dev/null)"
  echo "hygiene-last: $(cat "$D/state/.record-hygiene-last" 2>/dev/null)"
  echo "hygiene-meta-reportable: $([ -e "$D/state/orphan.status" ] && echo yes || echo no)"
  echo "watcher-stderr: $(tail -3 "$D/watch.stderr" 2>/dev/null | tr '\n' ';')"
} | tee "$OUT/record-hygiene-check.txt"
