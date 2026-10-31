#!/usr/bin/env bash
# Child fixture for live-session-lock-driver.sh: the process that actually runs
# the product (bin/fm-lock.sh and bin/fm-inbox.sh) inside a real process tree
# whose parent is a claude-named bash. Everything it prints is a fact line the
# driver asserts on; it never fakes a product answer.
set -u
ROOT=$ROOT LAB=$LAB SCENARIO=$SCENARIO

case $SCENARIO in
  acquire)
    echo "mode=acquire ps_denied=$(ps -o comm= -p $$ >/dev/null 2>&1; echo $?)"
    out=$("$ROOT/bin/fm-lock.sh" 2>&1); rc=$?
    printf 'acquire_rc=%s\nacquire_out=%s\n' "$rc" "$out"
    echo "lock_after=$(cat "$LAB/state/.lock" 2>/dev/null)"
    session=""
    [ ! -e "$LAB/state/.lock-session" ] || session=$(cat "$LAB/state/.lock-session")
    printf 'session_after=%s\n' "$session"
    "$ROOT/bin/fm-lock.sh" status 2>&1 | sed 's/^/status_out=/'
    out=$("$ROOT/bin/fm-inbox.sh" ready 2>&1); rc=$?
    printf 'ready_rc=%s\nready_out=%s\n' "$rc" "$out"
    ;;
  refuse)
    out=$("$ROOT/bin/fm-lock.sh" 2>&1); rc=$?
    printf 'acquire_rc=%s\nacquire_out=%s\n' "$rc" "$out"
    echo "lock_after=$(cat "$LAB/state/.lock" 2>/dev/null)"
    "$ROOT/bin/fm-lock.sh" status 2>&1 | sed 's/^/status_out=/'
    ;;
  unreadable)
    # A live owner whose identity cannot be read. The driver's ps shim serves
    # every pid except the owner and refuses `ps -V`, so the product takes its
    # confirmed denied-ps route for that owner and the provider's /proc root is
    # empty. Real kill probe, real lock file, real bin/fm-lock.sh.
    echo "owner_alive=$(kill -0 "$OWNER" 2>/dev/null; echo $?)"
    out=$("$ROOT/bin/fm-lock.sh" 2>&1); rc=$?
    printf 'acquire_rc=%s\nacquire_out=%s\n' "$rc" "$out"
    echo "lock_after=$(cat "$LAB/state/.lock" 2>/dev/null)"
    ;;
  zeros)
    records=('' ' ' not-a-pid 0 00 000 0000 'win:' 'win:7abc')
    for rec in "${records[@]}"; do
      printf '%s\n' "$rec" > "$LAB/state/.lock"
      out=$("$ROOT/bin/fm-lock.sh" 2>&1); rc=$?
      printf 'record=[%s] acquire_rc=%s lock_after=[%s]\n' \
        "$rec" "$rc" "$(cat "$LAB/state/.lock" 2>/dev/null)"
      case $out in
        *'holds the lock'*) printf 'record=[%s] refusal_out=%s\n' "$rec" "$out" ;;
      esac
    done
    ;;
esac
exit 0
