#!/usr/bin/env bash
set -eu
root=$PWD
state=$(mktemp -d "/tmp/writer.XXXXXX")
trap 'python3 -c "import shutil,sys;shutil.rmtree(sys.argv[1])" "$state"' EXIT
ev="$root/bin/fm-busy-event.sh"
gen=$("$ev" arm "$state" probe)
"$ev" apply "$state" probe busy --gen "$gen" --source pi-ext --event agent-start
"$ev" stream "$state" probe open --gen "$gen" --request 1
"$ev" stream "$state" probe progress --gen "$gen" --request 1
printf 'Allowed foreground progress: '; cat "$state/probe.model-stream"
[ ! -e "$state/probe.progress" ]
"$ev" stream "$state" probe close --gen "$gen" --request 1
printf 'Closed request tombstone: '; cat "$state/probe.model-stream-order"
refused() {
 local rc=0
 "$@" || rc=$?
 [ "$rc" = 1 ]
 printf 'Denied (exit %s): %s\n' "$rc" "$*"
}
refused "$ev" stream "$state" probe progress --gen "$gen" --request 1
refused "$ev" stream "$state" probe open --gen "$gen" --request 1
[ ! -e "$state/probe.model-stream" ]
"$ev" stream "$state" probe open --gen "$gen" --request 2
refused "$ev" stream "$state" probe close --gen "$gen" --request 1
printf 'New request preserved after late close: '; cat "$state/probe.model-stream"
new_gen=$("$ev" arm "$state" probe)
"$ev" apply "$state" probe busy --gen "$new_gen" --source pi-ext --event agent-start
"$ev" stream "$state" probe open --gen "$new_gen" --request 1
before=$(cat "$state/probe.model-stream")
refused "$ev" stream "$state" probe progress --gen "$gen" --request 2
[ "$(cat "$state/probe.model-stream")" = "$before" ]
"$ev" apply "$state" probe idle --gen "$new_gen" --source pi-ext --event agent-settled
[ ! -e "$state/probe.model-stream" ]
printf 'Settled: '; cat "$state/probe.busy-state"
refused "$ev" stream "$state" probe progress --gen "$new_gen" --request 1
"$ev" retire "$state" probe --gen "$new_gen"
refused "$ev" stream "$state" probe open --gen "$new_gen" --request 2
[ ! -e "$state/probe.model-stream" ]
printf 'PASS: actual writer CLI denies closed, late, and superseded observations; native progress is untouched.\n'
