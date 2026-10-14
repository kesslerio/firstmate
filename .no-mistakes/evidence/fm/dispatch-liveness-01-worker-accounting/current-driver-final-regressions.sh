set -euo pipefail
export TMPDIR="$PWD/.test-phase/tmp"
evidence=<operator-home>/.no-mistakes/evidence/<owned-run-01>
for suite in fm-liveness-lib fm-branch-supervision fm-afk-return fm-crew-state; do
  timeout -k 10s 600s bash "tests/$suite.test.sh" > "$evidence/final-$suite.log" 2>&1
  printf 'completed %s\n' "$suite"
done
