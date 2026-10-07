#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/home/art/.no-mistakes/evidence/01M4BGQYGGV94BM61ERP44DRTK
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND
export TMPDIR="$ROOT/.v/tmp"
export FM_HOME="$ROOT/.v/manual/outcomes"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME" >/dev/null
touch "$FM_HOME/config/supervision-host"
"$ROOT/bin/fm-branch-outcome.sh" append --task source --verdict captain --summary 'ready-work handoff: dispatch unit-first after dependency landed' > "$E/outcomes.log"
"$ROOT/bin/fm-branch-outcome.sh" append --task source --verdict captain --summary 'source completed; no new handoff' >> "$E/outcomes.log"
if "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 2 >> "$E/outcomes.log" 2>&1; then exit 1; fi
"$ROOT/bin/fm-wake-drain.sh" > "$E/outcomes-drain.log" 2>&1
"$ROOT/bin/fm-wake-drain.sh" > "$E/outcomes-repeat.log" 2>&1
grep -q 'dispatch unit-first' "$E/outcomes-drain.log"
grep -q 'source completed' "$E/outcomes-drain.log"
grep -q 'dispatch unit-first' "$E/outcomes-repeat.log"
"$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 2 >> "$E/outcomes.log"
pad=$(python3 -c 'print("x"*4500)')
"$ROOT/bin/fm-branch-outcome.sh" append --task source --verdict captain --summary "ready-work handoff: dispatch unit-first; $pad; dispatch unit-last" >> "$E/outcomes.log"
"$ROOT/bin/fm-branch-outcome.sh" append --task source --verdict captain --summary 'later source outcome' >> "$E/outcomes.log"
"$ROOT/bin/fm-wake-drain.sh" > "$E/outcomes-long.log" 2>&1
grep -q 'dispatch unit-last' "$E/outcomes-long.log"
grep -q 'mark-processed --through 3;' "$E/outcomes-long.log"
"$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 3 >> "$E/outcomes.log"
"$ROOT/bin/fm-wake-drain.sh" > "$E/outcomes-later.log" 2>&1
grep -q 'later source outcome' "$E/outcomes-later.log"
echo 'Confirmed: acknowledgement rejected before presentation; older handoff repeats; 4500-byte handoff fully shown; acknowledgement bounded to presented rows; later row shown next.' >> "$E/outcomes.log"
