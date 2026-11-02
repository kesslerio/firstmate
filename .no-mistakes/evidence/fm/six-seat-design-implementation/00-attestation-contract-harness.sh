#!/usr/bin/env bash
# Drive the pinned no-mistakes gate verifier with a head-bound attestation.
set -u
ACTION_REF=32d396ac0f29135daf7fcb9964aba9d5f4e796d6
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-attest.XXXXXX")
trap 'rm -rf "$T"' EXIT
curl --fail --silent --show-error --location \
  "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" > "$T/verify.py" || exit 1
HEAD=ef263384d9d11bda2ed1861563185cd3a33193bd
OLD=1111111111111111111111111111111111111111
SIG='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
DONE='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'
SKIP='[{"step":"review","status":"completed"},{"step":"test","status":"skipped"},{"step":"document","status":"completed"}]'
run() { PR_BODY="$1" PR_HEAD_SHA="$2" PR_AUTHOR=fixture PR_NUMBER=6238 python3 "$T/verify.py" 2>&1; }
echo "== head-bound attestation with every required step completed"
run "$SIG
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$HEAD\",\"steps\":$DONE} -->" "$HEAD"; echo "exit=$?"
echo "== same attestation with the test step skipped"
run "$SIG
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$HEAD\",\"steps\":$SKIP} -->" "$HEAD"; echo "exit=$?"
echo "== attestation bound to a stale head"
run "$SIG
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD\",\"steps\":$DONE} -->" "$HEAD"; echo "exit=$?"
