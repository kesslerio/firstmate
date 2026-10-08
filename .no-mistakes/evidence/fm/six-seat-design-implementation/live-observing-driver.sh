#!/usr/bin/env bash
set -euo pipefail
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE FM_GATE_REFUSE_BYPASS
R=$PWD
E=/home/art/.no-mistakes/evidence/01M4EGNATFWY186FV48C2W9EBR
T=$R/.test-labs/receipt-run
mkdir -p "$T"
export FM_HERDR_LAB_STATE_DIR=$T/tripwire
S=$(bin/fm-herdr-lab.sh name observing)
export LAB_SESSION=$S LAB_ROOT=$R LAB_PATH=$PATH LAB_REAL_HOME=$HOME LAB_REAL_CLAUDE=$(command -v claude)
cleanup() { HOME="$LAB_REAL_HOME" PATH="$LAB_PATH" bin/fm-herdr-lab.sh teardown "$S"; python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$T"; }
trap cleanup EXIT
bin/fm-herdr-lab.sh provision "$S"
bin/fm-herdr-lab.sh viewer start "$S"
P=$T/primary Q=$T/remote
bin/fm-lab-home.sh create "$P"
bin/fm-lab-home.sh create "$Q"
printf 'mate\n' > "$Q/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=lab\n' > "$Q/.fm-secondmate-parent"
printf '# Disposable lab\nRemain idle. Do not run tools or change any files.\n' > "$Q/AGENTS.md"
ln -s "$R/bin" "$Q/bin"
ln -s "$R/bin" "$P/bin"
git -C "$Q" init -q
mkdir -p "$Q/state/parent-route" "$Q/data/.parent-route/mate" "$T/shims" "$T/claude-config"
printf '# Lab charter\nRemain idle. Do not run tools or change any files.\n' > "$Q/data/.parent-route/mate/brief.md"
printf 'auto\n' > "$Q/config/claude-permission-mode"
printf 'on\n' > "$Q/config/keep-ai-trailers"
cp "$Q/config/claude-permission-mode" "$P/config/claude-permission-mode"
cp "$Q/config/keep-ai-trailers" "$P/config/keep-ai-trailers"
mkdir -p "$P/data/mate"
cp "$Q/data/.parent-route/mate/brief.md" "$P/data/mate/brief.md"
cat > "$T/shims/herdr" <<'WRAP'
#!/usr/bin/env python3
import os,sys,subprocess
args=sys.argv[1:]; out=[]; i=0
while i<len(args):
    if args[i]=='--session':
        assert args[i+1]=='fm-remote',args
        i+=2; continue
    out.append(args[i].replace('fm-remote:',os.environ['LAB_SESSION']+':')); i+=1
env=dict(os.environ,PATH=os.environ['LAB_PATH'],HOME=os.environ['LAB_REAL_HOME'])
p=subprocess.run([os.environ['LAB_ROOT']+'/bin/fm-herdr-lab.sh','run',os.environ['LAB_SESSION']]+out,env=env,stdout=subprocess.PIPE)
sys.stdout.buffer.write(p.stdout.replace(os.environ['LAB_SESSION'].encode(),b'fm-remote'))
sys.exit(p.returncode)
WRAP
cat > "$T/shims/claude" <<'WRAP'
#!/usr/bin/env bash
# Keep product trust registration in the lab; real CLI uses its existing login.
unset CLAUDE_CONFIG_DIR
HOME="$LAB_REAL_HOME" exec "$LAB_REAL_CLAUDE" "$@"
WRAP
chmod +x "$T/shims/herdr" "$T/shims/claude"
export PATH=$T/shims:$PATH FM_HOME=$Q FM_ROOT_OVERRIDE=$P HOME=$T/user-home CLAUDE_CONFIG_DIR=$T/claude-config FM_SPAWN_NO_GUARD=1 FM_CONTROL_LAUNCH_WAIT=15 FM_CONTROL_EXIT_WAIT=10 FM_CONTROL_POLL=0.5
mkdir -p "$HOME"
C=$R/bin/fm-remote-secondmate-control.sh
record() { jq -cn --arg g "$1" --arg prev "$2" --arg home "$Q" '{schema:"fm-fleet-seat-holder.v2",task:"mate",incarnations:[{generation:$g,previous_generation:(if $prev=="-" then null else $prev end),kind:"secondmate",model:null,lifecycle:"reserved",launch_phase:"dispatching",route:{placement:"remote",operation:$g,home:$home}}]}'; }
env -u FM_ROOT_OVERRIDE FM_HOME="$P" HERDR_SESSION=fm-remote FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 "$R/bin/fm-spawn.sh" mate "$Q" --secondmate --harness claude --backend herdr
cp "$P/state/mate.meta" "$Q/state/parent-route/mate.meta"
OLD=$(sed -n 's/^spawn_gen=//p' "$Q/state/parent-route/mate.meta")
record observing.old - | "$C" launch mate claude - medium herdr --operation observing.old
cp "$Q/state/parent-route/mate.seat-operation.observing.old" "$E/live-observing-before.txt"
# Model an imported generation: only its observing-operation receipt remains.
[ ! -f "$Q/state/parent-route/mate.seat-operation.actual.old" ]
TARGET=$(sed -n 's/^window=//p' "$Q/state/parent-route/mate.meta")
PANE=${TARGET#*:}
herdr pane read "$PANE" --json > "$E/live-observing-original-pane.json"
# Close the owned endpoint through the guarded helper, never touch fleet panes.
herdr pane close "$PANE"
"$C" disposition mate --operation observing.old
record replacement.new "$OLD" | "$C" launch mate claude - medium herdr --operation replacement.new --previous "$OLD"
"$C" disposition mate --operation observing.old
"$C" disposition mate --operation replacement.new
cp "$Q/state/parent-route/mate.seat-operation.observing.old" "$E/live-observing-after.txt"
cp "$Q/state/parent-route/mate.seat-operation.replacement.new" "$E/live-replacement-receipt.txt"
cp "$Q/state/parent-route/mate.meta" "$E/live-replacement-meta.txt"
grep -qx phase=dead-after-start "$E/live-observing-after.txt"
grep -qx requested_generation=observing.old "$E/live-observing-after.txt"
grep -qx "actual_generation=$OLD" "$E/live-observing-after.txt"
grep -qx phase=started "$E/live-replacement-receipt.txt"
echo 'Observed: observing receipt preserves its request identity, settles actual.old, and real replacement.new confirms startup.'
