#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/home/art/.no-mistakes/evidence/01M4BGQYGGV94BM61ERP44DRTK
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND
export TMPDIR="$ROOT/.v/tmp"
for form in relative trailing-slash relative-home trailing-slash-home; do
 home="$ROOT/.v/manual/address-backend-$form"
 "$ROOT/bin/fm-lab-home.sh" create "$home" >/dev/null
 printf 'backend = "beads"\n' > "$home/.tasks.toml"
 mkdir -p "$home/user/.tasks-axi"
 printf 'backend = "markdown"\n' > "$home/user/.tasks-axi/config.toml"
 export FM_HOME="$home"
 export HOME="$home/user"
 (
 cd "$home"
 case "$form" in
 relative) export FM_DATA_OVERRIDE=data ;;
 trailing-slash) export FM_DATA_OVERRIDE="$home/data/" ;;
 relative-home) export FM_HOME=. ;;
 trailing-slash-home) export FM_HOME="$home/" ;;
 esac
 FM_POLL=.2 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 timeout -k 3 12 "$ROOT/bin/fm-watch.sh" > "$E/address-backend-$form.log" 2>&1
 )
 grep -qx heartbeat "$E/address-backend-$form.log"
done
