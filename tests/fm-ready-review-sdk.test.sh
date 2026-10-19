#!/usr/bin/env bash
# Token-free positive integration: real Pi SDK supervision/tools, real tmux,
# real treehouse and fm-spawn, plus allowed/denied ready-review owner cases.
# The deterministic public provider replaces model responses only.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Exercise the shell wrapper before the optional SDK gate, including on stock
# macOS Bash 3.2 where an empty array under nounset aborts before exec.
test_ready_review_wrapper_backlog_modes() (
  fixture=$(fm_test_tmproot fm-ready-review-wrapper)
  mkdir -p "$fixture/data" "$fixture/config" "$fixture/fakebin"
  cat > "$fixture/fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@"
SH
  chmod +x "$fixture/fakebin/python3"
  for mode in default manual; do
    if [ "$mode" = manual ]; then printf 'manual\n' > "$fixture/config/backlog-backend"; fi
    FM_HOME="$fixture" FM_CONFIG_OVERRIDE="$fixture/config" \
      FM_DATA_OVERRIDE="$fixture/data" HOME="$fixture" PATH="$fixture/fakebin:$PATH" \
      "${FM_TEST_BASH:-bash}" "$ROOT/bin/fm-ready-review.sh" guard main > "$fixture/actual" \
      || fail "$mode backlog wrapper aborted before the Python owner"
    {
      printf '%s\n' "$ROOT/bin/fm_ready_review.py" --data "$fixture/data" --backend markdown
      if [ "$mode" = manual ]; then printf '%s\n' --manual-lifecycle; fi
      printf '%s\n' guard main
    } > "$fixture/expected"
    cmp -s "$fixture/expected" "$fixture/actual" || fail "$mode backlog wrapper changed owner arguments"
  done
  pass 'ready-review wrapper executes default and manual backlog paths with exact owner arguments'
)
test_ready_review_wrapper_backlog_modes
if [ "${FM_TEST_ONLY:-}" = test_ready_review_wrapper_backlog_modes ]; then exit 0; fi

# The admitted offline stage is mandatory: missing tools must fail, never skip.
if [ -d /opt/sdk-guest ]; then
  FM_READY_REVIEW_SDK_LIVE=1
  export FM_READY_REVIEW_SDK_LIVE
fi
fm_live_gate default-on FM_READY_REVIEW_SDK_LIVE node python3 tasks-axi jq git tmux treehouse perl
if [ "$(uname -s)" != Linux ]; then
  if [ "${FM_READY_REVIEW_SDK_LIVE:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ]; then
    fail 'requested positive SDK integration requires Linux pidfd process identities'
  fi
  printf '%s\n' 'skip: live: positive SDK integration requires Linux pidfd process identities'
  exit 0
fi
if [ ! -f /opt/sdk-guest/git-seeds/receipt.json ]; then
  if [ -d /opt/sdk-guest ] || [ "${FM_READY_REVIEW_SDK_LIVE:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ]; then
    fail 'positive SDK integration requires the admitted public existing-HEAD seed receipt'
  fi
  printf '%s\n' 'skip: live: positive SDK integration requires the admitted public existing-HEAD seed receipt'
  exit 0
fi
if [ -n "${FM_PI_PACKAGE_DIR:-}" ]; then
  package=$FM_PI_PACKAGE_DIR
else
  command -v npm >/dev/null || fail 'SDK package needs FM_PI_PACKAGE_DIR or npm root -g'
  package="$(npm root -g)/@earendil-works/pi-coding-agent"
fi
[ -f "$package/dist/index.js" ] || fail 'real Pi SDK package missing'
[ -d /proc/self ] || fail 'Linux positive SDK integration cannot read required process identities'
unset FM_GATE_REFUSE_BYPASS FM_TEST_SEAM
exec python3 -I -B "$ROOT/tests/fixtures/ready-review-sdk/run.py" --source "$ROOT" --sdk-package "$package"
