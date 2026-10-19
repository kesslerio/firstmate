#!/usr/bin/env bash
# Exercise up's mate readiness path with both supervision-host settings.
set -u
export LC_ALL=C TZ=UTC
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v tmux >/dev/null 2>&1 || { echo 'ok - skipped: tmux is not installed'; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-live-up-mate)
FM_TEST_CHILD_REGISTRY=${FM_TEST_CHILD_REGISTRY:-"$TMP_ROOT/children"}
export FM_TEST_CHILD_REGISTRY
(umask 077; : >> "$FM_TEST_CHILD_REGISTRY"; : >> "$FM_TEST_CHILD_REGISTRY.history")
export HOME="$TMP_ROOT/user"
mkdir -p "$HOME/.pi/agent" "$HOME/.treehouse" "$TMP_ROOT/source/bin" "$TMP_ROOT/fakebin"
printf '{}\n' > "$HOME/.pi/agent/trust.json"
unset CLAUDE_CONFIG_DIR TMUX

# A source checkout with a stubbed mate launch: it creates the same observable
# mate window/lock and opt-out material, without contacting a model.
cp -R "$ROOT/bin/." "$TMP_ROOT/source/bin/"
cp "$ROOT/AGENTS.md" "$TMP_ROOT/source/AGENTS.md"
cat > "$TMP_ROOT/source/bin/fm-home-seed.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p "$2/state" "$2/config" "$2/bin"
cp "$FM_HOME/bin/fm-supervision-engine-lib.sh" "$2/bin/"
if [ -f "$FM_HOME/config/supervision-host-off" ]; then
  : > "$2/config/supervision-host-off"
fi
SH
cat > "$TMP_ROOT/source/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
tmux new-window -d -t firstmate: -n "fm-$1" -c "$FM_HOME/../mate" 'exec sleep 45' || exit 1
pid=$(tmux display-message -p -t "firstmate:=fm-$1" '#{pane_pid}')
printf '%s\n' "$pid" > "$FM_HOME/../mate/state/.lock"
printf 'window=firstmate:fm-%s\n' "$1" > "$FM_HOME/state/$1.meta"
SH
cat > "$TMP_ROOT/fakebin/claude" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/state/.session-start-complete"
exec sleep 45
SH
chmod +x "$TMP_ROOT/source/bin/"{fm-home-seed,fm-spawn}.sh "$TMP_ROOT/fakebin/claude"
git -C "$TMP_ROOT/source" init -q -b main
git -C "$TMP_ROOT/source" add -A
git -C "$TMP_ROOT/source" -c user.name=t -c user.email=t@example.invalid commit -qm stub

