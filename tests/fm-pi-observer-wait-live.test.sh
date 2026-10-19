#!/usr/bin/env bash
# Token-free real Pi SDK guard: load the shipped extension with Pi's loader,
# emit through ExtensionRunner, and execute through agent-core's tool pipeline.
# Bash's injectable operations write a harmless sentinel instead of running
# submitted commands, so a regression can neither sleep nor contact Herdr.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_PI_OBSERVER_WAIT_LIVE pi npm node

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
[ -f "$PI_PACKAGE_DIR/package.json" ] || fail "installed Pi SDK not found: $PI_PACKAGE_DIR"
TMP_ROOT=$(fm_test_tmproot fm-pi-observer-live)
repo="$TMP_ROOT/primary"
mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$repo/state" "$TMP_ROOT/agent"
git init -q "$repo"
: > "$repo/AGENTS.md"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$repo/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/"
for file in fm-arm-pretool-check.sh fm-arm-command-policy.mjs fm-cd-pretool-check.sh fm-cd-command-policy.mjs fm-observer-wait-policy.mjs; do
  cp "$ROOT/bin/$file" "$repo/bin/"
done

PI_PACKAGE_DIR="$PI_PACKAGE_DIR" PI_CODING_AGENT_DIR="$TMP_ROOT/agent" \
  FM_HOME="$repo" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$repo/state" \
  node --input-type=module <<'EOF'
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { pathToFileURL } from "node:url";
const pkg = process.env.PI_PACKAGE_DIR;
const load = (file) => import(pathToFileURL(`${pkg}/${file}`).href);
const { loadExtensions, ExtensionRunner } = await load("dist/core/extensions/index.js");
const { createBashTool } = await load("dist/core/tools/bash.js");
const { SessionManager } = await load("dist/core/session-manager.js");
const { runToolCall } = await load("node_modules/@earendil-works/pi-agent-core/dist/agent-loop.js");
const version = JSON.parse(readFileSync(`${pkg}/package.json`, "utf8")).version;
const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const loaded = await loadExtensions([`${home}/.pi/extensions/fm-primary-turnend-guard.ts`], home);
assert.deepEqual(loaded.errors, [], `Pi ${version} extension load`);
assert.equal(loaded.extensions.length, 1);
const runner = new ExtensionRunner(loaded.extensions, loaded.runtime, home, SessionManager.inMemory(home));
assert.equal(runner.hasHandlers("tool_call"), true);
const sentinel = `${home}/executed`;
const tool = createBashTool(home, { operations: {
  exec: async () => {
    writeFileSync(sentinel, "executed\n");
    return { exitCode: 0 };
  },
} });
let observedBlock;
const execute = (command) => runToolCall({ type: "toolCall", id: "fixture-call", name: "bash", arguments: { command } }, {
  tools: [tool], context: { messages: [], tools: [tool] },
  assistantMessage: { role: "assistant", content: [] },
  beforeToolCall: async ({ toolCall, args }) => {
    const result = await runner.emitToolCall({ type: "tool_call", toolName: toolCall.name, toolCallId: toolCall.id, input: args });
    observedBlock = result?.block;
    return result;
  },
});
try {
  const denied = await execute("sleep 50; tail -3 state/child.status | cut -c1-400");
  assert.equal(observedBlock, true);
  assert.equal(denied.isError, true);
  assert.match(denied.result.content[0].text, /\[primary-observer-wait\]/);
  assert.equal(existsSync(sentinel), false, "denied tool reached its execution operation");
  const allowed = await execute("tail -3 state/child.status | cut -c1-400");
  assert.notEqual(observedBlock, true);
  assert.equal(allowed.isError, false);
  assert.equal(readFileSync(sentinel, "utf8"), "executed\n");
  unlinkSync(sentinel);
  unlinkSync(`${home}/state/.lock`);
  assert.equal((await execute("sleep 50; tail -3 state/child.status")).isError, false);
  assert.equal(existsSync(sentinel), true, "missing-lock startup must reach execution");
  console.log(`ok - Pi ${version}: real loader/runner/tool pipeline blocks before sentinel; immediate check and missing-lock startup execute; no model calls`);
} finally {
  await runner.emit({ type: "session_shutdown" });
}
EOF
