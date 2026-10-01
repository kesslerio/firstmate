#!/usr/bin/env bash
# Pi-surface live guard: load the REAL supervision-branch and Pi-watcher
# extensions against the REAL installed Pi SDK, arm the watcher, and hand it one
# Orca stale wake keyed by the task's Orca TERMINAL HANDLE.
#
# Pass = the Pi branch accepts the offer and publishes its eligible-row grant
# naming that row (state/.branch-eligible-rows), which is exactly what it does
# before it prompts itself. The same fixture against the PRE-FIX dispatch module
# must leave the branch untouched (no grant) and hand the wake to main.
#
# No provider call leaves the machine: PI_CODING_AGENT_DIR points at an empty
# directory, so the branch has no model and its prompt fails after the claim.
set -u
WORKTREE="$1"; LIB="$2"; CTRL="$3"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
[ -f "$PI_PACKAGE_DIR/package.json" ] || { echo "Pi package absent"; exit 1; }
PI_VERSION=$(node -e 'console.log(require(process.argv[1]).version)' "$PI_PACKAGE_DIR/package.json")
export NODE_NO_WARNINGS=1

probe() {  # <label> <repo-root-with-the-dispatch-module-under-test>
  local label=$1 srcroot=$2
  local home agentdir
  home="$LIB/home-$label"; agentdir="$LIB/agent-$label"
  rm -rf "$home" "$agentdir" "$LIB/repo-$label"
  rm -f "$LIB/watch-$label.log" "$LIB/trigger-$label" "$LIB/node-$label.log"
  local repo="$LIB/repo-$label"
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$repo/node_modules/@earendil-works" "$home/state" "$home/config" "$agentdir"
  cp "$WORKTREE/.pi/extensions/fm-branch-supervision.ts" "$repo/.pi/extensions/"
  cp "$WORKTREE/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/"
  for f in fm-native-contract.ts fm-async-exec.ts fm-branch-model-picker.ts fm-calm-visibility.ts fm-operational-input.ts; do
    cp "$WORKTREE/.pi/extensions/lib/$f" "$repo/.pi/extensions/lib/"
  done
  cp "$srcroot/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$WORKTREE"/bin/fm-operational-input.sh "$repo/bin/"
  cp "$WORKTREE/bin/fm-wake-lib.sh" "$WORKTREE/bin/fm-wake-grant.sh" "$WORKTREE/bin/fm-wake-drain.sh" "$repo/bin/"
  for f in fm-path-lib.sh fm-classify-lib.sh fm-line-cap-lib.sh fm-timeout-lib.sh fm-lease-lib.sh \
           fm-supervision-engine-lib.sh fm-afk-contract.sh fm-marker-lib.sh fm-wake-lib.sh; do
    [ -f "$WORKTREE/bin/$f" ] && cp "$WORKTREE/bin/$f" "$repo/bin/"
  done
  cp "$LIB/fake-watch-arm.sh" "$repo/bin/fm-watch-arm.sh"
  chmod +x "$repo"/bin/*.sh
  ln -s "$PI_PACKAGE_DIR" "$repo/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$repo/node_modules/@earendil-works/pi-tui"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" "$repo/node_modules/@earendil-works/pi-ai"
  ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$repo/node_modules/typebox"
  mkdir -p "$home/projects/orca-probe"
  # The Orca task record: the stale wake the watcher will deliver is keyed by the
  # Orca terminal handle, exactly as bin/fm-watch.sh keys it.
  printf 'project=%s/projects/orca-probe\nterminal=term-live-orca-1\nwindow=fm-live-orca\nbackend=orca\nharness=claude\nkind=ship\nendpoint_task_id=live-orca\n' "$home" > "$home/state/live-orca.meta"
  printf 'working: live guard step\n' > "$home/state/live-orca.status"
  rm -f "$home/state/.wake-queue" "$home/state/.wake-queue.seq" "$home/state/.watcher-down" \
    "$home/state/.branch-eligible-rows" "$home/state/.branch-eligible-owner"
  FM_HOME="$home" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append stale term-live-orca-1 "stale: term-live-orca-1 (idle Orca pane)"; fm_wake_append signal live-orca.status "signal: live-orca.status"' _ "$WORKTREE"

  BRANCH_PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" \
  WATCH_PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" \
  FM_HOME="$home" FM_REAL_ROOT="$repo" FM_WATCH_ROOT="$repo" \
  FM_LIVE_WATCH_LOG="$LIB/watch-$label.log" FM_LIVE_WATCH_TRIGGER="$LIB/trigger-$label" \
  PI_CODING_AGENT_DIR="$agentdir" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
  node --input-type=module > "$LIB/node-$label.log" 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
const home = resolve(process.env.FM_HOME);
const busHandlers = new Map();
const offers = [];
const bus = {
  on(channel, handler) { busHandlers.set(channel, [...(busHandlers.get(channel) ?? []), handler]); return () => {}; },
  emit(channel, data) {
    for (const h of busHandlers.get(channel) ?? []) h(data);
    if (channel === "fm-branch-supervision:dispatch") offers.push(data);
  },
};
const mainUserMessages = [];
const piHandlers = new Map();
let watcherTool = null;
const sessionCtx = { sessionManager: { getSessionFile: () => `${home}/main.jsonl`, getEntries: () => [] } };
const pi = {
  events: bus,
  on(event, handler) { piHandlers.set(event, [...(piHandlers.get(event) ?? []), handler]); },
  registerTool(tool) { if (tool.name === "fm_watch_arm_pi") watcherTool = tool; },
  registerCommand() {}, registerMessageRenderer() {}, sendMessage() {},
  async sendUserMessage(content, options) {
    mainUserMessages.push({ content, options: options ?? {} });
    for (const h of piHandlers.get("before_agent_start") ?? []) await h({ prompt: content }, sessionCtx);
    for (const h of piHandlers.get("message_start") ?? []) await h({ message: { role: "user", content: [{ type: "text", text: content }] } }, sessionCtx);
  },
};
process.env.FM_ROOT_OVERRIDE = process.env.FM_REAL_ROOT;
const branchMod = await import(pathToFileURL(process.env.BRANCH_PLUGIN).href);
branchMod.default(pi);
process.env.FM_ROOT_OVERRIDE = process.env.FM_WATCH_ROOT;
const watchMod = await import(pathToFileURL(process.env.WATCH_PLUGIN).href);
watchMod.default(pi);
const waitFor = async (p, label) => {
  for (let i = 0; i < 600; i += 1) { if (p()) return; await new Promise((r) => setTimeout(r, 50)); }
  throw new Error(`timeout waiting for ${label}`);
};
const armCount = () => existsSync(process.env.FM_LIVE_WATCH_LOG)
  ? readFileSync(process.env.FM_LIVE_WATCH_LOG, "utf8").split(/\n/).filter((l) => l.startsWith("arm ")).length : 0;
for (const h of piHandlers.get("session_start") ?? []) await h({ type: "session_start", reason: "startup" }, sessionCtx);
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
if (!watcherTool) throw new Error("watcher tool was not registered");
const armed = await watcherTool.execute("live-orca-arm", {}, undefined, undefined, {});
if (!armed.details?.ok) throw new Error(`watcher did not arm: ${JSON.stringify(armed.details)}`);
await waitFor(() => armCount() >= 1, "watcher arm");
writeFileSync(process.env.FM_LIVE_WATCH_TRIGGER, "stale: term-live-orca-1 (idle Orca pane)");
await waitFor(() => offers.length === 1, "branch dispatch offer");
const offer = offers[0];
const grantFile = `${home}/state/.branch-eligible-rows`;
// Let the branch's own claim path run to its end: with an empty agent dir it
// has no model, so it rejects its settlement back to the watcher, which then
// delivers the same wake to main.
let mainGot = false;
try {
  await waitFor(() => mainUserMessages.length === 1, "watcher-owned main delivery");
  mainGot = (mainUserMessages[0]?.content ?? "").includes("FIRSTMATE WATCHER WAKE: stale: term-live-orca-1");
} catch {}
const rows = existsSync(grantFile) ? readFileSync(grantFile, "utf8").trim().split("\n").join(",") : "";
console.log(JSON.stringify({
  offerEligible: offer.eligible,
  offerAccepted: offer.accepted,
  offerProjects: offer.projects.map((p) => p.split("/").pop()),
  branchGrantRows: rows,
  mainGotWake: mainGot,
}));
process.exit(0);
EOF
}

cat > "$LIB/fake-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_LIVE_WATCH_LOG:?}"
  exit 0
fi
printf 'arm pid=%s\n' "$$" >> "${FM_LIVE_WATCH_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=live-orca-generation\n' "$$"
trap 'exit 0' TERM INT
while :; do
  if [ -e "$FM_LIVE_WATCH_TRIGGER" ]; then
    reason=$(cat "$FM_LIVE_WATCH_TRIGGER"); rm -f "$FM_LIVE_WATCH_TRIGGER"
    printf '%s\n' "$reason"; exit 0
  fi
  sleep 0.02
done
SH

echo "Pi SDK: $PI_VERSION"
echo "--- POST-FIX (this change): the Pi branch's own verdict on one Orca terminal-keyed stale wake"
probe postfix "$WORKTREE" || { echo "post-fix probe failed"; cat "$LIB/node-postfix.log"; exit 1; }
sed -n 's/^/  result: /p' "$LIB/node-postfix.log"
echo "--- PRE-FIX (base commit 549e07f), identical fixture and Pi runtime:"
probe prefix "$CTRL" || { echo "pre-fix probe failed"; cat "$LIB/node-prefix.log"; exit 1; }
sed -n 's/^/  result: /p' "$LIB/node-prefix.log"
