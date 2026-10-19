// Pi primary observer-wait policy, called only by the existing pre-tool hook.
// Reuse the arm policy's structural lexer; never execute submitted text.
// Recognize only straight-line observer programs. Unknown grammar, commands,
// expansions, executable filters, or mixed substantive work remain allowed.
import path from "node:path";
import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";

export const observerWaitReason = "[primary-observer-wait] Perform bounded current-state checks and any required action, then yield to the existing watcher instead of sleeping to poll supervised work. If supervision is missing, use the existing startup/watcher recovery path.";

const observerWrappers = new Set(["command", "env", "exec", "timeout", "gtimeout"]);
function standardExecutable(value) {
  // Custom path-qualified names may perform real work, not observation.
  return !value.includes("/") ||
    ["/bin", "/usr/bin", "/run/current-system/sw/bin"].includes(path.dirname(value));
}

function statusPath(value, state) {
  const normalized = path.normalize(value);
  return !path.basename(normalized).startsWith(".") && /\.status$/.test(normalized) &&
    (path.dirname(normalized) === "state" || path.dirname(normalized) === path.normalize(state));
}

function readerFiles(name, args) {
  let index = 0;
  while (index < args.length && args[index].startsWith("-")) {
    const option = args[index++];
    if (option === "--") break;
    if (["-n", "-c", "--lines", "--bytes"].includes(option) && name === "tail") {
      if (!/^\d+$/.test(args[index++] || "")) return [];
    } else if (name === "tail" ? !/^-(?:\d+|[nc]\d+)$/.test(option) : !/^-[nqFiE]+$/.test(option)) {
      return [];
    }
  }
  if (name !== "tail") index += 1; // grep/rg's pattern is data, never a filename.
  return args.slice(index);
}

function outputFilter(name, args) {
  if (name === "cut") return args.length === 1 && /^-c\d+(?:-\d*)?$/.test(args[0]);
  if (["head", "tail"].includes(name)) {
    return (args.length === 1 && /^-\d+$/.test(args[0])) ||
      (args.length === 2 && args[0] === "-n" && /^\d+$/.test(args[1]));
  }
  // The captured pane JSON projection is a bounded read/print program. Do not
  // treat arbitrary Python (or jq/sed programs) as harmless pipeline filters.
  if (!["python", "python3"].includes(name) || args.length !== 2 || args[0] !== "-c") return false;
  return /^import json,sys; d=json\.load\(sys\.stdin\); print\(\[\(p\['pane_id'\],p\.get\('agent_status'\)\) for p in d\['result'\]\['panes'\] if p\['pane_id'\](?:=='[A-Za-z0-9:_-]+'| in \('[A-Za-z0-9:_-]+'(?:,'[A-Za-z0-9:_-]+')*\))\]\)$/.test(args[1]);
}

export function isObserverWait(command, state) {
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return false;
  const { nodes, separators } = splitProgram(lexed.tokens);
  if (nodes.length < 2 || separators.length > nodes.length ||
      separators.some((separator) => ![";", "newline", "&&", "|"].includes(separator))) return false;
  if (separators.length === nodes.length && ![";", "newline"].includes(separators.at(-1))) return false;
  let sleep = false;
  let observer = false;
  let pipelineObserver = false;
  for (let i = 0; i < nodes.length; i += 1) {
    const tokens = nodes[i];
    // Only stderr-to-/dev/null is supported; all other IO or compound forms
    // could carry substantive work, including heredocs and substitutions.
    for (let j = 0; j < tokens.length; j += 1) {
      const token = tokens[j];
      if (token.type === "redir") {
        if (token.fd !== 2 || token.value !== ">" || tokens[j + 1]?.value !== "/dev/null") return false;
      } else if (token.type !== "word" || !token.literal || token.subs.length || token.unquotedExpansion) return false;
    }
    const position = commandPosition(tokens);
    if (!position.command || position.unresolvedWrapperOption || position.wrapperPayloads.length ||
        position.wrappers.some((wrapper) => !observerWrappers.has(wrapper))) return false;
    if (position.wrappers.includes("exec") && i !== nodes.length - 1) return false;
    // command -v/-V only prints lookup data; env/timeout help also does not run
    // the apparent operand. Conservatively skip these wrapper forms entirely.
    if (position.words.slice(0, position.index).some((word) =>
      word.value.startsWith("-") && !["--", "-p", "-i", "--ignore-environment"].includes(word.value))) return false;
    const prefix = position.words.slice(0, position.index);
    if (!standardExecutable(position.command.value) || prefix.some((word) =>
      /^PATH=/.test(word.value) || ["-i", "--ignore-environment"].includes(word.value) ||
      (observerWrappers.has(path.basename(word.value)) && !standardExecutable(word.value)))) return false;
    const name = path.basename(position.command.value);
    const args = position.words.slice(position.index + 1).map((word) => word.value);
    const fromPipe = separators[i - 1] === "|";
    const toPipe = separators[i] === "|";
    if (fromPipe) {
      if (!pipelineObserver || !outputFilter(name, args)) return false;
      continue;
    }
    pipelineObserver = false;
    if (name === "sleep") {
      const durations = args[0] === "--" ? args.slice(1) : args;
      if (toPipe || durations.length === 0 || !durations.every((value) =>
        /^(?:\d+(?:\.\d*)?|\.\d+)[smhd]?$/.test(value) && Number.parseFloat(value) > 0)) return false;
      sleep = true;
    } else if (name === "herdr" && args.length === 2 && args[0] === "pane" && args[1] === "list") {
      observer = pipelineObserver = true;
    } else if (["tail", "grep", "rg"].includes(name)) {
      const files = readerFiles(name, args);
      if (!files.length || !files.every((file) => statusPath(file, state))) return false;
      observer = pipelineObserver = true;
    } else {
      return false;
    }
  }
  return sleep && observer;
}
