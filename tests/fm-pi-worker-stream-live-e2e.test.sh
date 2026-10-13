#!/usr/bin/env bash
# Token-free live-harness guard for the generated Pi worker stream extension.
# Uses the REAL installed Pi SDK with synthetic transport and isolated homes.
# No external provider, credentials, live fleet, or primary extension is used.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate default-on FM_PI_WORKER_STREAM_LIVE node pi jq

PI_EXECUTABLE=$(command -v pi)
PI_PACKAGE_DIR=$(node -e 'const fs=require("node:fs"),p=require("node:path"); console.log(p.resolve(p.dirname(fs.realpathSync(process.argv[1])),"../.."));' "$PI_EXECUTABLE")
PI_VERSION=$(jq -r '.version' "$PI_PACKAGE_DIR/package.json") || fail "Pi package version unavailable"
[ "$PI_VERSION" = 1.2.0 ] || fail "Pi $PI_VERSION: worker stream contract verified only on 1.2.0"
TMP_ROOT=$(fm_test_tmproot fm-pi-worker-stream-live)
fakebin=$(make_spawn_fakebin "$TMP_ROOT/fake")

for enabled in 300 0; do
  home="$TMP_ROOT/home-$enabled"
  project="$TMP_ROOT/project-$enabled"
  wt="$TMP_ROOT/wt-$enabled"
  fm_test_spawn_home "$home" pi
  fm_git_worktree "$project" "$wt" "stream-$enabled"
  fm_test_spawn_brief "$home" stream
  out=$(FM_STREAM_SILENT_MAX_SECS="$enabled" fm_test_run_spawn "$home" "$wt" "$fakebin" stream "$project" pi --mode no-mistakes --yolo off) \
    || fail "Pi $PI_VERSION: could not generate worker extension: $out"
  mkdir -p "$home/agent"
  cat > "$home/agent/models.json" <<'JSON'
{"providers":{"fm-worker-stream":{"baseUrl":"https://fm-worker-stream.invalid/v1","api":"openai-completions","apiKey":"synthetic-local-only","models":[{"id":"stream","name":"stream","contextWindow":8192,"maxTokens":512}]}}}
JSON
  # Empty environment and explicit runtime storage prevent ambient credentials
  # or resource discovery from entering this provider-free session.
  env -i PATH="$PATH" HOME="$home/user-home" NODE_NO_WARNINGS=1 \
    PI_PACKAGE_DIR="$PI_PACKAGE_DIR" PI_CODING_AGENT_DIR="$home/agent" \
    STREAM_STATE="$home/state" STREAM_EXTENSION="$home/state/stream.pi-ext.ts" \
    STREAM_CWD="$wt" STREAM_ENABLED="$enabled" \
    node "$ROOT/tests/fm-pi-worker-stream-live.mjs" || fail "Pi $PI_VERSION: real worker stream guard failed (enabled=$enabled)"
done
if ! command -v pi-signed >/dev/null 2>&1; then
  printf '# pi-signed unavailable: signed executable not exercised\n'
fi
pass "real Pi 1.2.0 worker stream lifecycle, background exclusion, and default-off behavior"
