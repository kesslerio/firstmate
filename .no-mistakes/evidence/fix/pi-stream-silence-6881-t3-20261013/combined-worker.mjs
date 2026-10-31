// Live drive: run the SPAWN-GENERATED Pi worker extension through the real Pi
// 1.2.0 SDK agent loop with a synthetic local provider stream that holds open
// (simulating a stalled foreground request). Commands arrive as files in
// CMD_DIR so the shell driver can interleave a real watcher poll cycle with the
// live stream: finish-<call> ends that provider response, chunk-<call> appends
// substantive content.
import { existsSync, readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { pathToFileURL } from "node:url";
import assert from "node:assert/strict";

const sdk = await import(pathToFileURL(process.env.PI_PACKAGE_DIR + "/dist/index.js").href);
const { DefaultResourceLoader, ModelRegistry, ModelRuntime, SessionManager, SettingsManager, createAgentSession } = sdk;
const cwd = process.env.STREAM_CWD;
const agentDir = process.env.PI_CODING_AGENT_DIR;
const state = process.env.STREAM_STATE;
const cmdDir = process.env.CMD_DIR;
const marker = state + "/stream.model-stream";
const progress = state + "/stream.model-progress";
const record = () => (existsSync(marker) ? readFileSync(marker, "utf8") : "");
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const flag = (name) => existsSync(cmdDir + "/" + name);
const take = (name) => {
  try {
    unlinkSync(cmdDir + "/" + name);
  } catch {
    /* absent */
  }
};

let calls = 0;
const encoder = new TextEncoder();
const chunk = (delta, finish = null) =>
  "data: " +
  JSON.stringify({
    id: "synthetic",
    object: "chat.completion.chunk",
    created: 1,
    model: "stream",
    choices: [{ index: 0, delta, finish_reason: finish }],
  }) +
  "\n\n";
const send = (target, delta, finishReason) => target.enqueue(encoder.encode(chunk(delta, finishReason)));
const finish = (target, reason = "stop") => {
  send(target, {}, reason);
  target.enqueue(encoder.encode("data: [DONE]\n\n"));
  target.close();
};

globalThis.fetch = async (input) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  assert.ok(url.startsWith("https://fm-combined.invalid/"), "unexpected network request: " + url);
  calls += 1;
  const call = calls;
  return new Response(
    new ReadableStream({
      start(target) {
        send(target, { role: "assistant", content: "streaming" });
        (async () => {
          for (;;) {
            if (flag("chunk-" + call)) {
              take("chunk-" + call);
              send(target, { content: " more output" });
            }
            if (flag("finish-" + call)) {
              take("finish-" + call);
              finish(target);
              return;
            }
            await delay(50);
          }
        })();
      },
    }),
    { status: 200, headers: { "content-type": "text/event-stream" } },
  );
};

const settings = SettingsManager.create(cwd, agentDir);
settings.setCacheWarmingMode("off");
const loader = new DefaultResourceLoader({
  cwd,
  agentDir,
  settingsManager: settings,
  additionalExtensionPaths: [process.env.STREAM_EXTENSION],
  noSkills: true,
  noPromptTemplates: true,
  noThemes: true,
  noContextFiles: true,
});
await loader.reload();
const runtime = await ModelRuntime.create({
  authPath: agentDir + "/auth.json",
  modelsPath: agentDir + "/models.json",
});
const registry = new ModelRegistry(runtime);
await registry.refresh();
const model = registry.find("fm-combined", "stream");
assert.ok(model, "real Pi registry failed to resolve synthetic model");
const { session } = await createAgentSession({
  cwd,
  settingsManager: settings,
  resourceLoader: loader,
  modelRuntime: runtime,
  model,
  sessionManager: SessionManager.inMemory(),
  noTools: "builtin",
});
try {
  writeFileSync(cmdDir + "/sdk-ready", "");
  // The driver finishes the held response (finish-1) after its watcher round.
  const first = session.prompt("Phase one: hold the foreground stream open.");
  await first;
  assert.equal(record(), "", "settled phase one retained stream evidence");
  writeFileSync(cmdDir + "/phase1-settled", "");
  while (!flag("go2")) await delay(50);
  const second = session.prompt("Phase two: make progress while the watcher polls.");
  await second;
  assert.equal(record(), "", "settled phase two retained stream evidence");
  writeFileSync(cmdDir + "/phase2-settled", "");
  console.log("ok - real Pi worker phases completed; final marker empty");
} finally {
  if (session.isStreaming) await session.abort();
  session.dispose();
}
void progress;
