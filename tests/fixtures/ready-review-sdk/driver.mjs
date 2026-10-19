// Actual public SDK embedding with unmodified Firstmate branch/watcher extensions.
import { readFileSync, writeFileSync, appendFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import provider from "./provider.mjs";
const spec = JSON.parse(readFileSync(process.env.FM_RR_SPEC, "utf8"));
const sdk = await import(pathToFileURL(join(process.env.FM_PI_PACKAGE_DIR, "dist/index.js")).href);
const settings = sdk.SettingsManager.inMemory({ retry: { enabled: false }, compaction: { enabled: false } });
const events = [];
const settlements = [];
const branchFailures = [];
const observer = (pi) => {
  pi.events.on("fm-branch-supervision:dispatch", (offer) => {
    events.push(offer);
    appendFileSync(join(spec.output, "dispatch-events.jsonl"), `${JSON.stringify({ accepted: offer.accepted, message: offer.message })}\n`);
    if (offer.accepted && offer.settlement) settlements.push(Promise.resolve(offer.settlement).then(
      () => appendFileSync(join(spec.output, "dispatch-events.jsonl"), '{"settled":true}\n'),
      (error) => {
        branchFailures.push(String(error));
        appendFileSync(join(spec.output, "dispatch-events.jsonl"), `${JSON.stringify({ failed: String(error) })}\n`);
      }));
  });
};
const loader = new sdk.DefaultResourceLoader({ cwd: spec.source, agentDir: process.env.PI_CODING_AGENT_DIR,
  settingsManager: settings, noExtensions: true, noSkills: true, noThemes: true,
  noPromptTemplates: true, noContextFiles: true,
  additionalExtensionPaths: [join(spec.source, ".pi/extensions/fm-branch-supervision.ts"), join(spec.source, ".pi/extensions/fm-primary-pi-watch.ts")],
  extensionFactories: [{ name: "private-ready-review-sdk-model", factory: provider }, { name: "private-ready-review-observer", factory: observer }],
});
await loader.reload();
if (loader.getExtensions().errors.length) throw new Error(JSON.stringify(loader.getExtensions().errors));
const runtime = await sdk.ModelRuntime.create({ authPath: join(process.env.PI_CODING_AGENT_DIR, "auth.json"),
  modelsPath: join(process.env.PI_CODING_AGENT_DIR, "models.json"), allowModelNetwork: false });
const model = { id: "main", provider: spec.provider, api: spec.provider, name: "SDK fixture main", baseUrl: "http://127.0.0.1:0",
  reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 262144, maxTokens: 8192 };
const manager = sdk.SessionManager.create(spec.source, join(spec.output, "main-session"));
const { session } = await sdk.createAgentSession({ cwd: spec.source, agentDir: process.env.PI_CODING_AGENT_DIR,
  resourceLoader: loader, settingsManager: settings, sessionManager: manager, modelRuntime: runtime, model,
  tools: ["read", "bash", "fm_watch_arm_pi", "fm_branch_processed"] });
const errors = [];
session.subscribe((event) => {
  appendFileSync(join(spec.output, "main-events.jsonl"), `${JSON.stringify(event)}\n`);
  if (event.type === "message_end" && event.message?.role === "assistant" && ["error", "aborted"].includes(event.message.stopReason)) {
    errors.push({ message: "Actual MAIN provider turn failed", stopReason: event.message.stopReason });
  }
});
// This synthetic primary is the actual live AgentSession host, never a fake worker.
for (const scene of spec.scenes) writeFileSync(join(spec.root, "homes", scene, "state/.lock"), `${process.pid}\n`, { mode: 0o600 });
writeFileSync(join(spec.output, "primary-owner.json"), JSON.stringify({ pid: process.pid, exec_path: process.execPath, session_file: manager.getSessionFile() }));
try {
  await runtime.refresh({ providers: [spec.provider], allowNetwork: false });
  await session.bindExtensions({ mode: "print", onError: (error) => { errors.push(error);
    appendFileSync(join(spec.output, "extension-errors.jsonl"), `${JSON.stringify(error)}\n`); } });
  await session.prompt(`Exercise the private dependency acceptance fixture ${spec.nonce}.`);
  const deadline = Date.now() + 720000;
  while (!existsSync(join(spec.output, "scenario-completed.json"))) {
    if (errors.length || branchFailures.length) throw new Error("Actual extension or branch error; see private evidence");
    if (Date.now() >= deadline) throw new Error("Actual asynchronous supervision completion deadline exceeded");
    await delay(20);
  }
  await session.waitForIdle();
  // A consumed wake can precede the branch's final model turn. Await its real
  // settlement before session shutdown, including offers delivered meanwhile.
  let count;
  do {
    count = settlements.length;
    await Promise.all(settlements.slice());
    await session.waitForIdle();
  } while (settlements.length !== count);
  if (errors.length || branchFailures.length || !events.some((offer) => offer.accepted)) throw new Error("Actual branch dispatch not established");
  writeFileSync(join(spec.output, "driver-completed.json"), JSON.stringify({ schema: 1, pid: process.pid,
    actual_branch_offers: events.length, accepted: events.filter((offer) => offer.accepted).length,
    session_file: manager.getSessionFile() }));
} finally {
  await session.abort();
  await session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" });
  session.dispose();
}
