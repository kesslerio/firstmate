#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/home/art/.no-mistakes/evidence/01M4BGQYGGV94BM61ERP44DRTK
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND
export TMPDIR="$ROOT/.v/tmp"
for form in relative trailing-slash relative-home trailing-slash-home; do
 home="$ROOT/.v/manual/address-$form"
 "$ROOT/bin/fm-lab-home.sh" create "$home" >/dev/null
 cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
 export FM_HOME="$home"
 printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
 "$ROOT/bin/fm-tasks-axi.sh" add next 'ready unit at normalized root' >/dev/null
 (
 cd "$home"
 case "$form" in
 relative) export FM_DATA_OVERRIDE=data ;;
 trailing-slash) export FM_DATA_OVERRIDE="$home/data/" ;;
 relative-home) export FM_HOME=. ;;
 trailing-slash-home) export FM_HOME="$home/" ;;
 esac
 FM_POLL=.2 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 timeout -k 3 12 "$ROOT/bin/fm-watch.sh" > "$E/address-$form.log" 2>&1
 )
 grep -qx heartbeat "$E/address-$form.log"
done