mate_custody() {  # capture <lab> | sockets | audit
  python3 - "$1" "${2:-}" "$FM_TEST_CHILD_REGISTRY.mate-custody.json" "$FM_TEST_CHILD_REGISTRY" "$ROOT/bin/fm-lab-launch.py" <<'PYCUSTODY'
import hashlib, json, os, pathlib, stat, subprocess, sys
action, lab, receipt, registry, helper = sys.argv[1:]
receipt = pathlib.Path(receipt)
custody = json.loads(receipt.read_text()) if receipt.exists() else dict(processes={}, directories={})
def snapshot():
    text = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,pgid=,stat=,lstart='], text=True)
    return {int(pid): (int(parent), int(group), state, born.strip()) for line in text.splitlines()
            for pid, parent, group, state, born in [line.split(None, 4)]}
if action == 'capture':
    root = pathlib.Path(lab)
    fields = {}
    for line in root.joinpath('.fm-live-lab').read_text().splitlines()[1:]:
        key, sep, value = line.partition('=')
        if sep: fields.setdefault(key, []).append(value)
    anchors = subprocess.check_output([sys.executable, helper, 'anchors', lab], text=True)
    expected = {int(pid): born for line in anchors.splitlines() for pid, born in [line.split('\t', 1)]}
    rows = snapshot()
    owned = set()
    groups = set()
    for name in fields.get('anchor_record', []):
        data = json.loads(root.joinpath(name).read_text())
        if data.get('retired') is True: continue
        pid = data['pid']
        row = rows.get(pid)
        if (expected.get(pid) != data['start'] or not row or row[3] != data['start']
                or row[1] != data['group'] or row[2].startswith('Z')):
            raise ValueError('mate fixture guardian identity changed before custody capture')
        owned.add(pid)
        groups.add(row[1])
    for pid, born in zip(fields.get('launch_pid', []), fields.get('launch_start', [])):
        pid = int(pid)
        if pid in rows and rows[pid][3] == born and not rows[pid][2].startswith('Z'):
            owned.add(pid)
    owned.update(pid for pid, row in rows.items() if row[1] in groups and not row[2].startswith('Z'))
    while True:
        children = {pid for pid, row in rows.items() if row[0] in owned and not row[2].startswith('Z')}
        if children <= owned: break
        owned.update(children)
    with open(registry, 'a') as stream, open(registry + '.history', 'a') as history:
        os.chmod(registry + '.history', 0o600)
        for pid in owned:
            born = rows[pid][3]
            custody['processes'][str(pid) + '\t' + born] = [pid, born]
            line = str(pid) + '\t' + born + '\tkill\n'
            history.write(line)
            history.flush()
            os.fsync(history.fileno())
            stream.write(line)
    directory = pathlib.Path(fields['tmux_dir'][0])
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('unsafe mate fixture socket directory')
    sockets = {str(path): [path.lstat().st_dev, path.lstat().st_ino]
               for path in directory.glob('tmux-' + str(os.getuid()) + '/*')}
    current = dict(device=info.st_dev, inode=info.st_ino, sockets=sockets)
    previous = custody['directories'].get(str(directory))
    if previous and (previous['device'], previous['inode']) != (info.st_dev, info.st_ino):
        raise ValueError('mate fixture socket directory generation changed')
    if previous:
        if any(previous['sockets'].get(name) != identity for name, identity in sockets.items()):
            raise ValueError('mate fixture socket generation changed before custody refresh')
        current['sockets'] = previous['sockets']
    custody['directories'][str(directory)] = current
    temporary = receipt.with_suffix('.tmp')
    temporary.write_text(json.dumps(custody) + '\n')
    temporary.chmod(0o600)
    os.replace(temporary, receipt)
else:
    if action in ('audit', 'complete'):
        rows = snapshot()
        history = pathlib.Path(registry + '.history')
        archived = [[int(pid), born.strip()] for line in history.read_text().splitlines()
                    for pid, born, policy in [line.split('\t')]]
        survivors = [pid for pid, born in list(custody['processes'].values()) + archived
                     if pid in rows and rows[pid][3] == born and not rows[pid][2].startswith('Z')]
        if survivors: raise ValueError('owned mate fixture processes remain: ' + str(survivors))
    for name, saved in custody['directories'].items():
        directory = pathlib.Path(name)
        if directory.is_symlink(): raise ValueError('mate fixture socket directory became a link')
        if not directory.exists(): continue
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or (info.st_dev, info.st_ino) != (saved['device'], saved['inode']):
            raise ValueError('mate fixture socket custody changed')
        if action in ('audit', 'complete'): raise ValueError('owned mate fixture socket directory remains')
        for path in directory.glob('tmux-' + str(os.getuid()) + '/*'):
            info = path.lstat()
            if saved['sockets'].get(str(path)) != [info.st_dev, info.st_ino]:
                raise ValueError('mate fixture socket generation changed')
    if action == 'complete':
        target = pathlib.Path(registry + '.custody.json')
        temporary = pathlib.Path(str(target) + '.tmp')
        temporary.write_text(json.dumps(dict(schema=1, registry=registry, history=str(history),
                                            history_sha256=hashlib.sha256(history.read_bytes()).hexdigest(),
                                            cleanup_complete=True, retained_before_cleanup=True,
                                            sockets=custody['directories'])) + '\n')
        temporary.chmod(0o600)
        os.replace(temporary, target)
PYCUSTODY
}

cleanup_labs() {
  local exiting_status=$? root failed=0 down_failed=0
  for root in "$TMP_ROOT"/lab-*; do
    [ -f "$root/.fm-live-lab" ] || continue
    mate_custody capture "$root" || failed=1
    PATH="$TMP_ROOT/fakebin:$PATH" "$ROOT/bin/fm-live-lab.sh" down "$root" >> "$TMP_ROOT/cleanup.log" 2>&1 || down_failed=1
  done
  fm_test_stop_children || failed=1
  if mate_custody sockets; then
    for root in "$TMP_ROOT"/lab-*; do
      [ -f "$root/home/.fm-lab-home" ] || continue
      "$ROOT/bin/fm-lab-home.sh" teardown "$root/home" || failed=1
    done
  else
    failed=1
  fi
  mate_custody audit || failed=1
  if [ "$failed" -ne 0 ]; then
    echo "mate fixture cleanup failed; retained ownership records and evidence: $TMP_ROOT" >&2
    return 1
  fi
  mate_custody complete || return 1
  if [ "$down_failed" -ne 0 ]; then
    echo "public mate cleanup failed; owned processes and sockets retired; retained evidence: $TMP_ROOT" >&2
    return 1
  fi
  if [ "$exiting_status" -ne 0 ]; then
    echo "mate test failed; owned processes and sockets retired; retained evidence: $TMP_ROOT" >&2
    return 0
  fi
  fm_test_cleanup
}
trap 'cleanup_labs || exit 1' EXIT

