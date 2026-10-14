set -euo pipefail
. bin/fm-liveness-lib.sh
home="$PWD/.test-phase/targets"
mkdir -p "$home/config"
for variant in absent valid maximum no-newline two-newlines crlf zero padded negative overflow hardlink symlink fifo; do
 p="$home/config/worker-target"
 [ ! -e "$p" ] && [ ! -L "$p" ] || unlink "$p"
 case "$variant" in
 absent) ;;
 valid) printf '7\n' > "$p" ;;
 maximum) printf '9223372036854775807\n' > "$p" ;;
 no-newline) printf 4 > "$p" ;;
 two-newlines) printf '4\n\n' > "$p" ;;
 crlf) printf '4\r\n' > "$p" ;;
 zero) printf '0\n' > "$p" ;;
 padded) printf '04\n' > "$p" ;;
 negative) printf '%s\n' -1 > "$p" ;;
 overflow) printf '9223372036854775808\n' > "$p" ;;
 hardlink) printf '4\n' > "$home/value"; ln "$home/value" "$p" ;;
 symlink) ln -s "$home/value" "$p" ;;
 fifo) mkfifo "$p" ;;
 esac
 if fm_liveness_snapshot "$home"; then
  printf '%s accepted target=%s\n' "$variant" "$FM_LIVENESS_TARGET"
  case "$variant" in absent|valid|maximum) ;; *) exit 1 ;; esac
 else
  printf '%s refused: %s; free=%s\n' "$variant" "$FM_LIVENESS_ERROR" "$FM_LIVENESS_FREE"
  [ "$FM_LIVENESS_FREE" = 0 ]
  case "$variant" in absent|valid|maximum) exit 1 ;; esac
 fi
done
unlink "$p"
printf 'parent_home=%s\n' "$home" > "$home/.fm-secondmate-home"
fm_liveness_snapshot "$home"
printf 'secondmate default target=%s\n' "$FM_LIVENESS_TARGET"
[ "$FM_LIVENESS_TARGET" = 6 ]
