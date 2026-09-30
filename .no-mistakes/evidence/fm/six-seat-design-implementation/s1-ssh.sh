#!/usr/bin/env bash
# FM_SSH_BIN isolation shim for the scenario-1 live lab on mama.
#
# fm-on.sh invokes: <this> -o ... -o ... -- <host> fm-remote-entrypoint.sh 1 <root_b64> <home_b64> <argv_b64>
# Only the transport target changes: instead of the account's registered
# entrypoint (which belongs to the operator's own Firstmate root and job
# worker), the candidate's own tracked entrypoint in the disposable lab root is
# run with FM_REMOTE_JOB_STATE_ROOT (the job library's isolated-state knob), so
# a private job worker serves the lab while the operator's worker and live
# fm-remote Herdr session stay untouched. The readiness doctor is run from the
# lab root without FM_ROOT_OVERRIDE, because its entrypoint-link check would
# otherwise demand re-pointing the operator's ~/.local/bin entrypoint symlink;
# --fix is refused outright so no account-level repair can ever run.
# Fault injection: a file $FAULT_DIR/<n>-<command>-<verb> makes the next
# matching call run for real on the host and then lose its reply (stdout
# discarded, ssh-style exit 255): an ambiguous reply after remote completion.
set -u
E=/Users/kesslerio/.no-mistakes/evidence/01M3RP9FKDWJ4VTFQQY8Q2R70E
LR=$(cat "$E/s1-remote-lab-root")
FAULT_DIR="$E/s1-faults"
LOG="$E/s1-transport.log"
opts=()
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do opts+=("$1"); shift; done
shift
host=$1 entry=$2 proto=$3 rootb=$4 homeb=$5 argvb=$6
[ "$host" = mama ] || { echo "shim: refusing host $host" >&2; exit 97; }
[ "$entry" = fm-remote-entrypoint.sh ] && [ "$proto" = 1 ] || { echo "shim: unexpected entrypoint" >&2; exit 97; }
case "$argvb$rootb$homeb" in *[!A-Za-z0-9+/=]*) echo "shim: bad encoding" >&2; exit 97 ;; esac
root=$(printf '%s' "$rootb" | base64 -D); home=$(printf '%s' "$homeb" | base64 -D)
case "$root/" in "$LR/root/") ;; *) echo "shim: refusing non-lab root $root" >&2; exit 97 ;; esac
case "$home" in "$LR"/*) ;; *) echo "shim: refusing non-lab home $home" >&2; exit 97 ;; esac
argv=(); while IFS= read -r -d '' a; do argv+=("$a"); done < <(printf '%s' "$argvb" | base64 -D)
cmd=${argv[0]}; verb=${argv[1]:-}
printf '%s %s %s\n' "$(date -u +%H:%M:%S)" "$cmd" "${argv[*]:1}" >> "$LOG"
if [ "$cmd" = fm-remote-doctor.sh ]; then
  [ "$verb" != --fix ] || { echo "shim: doctor --fix refused in the isolated lab" >&2; exit 1; }
  remote="$LR/doctor.sh $homeb"
else
  remote="FM_REMOTE_JOB_STATE_ROOT=$LR/jobs $LR/root/bin/fm-remote-entrypoint.sh 1 $rootb $homeb $argvb"
fi
fault=$(ls "$FAULT_DIR" 2>/dev/null | grep -E "^[0-9]+-$cmd-$verb\$" | sort -n | head -1)
if [ -n "$fault" ]; then
  rm -f -- "${FAULT_DIR:?}/${fault:?}"
  ssh "${opts[@]}" -- mama "$remote" > "$E/s1-lost-reply.$fault.out" 2>&1
  printf '%s   -> FAULT %s: remote exit %s, reply discarded, returning 255\n' "$(date -u +%H:%M:%S)" "$fault" "$?" >> "$LOG"
  exit 255
fi
exec ssh "${opts[@]}" -- mama "$remote"