for mode in off on; do
  lab="$TMP_ROOT/lab-$mode"
  host=claude
  [ "$mode" = off ] && host=off
  out=$(PATH="$TMP_ROOT/fakebin:$PATH" SHELL=/bin/sh "$ROOT/bin/fm-live-lab.sh" up --harness claude --mate --supervision-host "$host" --source "$TMP_ROOT/source" --timeout 0 "$lab" 2>&1)
  rc=$?
  if [ -f "$lab/.fm-live-lab" ]; then
    mate_custody capture "$lab" || fail 'cannot capture initial mate fixture process and socket ownership'
  fi
  expect_code 1 "$rc" "unanswered probe leaves the $mode mate lab for inspection"
  assert_not_contains "$out" 'HOST_OFF: unbound variable' "up $mode sets mate readiness state"
  assert_contains "$out" 'ok mate:' "up $mode checks the launched mate"
  assert_contains "$out" 'primary: claude' "up $mode reaches primary launch"
  if [ "$mode" = off ]; then
    assert_present "$lab/mate/config/supervision-host-off" "off mate receives inherited opt-out"
  else
    assert_absent "$lab/mate/config/supervision-host-off" "on mate has no opt-out"
  fi
  tmux_dir=$(sed -n 's/^tmux_dir=//p' "$lab/.fm-live-lab")
  TMUX_TMPDIR="$tmux_dir" tmux new-window -d -t firstmate: -n ownership-shell || fail 'cannot launch default lab shell'
  ready=0
  for ((attempt=0; attempt<50; attempt++)); do
    if python3 - "$lab" <<'PYTHON'
import json, os, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
count = 0
for name in root.joinpath('.fm-live-lab').read_text().splitlines():
    if not name.startswith('anchor_record='):
        continue
    data = json.loads(root.joinpath(name.split('=', 1)[1]).read_text())
    child = data.get('child')
    if not child:
        continue
    try:
        args = subprocess.check_output(['ps', '-o', 'args=', '-p', str(child)], text=True)
        if '--noprofile' not in args:
            continue
        assert os.getpgid(child) == data['group']
        os.kill(data['pid'], 0)
        count += 1
    except FileNotFoundError:
        continue
assert count >= 2
PYTHON
    then ready=1; break; fi
    sleep 0.1
  done
  mate_custody capture "$lab" || fail 'cannot retain final mate fixture ownership before cleanup assertions'
  [ "$ready" -eq 1 ] || fail 'initial and default shells lack continuous launch ownership'
  if [ "${FM_LIVE_LAB_UP_MATE_TEST_GROUP:-all}" = cleanup-failure ]; then
    mkdir "$TMP_ROOT/fail-cleanup-bin"
    cat > "$TMP_ROOT/fail-cleanup-bin/ps" <<'SHFAILCLEANUP'
#!/usr/bin/env bash
if [ "${1:-}" = -axo ] && [ "${2:-}" = 'pid=,ppid=,pgid=,stat=,lstart=' ]; then
  parent=$("$REAL_PS" -o args= -p "$PPID") || exit 1
  case "$parent" in *'fm-live-lab.sh down '*) touch "$CLEANUP_FAILURE_HIT"; exit 1 ;; esac
fi
exec "$REAL_PS" "$@"
SHFAILCLEANUP
    chmod +x "$TMP_ROOT/fail-cleanup-bin/ps"
    REAL_PS="$(command -v ps)" CLEANUP_FAILURE_HIT="$TMP_ROOT/forced-cleanup-hit" PATH="$TMP_ROOT/fail-cleanup-bin:$PATH" cleanup_labs
    cleanup_rc=$?
    expect_code 1 "$cleanup_rc" 'failed public cleanup must remain a failed fixture cleanup'
    assert_present "$TMP_ROOT/forced-cleanup-hit" 'fixture did not force the public cleanup failure'
    assert_present "$FM_TEST_CHILD_REGISTRY.mate-custody.json" 'failed cleanup erased its independent ownership receipt'
    assert_present "$FM_TEST_CHILD_REGISTRY.custody.json" 'owned cleanup proof was not retained before fixture deletion'
    assert_present "$lab/.fm-live-lab" 'failed cleanup erased the retained lab evidence'
    mate_custody audit || fail 'failed public cleanup left captured processes or sockets alive'
    trap - EXIT
    pass 'failed public mate cleanup retires exact captured processes and sockets before retaining failure evidence'
    exit 0
  fi
  out=$(PATH="$TMP_ROOT/fakebin:$PATH" "$ROOT/bin/fm-live-lab.sh" down "$lab" 2>&1)
  expect_code 0 "$?" "owned $mode lab cleanup: $out"
  assert_absent "$lab" "owned $mode lab was fully retired"
  pass "up --mate with supervision host $mode reaches readiness"
done
