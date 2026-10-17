#!/usr/bin/env bash
set -euo pipefail
cd "$WORK"
python3 - <<'PY'
import os,socket
for p in ['/home/art/.claude','/home/art/.codex','/home/art/.pi','/home/art/.config','/run/user','/tmp/tmux-1000','/home/art/projects']:
    assert not os.path.exists(p), p
assert os.environ['HOME']=='/synthetic-home'
s=socket.socket(); s.settimeout(1)
try:
    s.connect(('1.1.1.1',443))
except OSError as e:
    print('network denied:',e)
else:
    raise AssertionError('network exposed')
assert len([x for x in os.listdir('/proc') if x.isdigit()]) < 10
print('PASS isolation: real home/auth/trust/config/runtime/other checkouts absent; private PID and network namespaces')
PY
# A synthetic empty history satisfies lineage checks without exposing gate storage.
git init --bare -q /fixture.git
git --git-dir=/fixture.git --work-tree="$WORK" add bin
tree=$(git --git-dir=/fixture.git mktree </dev/null)
commit=$(printf 'Disposable validation metadata\n' | git --git-dir=/fixture.git -c user.name=Test -c user.email=test@example.invalid commit-tree "$tree")
git --git-dir=/fixture.git update-ref refs/heads/main "$commit"
git --git-dir=/fixture.git symbolic-ref HEAD refs/heads/main
case "$1" in
 protocol) bash "$EVID/protocol.sh" ;;
 wake) timeout -k 5s 300s bash bin/fm-test-run.sh tests/fm-wake-queue.test.sh ;;
 diagnostic) git check-ref-format --branch fm/stream; git --version ;;
 live) FM_PI_WORKER_STREAM_LIVE=1 timeout -k 5s 120s bash bin/fm-test-run.sh tests/fm-pi-worker-stream-live-e2e.test.sh ;;
 focused) timeout -k 5s 240s bash bin/fm-test-run.sh tests/fm-busy-state.test.sh tests/fm-busy-adapter-wiring.test.sh ;;
 watcher|watcher-evidence) python3 "$EVID/observe.py" > "$EVID/watcher-product-output.log" &
 observer=$!
 trap 'kill "$observer" 2>/dev/null || true; wait "$observer" 2>/dev/null || true' EXIT
 cases='test_pi_stream_silence_uses_inspection_timer test_pi_model_progress_and_legacy_fallback test_pi_stream_publication_lock_revalidation test_pi_stream_uninterrupted_publication test_busy_pane_default_turn_age_bound_is_3600s test_busy_pane_native_progress_resets_age test_busy_declared_pause_is_rechecked_not_wedge_escalated'
 [ "$1" != watcher-evidence ] || cases=test_pi_stream_silence_uses_inspection_timer
 FM_WATCH_TRIAGE_CASES="$cases" timeout -k 5s 360s bash bin/fm-test-run.sh tests/fm-watch-triage.test.sh ;;
esac
