#!/usr/bin/env bash
set -euo pipefail
cd "$WORK"
python3 /preflight.py
case "${1:-}" in
 identity-red) env -i PATH="$PATH" STREAM_EXTENSION=probe node -e "process.exit(0)";;
 preflight) exit 0;;
 cli-races) for LOCK_KIND in queue recovery; do for RACE in close progress replace; do export LOCK_KIND RACE; timeout -k 5s 45s bash /cli.sh; done; done;;
 cli-fallback) for BOUND in 0 invalid; do export BOUND OFF=1; timeout -k 5s 45s bash /cli.sh; done;;
 cli) export PREP=1; timeout -k 5s 90s bash /cli.sh;;
 live) timeout -k 5s 120s bash bin/fm-test-run.sh --json /out/sdk.json tests/fm-pi-worker-stream-live-e2e.test.sh;;
 focused) export FM_WATCH_TRIAGE_CASES='test_pi_stream_silence_uses_inspection_timer test_pi_model_progress_and_legacy_fallback test_pi_stream_publication_lock_revalidation test_pi_stream_uninterrupted_publication'; timeout -k 5s 300s bash bin/fm-test-run.sh --jobs 1 --json /out/focused.json tests/fm-busy-state.test.sh tests/fm-busy-adapter-wiring.test.sh tests/fm-watch-triage.test.sh;;
 *) exit 2;;
esac
