#!/usr/bin/env bash
set -eu
export PATH="$PWD/.test-sol-lab/zellij:$PATH"
export FM_HOME="$PWD/.test-sol-lab/home"
export FM_ZELLIJ_SESSION=fm-lab-sol-close
export ZELLIJ_SOCKET_DIR=/home/art/.no-mistakes/evidence/01M53EGCQXW2H51Q8EPQ12MT36/z
export XDG_CONFIG_HOME="$PWD/.test-sol-lab/zellij/config"
export XDG_CACHE_HOME="$PWD/.test-sol-lab/zellij/cache"
export XDG_DATA_HOME="$PWD/.test-sol-lab/zellij/data"
export SHELL="$(command -v bash)"
unset ZELLIJ ZELLIJ_SESSION_NAME
mkdir -p "$ZELLIJ_SOCKET_DIR" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"
source bin/fm-backend.sh
fm_backend_source zellij
cleanup() { zellij kill-session "$FM_ZELLIJ_SESSION" 2>/dev/null || true; zellij delete-session "$FM_ZELLIJ_SESSION" --force 2>/dev/null || true; rm -rf "$ZELLIJ_SOCKET_DIR"; }
trap cleanup EXIT
session=$(fm_backend_zellij_container_ensure)
echo "Ready isolated session: $session"
result=$(fm_backend_zellij_create_task "$session" fm-close-proof "$PWD")
tab=${result%% *}; pane=${result##* }
echo "Created owned tab=$tab pane=$pane"
zellij --session "$session" action list-tabs --json
if fm_backend_zellij_kill "$session:$pane" "$tab" fm-wrong-identity; then echo 'ERROR identity mismatch accepted'; exit 1; fi
echo 'Wrong identity refused; endpoint retained.'
fm_backend_zellij_target_ready "$session:$pane" fm-close-proof
fm_backend_zellij_kill "$session:$pane" "$tab" fm-close-proof
fm_backend_zellij_target_absent "$session" "$pane" "$tab" fm-close-proof
echo 'Owned close succeeded and fresh pane/tab inventory proves absence.'
fm_backend_zellij_kill "$session:$pane" "$tab" fm-close-proof
echo 'Retry accepts already-absent endpoint after successful inventory.'
