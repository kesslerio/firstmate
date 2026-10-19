// Deterministic model responses through public Pi APIs; sessions/tools stay real.
import { readFileSync, appendFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

const sha = (value) => createHash("sha256").update(value).digest("hex");
const text = (message) => typeof message?.content === "string" ? message.content :
  (message?.content ?? []).filter((part) => part.type === "text").map((part) => part.text).join("\n");
const quote = (value) => `'${String(value).replaceAll("'", "'\\''")}'`;
function identity() {
  const fields = readFileSync("/proc/self/stat", "utf8").split(") ").at(-1).split(" ");
  return { pid: process.pid, start: fields[19], ppid: Number(fields[1]), uid: process.getuid() };
}
// A generic watcher wake must never be mistaken for the typed MAIN handoff.
export function requireProcessingRequest(messages) {
  const latest = messages.filter((message) => message.role === "user").at(-1);
  const content = text(latest);
  if (!content.startsWith("\u2063FIRSTMATE_OP: v1 branch-outcome: ") ||
      !content.includes("fm_branch_processed with through=1 exactly once") ||
      !content.includes("[seq 1, recorded ")) {
    throw new Error("Expected the actual typed branch processing request for seq 1 before acknowledgment");
  }
  return content;
}
// All model-issued fixture actions import public assets without writing caches.
export function scenarioCommand(spec, action) {
  return [spec.python, "-I", "-B", join(spec.assets, "scenario.py"), action].map(quote).join(" ");
}
export default async function provider(pi) {
  const spec = JSON.parse(readFileSync(process.env.FM_RR_SPEC, "utf8"));
  if (spec.schema !== 1 || spec.kind !== "private-ready-review-sdk-fixture" || !spec.nonce) {
    throw new Error("Expected generated private SDK test fixture");
  }
  const ai = await import(pathToFileURL(join(process.env.FM_PI_PACKAGE_DIR,
    "node_modules/@earendil-works/pi-ai/dist/index.js")).href);
  const log = (event) => appendFileSync(join(spec.output, `provider-${process.pid}.jsonl`),
    `${JSON.stringify({ ...identity(), home: process.env.FM_HOME, task: process.env.FM_TASK_ID ?? null,
      exec_path: process.execPath, argv_entry: process.argv[1], sdk_package: process.env.FM_PI_PACKAGE_DIR,
      monotonic_ns: process.hrtime.bigint().toString(), ...event })}\n`, { mode: 0o600 });
  const models = ["main", "branch", "child"].map((id) => ({ id, name: `SDK fixture ${id}`,
    reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 262144, maxTokens: 8192 }));
  const counters = new Map();
  const command = (action) => scenarioCommand(spec, action);
  pi.on("session_start", (_event, ctx) => log({ event: "session-start", session_file: ctx.sessionManager.getSessionFile() }));
  pi.on("before_agent_start", (event) => log({ event: "before-agent-start", prompt_sha256: sha(event.prompt ?? ""),
    contains_nonce: (event.prompt ?? "").includes(spec.nonce) }));
  pi.registerProvider(spec.provider, { api: spec.provider, apiKey: "synthetic-placeholder-no-real-credential",
    baseUrl: "http://127.0.0.1:0", models,
    streamSimple(model, context, options) {
      if (!options?.sessionId) throw new Error("Actual SDK session identity is required");
      const key = `${model.id}:${options.sessionId}`;
      const step = counters.get(key) ?? 0;
      counters.set(key, step + 1);
      const faux = ai.fauxProvider({ provider: spec.provider, api: spec.provider, models,
        tokenSize: { min: 4096, max: 4096 } });
      faux.setResponses([async () => {
        const results = context.messages.filter((message) => message.role === "toolResult");
        const last = results.at(-1);
        log({ event: "request", role: model.id, session: options.sessionId, step,
          transcript_sha256: sha(JSON.stringify(context.messages)),
          user: context.messages.filter((message) => message.role === "user").map(text).join("\n"),
          results: results.map((message) => ({ id: message.toolCallId, tool: message.toolName,
            isError: Boolean(message.isError), text: text(message), text_sha256: sha(text(message)) })) });
        const tool = (name, args, suffix) => {
          if (!ai.getCurrentTools(context.messages).some((item) => item.name === name)) throw new Error(`Actual tool missing: ${name}`);
          const id = `${model.id}-${step}-${suffix}`;
          log({ event: "tool-issued", role: model.id, session: options.sessionId, id, tool: name, arguments_sha256: sha(JSON.stringify(args)) });
          return ai.fauxAssistantMessage(ai.fauxToolCall(name, args, { id }), { stopReason: "toolUse" });
        };
        const requireResult = (name, needle, error = false) => {
          if (!last || last.toolName !== name || Boolean(last.isError) !== error || !text(last).includes(needle)) {
            throw new Error(`Unexpected actual ${model.id} tool result at ${step}: ${name} / ${needle}`);
          }
        };
        if (model.id === "child") {
          const task = process.env.FM_TASK_ID;
          if (!spec.workerTasks.includes(task)) throw new Error("Unexpected actual worker identity");
          const brief = join(process.env.FM_HOME, "data", task, "launch-brief.md");
          if (step === 0) {
            if (!context.messages.some((message) => message.role === "user" && text(message).includes(spec.nonce))) {
              throw new Error("Actual worker launch brief lacks case nonce");
            }
            return tool("read", { path: brief }, "brief");
          }
          if (step === 1) {
            requireResult("read", spec.nonce);
            return tool("bash", { command: command("worker"), timeout: 20 }, "process");
          }
          if (step === 2) {
            requireResult("bash", `WORKER_PROCESSED ${spec.nonce}`);
            log({ event: "worker-holding", role: "child", session: options.sessionId,
              brief, brief_sha256: sha(readFileSync(brief)), last_result_id: last.toolCallId,
              last_result_sha256: sha(text(last)) });
            const deadline = Date.now() + 600000;
            while (!existsSync(join(spec.output, `${task}.release`))) {
              if (Date.now() >= deadline) throw new Error("Owned child release deadline exceeded");
              await delay(20, undefined, { signal: options.signal });
            }
            return ai.fauxAssistantMessage("Private synthetic worker processing complete.");
          }
          throw new Error("Unexpected extra worker request");
        }
        if (model.id === "branch") {
          // The first wake tests refused routine reporting and durable MAIN handoff.
          if (step === 0) return tool("bash", { command: command("branch-review"), timeout: 120 }, "review");
          if (step === 1) { requireResult("bash", "BRANCH_REVIEW_COMPLETE");
            return tool("fm_branch_report", { task: "fleet", verdict: "routine", summary: "Synthetic dependency review without a disposition." }, "refused-report"); }
          if (step === 2) { requireResult("fm_branch_report", "nothing merged", true);
            return tool("fm_branch_report", { task: "fleet", verdict: "captain", summary: "Launch the permitted dependent; retain the explicit held sibling." }, "handoff"); }
          if (step === 3) { requireResult("fm_branch_report", "recorded seq");
            return tool("bash", { command: command("branch-ack"), timeout: 60 }, "ack"); }
          if (step === 4) { requireResult("bash", "BRANCH_ACK_COMPLETE");
            log({ event: "branch-complete", role: "branch", session: options.sessionId });
            return ai.fauxAssistantMessage("Durable handoff complete."); }
          // A redundant watcher review follows the same owner path, without launching.
          const round = (step - 5) % 3;
          if (round === 0) return tool("fm_branch_report", { task: "fleet", verdict: "routine", summary: "Existing owning MAIN handoff or current disposition remains responsible." }, "replay-report");
          if (round === 1) { requireResult("fm_branch_report", "recorded seq");
            return tool("bash", { command: command("branch-ack"), timeout: 60 }, "replay-ack"); }
          requireResult("bash", "BRANCH_ACK_COMPLETE");
          return ai.fauxAssistantMessage("Repeated wake reviewed without another launch.");
        }
        if (model.id !== "main") throw new Error("Unexpected synthetic model role");
        if (step === 0) return tool("fm_watch_arm_pi", {}, "arm");
        if (step === 1) { requireResult("fm_watch_arm_pi", "watcher"); return ai.fauxAssistantMessage("Private test watcher armed."); }
        if (step === 2) {
          const request = requireProcessingRequest(context.messages);
          log({ event: "processing-request", role: "main", session: options.sessionId, request_sha256: sha(request) });
          return tool("fm_branch_processed", { through: 1 }, "premature-ack");
        }
        if (step === 3) { requireResult("fm_branch_processed", "unhandled ready review", true);
          return tool("bash", { command: command("main-dispatch"), timeout: 600 }, "dispatch"); }
        if (step === 4) { requireResult("bash", "MAIN_DISPATCH_COMPLETE");
          return tool("fm_branch_processed", { through: 1 }, "processed"); }
        if (step === 5) { requireResult("fm_branch_processed", "processed");
          return tool("bash", { command: command("finalize"), timeout: 60 }, "finalize"); }
        if (step === 6) { requireResult("bash", "SDK_SCENARIO_COMPLETE");
          log({ event: "main-complete", role: "main", session: options.sessionId });
          return ai.fauxAssistantMessage("Private dependency acceptance scenario complete."); }
        throw new Error("Unexpected extra MAIN processing request");
      }]);
      return faux.provider.streamSimple(model, context, options);
    },
  });
}
