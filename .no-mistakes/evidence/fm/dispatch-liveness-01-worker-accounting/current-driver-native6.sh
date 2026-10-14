#!/usr/bin/env bash
set -euo pipefail
root=$PWD
owned="$root/.test-phase/live6"
home="$owned/native-home"
mkdir -p "$home"/{state,data,config,projects} "$owned/native-bin" "$owned/native-lab-state" "$owned/harness-bin" "$owned/tmp" "$owned/herdr"
cp "$root/.test-phase/herdr/config.toml" "$owned/herdr/config.toml"
export FM_HOME="$home" FM_GUARD_READ_ONLY=1 TMPDIR="$owned/tmp" HERDR_CONFIG_PATH="$owned/herdr/config.toml" FM_HERDR_LAB_STATE_DIR="$owned/native-lab-state"
project="$home/projects/receipt-fixture"
mkdir -p "$project"
case "$home:$project" in "$root/.test-phase/"*) ;; *) exit 98;; esac
original=$PATH
helper="$root/bin/fm-herdr-lab.sh"
session=$("$helper" name accounting-current)
[[ "$session" == fm-lab-* ]] || exit 98
export HERDR_SESSION="$session"
# Negative control: source-owned exemption is absent; marker remains intact.
set +e
env -u FM_GATE_REFUSE_BYPASS "$root/bin/fm-spawn.sh" harmless "$project" --mode local-only --yolo off > "$owned/guard.txt" 2>&1
rc=$?
set -e
[ "$rc" = 3 ] && [ ! -e "$home/state/harmless.meta" ]
cat "$owned/guard.txt"
. tests/herdr-test-safety.sh
herdr_forget_inherited_pane
export HERDR_SESSION="$session"
unset TASKS_AXI_FILE TASKS_AXI_BACKEND
printf 'off\n' > "$home/config/herdr-presentation-spaces"
printf 'herdr\n' > "$home/config/backend"
git -C "$project" init -q
printf 'max_trees = 3\nroot = "%s"\n' "$project" > "$project/treehouse.toml"
printf 'Disposable fixture\n' > "$project/README.md"
git -C "$project" add .
git -C "$project" -c user.name=Tests -c user.email=tests@example.invalid -c commit.gpgsign=false commit --allow-empty -qm fixture
cat > "$owned/native-bin/herdr" <<EOF
#!/usr/bin/env bash
set -eu
args=("\$@")
n=\${#args[@]}
if [ "\${args[0]:-}" = --version ]; then exec env PATH='$original' herdr --version; fi
if [ "\$n" -ge 2 ] && [ "\${args[n-2]}" = --session ]; then
[ "\${args[n-1]}" = "$session" ] || exit 98
args=("\${args[@]:0:n-2}")
fi
exec env PATH='$original' '$helper' run '$session' "\${args[@]}"
EOF
realcodex=$(command -v codex)
cat > "$owned/native-bin/codex" <<EOF
#!/usr/bin/env python3
import os,sys,json,pathlib
args=sys.argv[1:]
if '--version' in args or '--help' in args: os.execv('$realcodex',['codex',*args])
cwd=pathlib.Path.cwd()
assert str(cwd).startswith('$project/.treehouse/'),str(cwd)
assert args[args.index('--model')+1]=='gpt-6.1-sol'
setting='projects={'+json.dumps('$project')+'={trust_level="trusted"},'+json.dumps(str(cwd))+'={trust_level="trusted"}}'
os.execv('$realcodex',['codex','-c',setting,*args])
EOF
chmod +x "$owned/native-bin/"*
cleanup() {
  local rc=$?
  trap - EXIT
  PATH="$owned/native-bin:$original" FM_CONTROL_EXIT_WAIT=8 "$root/bin/fm-control.sh" receipt exit > "$owned/native-exit.txt" 2>&1 || true
  PATH="$original" "$helper" teardown "$session" > "$owned/native-teardown.txt" 2>&1 || rc=1
  cat "$owned/native-teardown.txt"
  exit "$rc"
}
trap cleanup EXIT
ln -s "$owned/native-bin/codex" "$owned/harness-bin/codex"
PATH="$owned/harness-bin:$original" "$helper" provision "$session"
export PATH="$owned/native-bin:$original"
[ -f "$home/data/backlog.md" ] || "$root/bin/fm-tasks-axi.sh" add receipt 'Isolated provider receipt' --kind ship
"$root/bin/fm-tasks-axi.sh" show extra >/dev/null 2>&1 || "$root/bin/fm-tasks-axi.sh" add extra 'Capacity denial' --kind ship
[ -f "$home/data/receipt/brief.md" ] || "$root/bin/fm-brief.sh" receipt receipt-fixture --mode local-only --herdr-lab
python3 - "$home/data/receipt/brief.md" "$owned/provider-receipt.txt" <<'PY'
import sys,pathlib
p=pathlib.Path(sys.argv[1]);s=p.read_text().replace('{TASK}','Execute only the isolated receipt duty.').replace('{FIRSTMATE_SPEC}','No implementation, publication, validation pipeline, or other task actions.')
s=s.split('# Setup\n')[0]+'# Exact duty\nRun only this shell command once: `printf "provider-received\\n" > '+sys.argv[2]+'`. This receipt is the sole authorized write. Then reply RECEIPT-COMPLETE and remain idle. Do not quit, change configuration, or do other work.\n\n# Definition of done\nDelivery contract: mode=local-only\nReceipt only.\n'
p.write_text(s)
PY
"$root/bin/fm-afk-contract.sh" propose --words 'Disposable local validation' --spend 1
"$root/bin/fm-afk-contract.sh" confirm
"$root/bin/fm-spawn.sh" receipt "$project" --mode local-only --yolo off --harness codex --model gpt-6.1-sol --effort low --backend herdr
for i in $(seq 1 90); do [ ! -e "$owned/provider-receipt.txt" ] || break; sleep 1; done
[ -s "$owned/provider-receipt.txt" ] || { "$root/bin/fm-peek.sh" receipt; exit 97; }
cat "$owned/provider-receipt.txt"
"$root/bin/fm-tasks-axi.sh" show receipt
cat "$home/state/.last-launch"
python3 - "$home/state/.last-launch" <<'PY'
import pathlib,sys,re,time
p=pathlib.Path(sys.argv[1]);s=p.stat();v=p.read_bytes();assert s.st_nlink==1 and not p.is_symlink();assert re.fullmatch(rb'[1-9][0-9]*\n',v);assert abs(time.time()-int(v))<180
print('Exact ordinary positive epoch launch stamp verified')
PY
"$root/bin/fm-crew-state.sh" receipt
. "$root/bin/fm-liveness-lib.sh"
fm_liveness_snapshot "$home"
printf 'current live=%s free=%s\n%s%s' "$FM_LIVENESS_LIVE" "$FM_LIVENESS_FREE" "$FM_LIVENESS_LANES" "$FM_LIVENESS_WARNINGS"
before=$(find "$home/state" -type f -exec cksum {} \; | sort)
set +e
"$root/bin/fm-spawn.sh" extra "$project" --mode local-only --yolo off --harness codex --model gpt-6.1-sol --effort low --backend herdr > "$owned/native-denied.txt" 2>&1
rc=$?
set -e
cat "$owned/native-denied.txt"
[ "$rc" = 1 ] && [ ! -e "$home/state/extra.meta" ] && [ "$before" = "$(find "$home/state" -type f -exec cksum {} \; | sort)" ]
printf 'LIVE launch delivery, backlog transition, exact stamp and cap-denial verified\n'
# Slow external forge read; actual public replacement changes the incarnation.
cat > "$owned/native-bin/gh" <<EOF
#!/usr/bin/env bash
if [ -e '$owned/forge-hold' ]; then
  touch '$owned/forge-observed'
  for i in \$(seq 1 200); do [ -e '$owned/forge-release' ] && break; sleep .1; done
fi
git -C '$project' rev-parse HEAD
EOF
chmod +x "$owned/native-bin/gh"
touch "$owned/forge-hold"
"$root/bin/fm-pr-check.sh" receipt https://github.com/example/fixture/pull/1 > "$owned/stale-ready.txt" 2>&1 &
publisher=$!
for i in $(seq 1 100); do [ -e "$owned/forge-observed" ] && break; sleep .1; done
[ -e "$owned/forge-observed" ]
"$root/bin/fm-control.sh" receipt exit
rm "$owned/provider-receipt.txt"
"$root/bin/fm-spawn.sh" receipt --relaunch --harness codex --model gpt-6.1-sol --effort low
before=$(cksum "$home/state/receipt.meta")
touch "$owned/forge-release"
set +e
wait "$publisher"
rc=$?
set -e
cat "$owned/stale-ready.txt"
[ "$rc" = 1 ] && [ "$before" = "$(cksum "$home/state/receipt.meta")" ] && [ ! -e "$home/state/receipt.pr-poll" ]
printf 'Stale publisher refused after actual replacement, before persistent readiness publication\n'
rm "$owned/forge-hold"
"$root/bin/fm-pr-check.sh" receipt https://github.com/example/fixture/pull/1
fm_liveness_snapshot "$home"
[ "$FM_LIVENESS_LIVE" = 0 ]
printf 'Fresh authenticated current handoff released the seat\n'
"$root/bin/fm-brief.sh" extra receipt-fixture --mode local-only --herdr-lab
python3 - "$home/data/receipt/brief.md" "$home/data/extra/brief.md" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text().replace('provider-receipt.txt','provider-receipt-extra.txt');pathlib.Path(sys.argv[2]).write_text(s)
PY
mv "$home/state/.last-launch" "$owned/previous-stamp"
mkdir "$home/state/.last-launch"
set +e
"$root/bin/fm-spawn.sh" extra "$project" --mode local-only --yolo off --harness codex --model gpt-6.1-sol --effort low --backend herdr > "$owned/unsafe-stamp.txt" 2>&1
rc=$?
set -e
cat "$owned/unsafe-stamp.txt"
[ "$rc" = 1 ] && [ -f "$home/state/extra.meta" ] && [ -d "$home/state/.last-launch" ]
for i in $(seq 1 90); do [ -s "$owned/provider-receipt-extra.txt" ] && break; sleep 1; done
[ -s "$owned/provider-receipt-extra.txt" ]
cat "$owned/provider-receipt-extra.txt"
"$root/bin/fm-tasks-axi.sh" show extra
printf 'Unsafe stamp destination reported the started worker; native delivery and In-flight record preserved\n'
"$root/bin/fm-control.sh" extra exit
# Exercise a real rename race at the exact-path atomic publisher.
"$root/bin/fm-pr-check.sh" extra https://github.com/example/fixture/pull/2
"$root/bin/fm-tasks-axi.sh" add race 'Actual rename collision' --kind ship
"$root/bin/fm-brief.sh" race receipt-fixture --mode local-only --herdr-lab
sed 's/provider-receipt-extra.txt/provider-receipt-race.txt/g' "$home/data/extra/brief.md" > "$home/data/race/brief.md"
rmdir "$home/state/.last-launch"
mv "$owned/previous-stamp" "$home/state/.last-launch"
realperl=$(command -v perl)
realstrace=$(command -v strace)
cat > "$owned/native-bin/perl" <<EOF
#!/usr/bin/env bash
if [ "\$#" = 3 ] && [ "\$1" = - ] && [ "\$3" = '$home/state/.last-launch' ]; then
  exec '$realstrace' -o '$owned/rename-syscalls.txt' -ttt -e trace=rename,newfstatat,openat -e inject=rename:delay_enter=8s '$realperl' "\$@"
fi
exec '$realperl' "\$@"
EOF
chmod +x "$owned/native-bin/perl"
"$root/bin/fm-spawn.sh" race "$project" --mode local-only --yolo off --harness codex --model gpt-6.1-sol --effort low --backend herdr > "$owned/rename-race.txt" 2>&1 &
producer=$!
for i in $(seq 1 900); do
 if [ -e "$owned/rename-syscalls.txt" ] && rg -q 'rename\(' "$owned/rename-syscalls.txt"; then break; fi
 sleep .1
done
[ -e "$owned/rename-syscalls.txt" ] && rg -q 'rename\(' "$owned/rename-syscalls.txt"
mv "$home/state/.last-launch" "$owned/stamp-before-race"
mkdir "$home/state/.last-launch"
set +e
wait "$producer"
rc=$?
set -e
cat "$owned/rename-race.txt"
[ "$rc" = 1 ] && [ -f "$home/state/race.meta" ] && [ -d "$home/state/.last-launch" ]
for i in $(seq 1 90); do [ -s "$owned/provider-receipt-race.txt" ] && break; sleep 1; done
[ -s "$owned/provider-receipt-race.txt" ]
cat "$owned/provider-receipt-race.txt"
"$root/bin/fm-tasks-axi.sh" show race
printf 'Actual rename race preserved confirmed worker delivery and In-flight record\n'
"$root/bin/fm-control.sh" race exit
