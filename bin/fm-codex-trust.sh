#!/usr/bin/env bash
# Pre-register Codex's folder trust for the repository a codex spawn is about to
# launch into - the isolated task worktree of a ship or scout crewmate, or the
# seeded home of a secondmate - so the worker reaches its brief instead of
# parking on the "Trust this folder?" dialog until a person presses Enter.
#
# Usage: fm-codex-trust.sh <worktree> <project>
#        fm-codex-trust.sh --secondmate-home <home> <id>
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
#   <home>      the seeded secondmate home this spawn launches into
#   <id>        the secondmate id that home must already be marked for
# Prints one line naming what it registered; refuses loudly on anything else.
#
# WHY THIS EXISTS. Codex gates a directory it has never seen behind
# "Folder access … Trust this folder?", and no launch flag suppresses it:
# `-c projects."<path>".trust_level="trusted"` is accepted and ignored for this
# decision (verified on codex-cli 0.159.2, docs/verification/runtime-backends.md),
# and every fresh pool slot is a directory nobody has answered for. The pane
# therefore sat idle on a keystroke a human had to supply, per project, per
# machine, on every otherwise unattended spawn.
#
# WHAT GETS WRITTEN, AND WHERE. Codex persists folder trust as
# `[projects."<path>"] trust_level = "trusted"` in `${CODEX_HOME:-$HOME/.codex}/config.toml`,
# and this script writes exactly one such stanza: the entry Codex's own
# Enter-key answer would have written for that launch. Verified on
# codex-cli 0.159.2 against the installed binary in a throwaway CODEX_HOME:
# answering the dialog inside a LINKED WORKTREE persists the entry for the
# REPOSITORY ROOT, not the worktree, and an entry registered for that root -
# written ahead of launch, by this script - removes the dialog for that
# worktree, while an entry for a directory merely ABOVE the repository root
# does not. So the key is the canonical repository root, one write per project
# covers every current and future worktree of it, and pool slots add nothing to
# the store after the first spawn of that project. This is the opposite of
# Pi's scope, which is a per-directory store with an unbounded parent walk
# (bin/fm-spawn.sh's pi launch comment owns that half).
#
# Folder trust is not hook trust. The hook-trust modal stays unautomated and
# the crewmate launch disables Codex's hook layer outright, because
# pre-accepting THAT store would manufacture a consent the operator never gave
# (.agents/skills/harness-adapters/references/harness/codex.md). Folder trust is
# the same decision the operator already makes by pressing Enter on a
# firstmate-created worktree of a project firstmate was told to work on, and an
# entry this script leaves behind is the entry that key would have written.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY and mirrors bin/fm-claude-trust.sh.
# Worktree mode: <worktree> must be a LINKED git worktree - its own git dir,
# sharing <project>'s common dir - whose top level is exactly the resolved
# argument, so a primary checkout, a worktree of an unrelated repo, a
# subdirectory, a plain directory, and a home directory are each refused.
# Secondmate-home mode: the directory must carry the seed evidence
# bin/fm-home-seed.sh writes and bin/fm-spawn.sh re-checks before launch.
# Refusal is always a non-zero exit naming the reason, never a warning and
# never a silent skip.
#
# Only the launching user's own store is written. It must be a regular file this
# uid owns (or absent, in which case it is created), every unrelated line and
# project entry is preserved verbatim, an existing entry is never rewritten
# unless it already says `trusted`, the replacement is atomic, and the entry is
# read back after the rename. A store that an interactive Codex moved while this
# ran is retried once and then refused rather than clobbered.
set -u
# Path resolution here must answer from the filesystem, never from the caller's
# environment, because the refusals below are the safety property. See
# bin/fm-claude-trust.sh for the full reasoning; the class is cleared once here
# so every subshell inherits it.
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

usage() {
  echo "usage: fm-codex-trust.sh <worktree> <project>" >&2
  echo "       fm-codex-trust.sh --secondmate-home <home> <id>" >&2
  exit 2
}

# MODE selects which structural scope test decides the argument, and SCOPE_NOUN
# names what the argument was expected to be so every shared refusal reads
# correctly in both modes.
case "${1:-}" in
  --secondmate-home)
    [ "$#" -eq 3 ] || usage
    MODE=secondmate-home
    TARGET_ARG=$2
    SUB_ID=$3
    PROJ_ARG=
    SCOPE_NOUN="secondmate home"
    ;;
  '' | -h | --help)
    usage
    ;;
  *)
    [ "$#" -eq 2 ] || usage
    MODE=worktree
    TARGET_ARG=$1
    SUB_ID=
    PROJ_ARG=$2
    SCOPE_NOUN="task worktree"
    ;;
esac

refuse() { echo "error: refusing to pre-register Codex folder trust: $1" >&2; exit 1; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

# The fully resolved path of an existing file, or empty. Resolution runs in node
# because it must follow a symlink chain to its final target, and node is already
# this script's store writer.
real_file() { node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$1" 2>/dev/null; }

# The resolved common dir of a git directory, or empty. --git-common-dir can be
# relative, so it is resolved from inside the directory rather than joined here.
common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

# The repository root Codex keys folder trust on: the directory whose own git
# directory IS the common dir, derived from the common dir's parent and then
# verified rather than assumed - the same primary-checkout definition
# bin/fm-claude-trust.sh uses. Empty when no directory answers to it.
repo_root_of() {
  local common=$1 candidate git_dir bare
  candidate=$(real_dir "$(dirname -- "$common")") || return 1
  [ -n "$candidate" ] || return 1
  git_dir=$(git -C "$candidate" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  git_dir=$(real_dir "$git_dir") || return 1
  [ "$git_dir" = "$common" ] || return 1
  bare=$(git -C "$candidate" rev-parse --is-bare-repository 2>/dev/null) || return 1
  [ "$bare" = false ] || return 1
  real_dir "$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null)" || return 1
}

TARGET_REAL=$(real_dir "$TARGET_ARG") || true
[ -n "$TARGET_REAL" ] || refuse "$SCOPE_NOUN '$TARGET_ARG' is not an accessible directory"
if [ "$MODE" = worktree ]; then
  PROJ_REAL=$(real_dir "$PROJ_ARG") || true
  [ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"
fi

# Codex reads its config from ${CODEX_HOME:-$HOME/.codex}, and fm-spawn.sh
# forwards CODEX_HOME onto the launch by inheriting it rather than resolving it,
# so a relative value would name one store here and another in the pane. Refuse
# rather than guess at the worker's cwd.
CODEX_DIR=${CODEX_HOME:-}
if [ -z "$CODEX_DIR" ]; then
  [ -n "${HOME:-}" ] || refuse "neither CODEX_HOME nor HOME is set, so the store cannot be located"
  CODEX_DIR="$HOME/.codex"
else
  case "$CODEX_DIR" in
    /*) ;;
    *) refuse "CODEX_HOME '$CODEX_HOME' is a relative path, so the store the worker reads cannot be guaranteed to be the one written here; set it to an absolute path" ;;
  esac
fi
# Created when absent, the way Codex creates its own home, because an absent
# store is the ordinary state on a machine where codex has never been run
# interactively and a worker launched into that state still needs the entry.
CODEX_DIR_REAL=$(real_dir "$CODEX_DIR") || true
if [ -z "$CODEX_DIR_REAL" ]; then
  mkdir -p "$CODEX_DIR" 2>/dev/null || true
  CODEX_DIR_REAL=$(real_dir "$CODEX_DIR") || true
fi
[ -n "$CODEX_DIR_REAL" ] || refuse "Codex directory '$CODEX_DIR' does not exist and could not be created"

# The filesystem root, a home directory, and the Codex directory itself are never
# what this registers, in either mode.
[ "$TARGET_REAL" != / ] || refuse "'/' is the filesystem root, not a $SCOPE_NOUN"
[ "$TARGET_REAL" != "$CODEX_DIR_REAL" ] || refuse "'$TARGET_REAL' is the Codex directory, not a $SCOPE_NOUN"
if [ -n "${HOME:-}" ]; then
  HOME_REAL=$(real_dir "$HOME") || true
  [ "$TARGET_REAL" != "${HOME_REAL:-}" ] || refuse "'$TARGET_REAL' is the home directory, not a $SCOPE_NOUN"
fi

if [ "$MODE" = worktree ]; then
  WT_TOP=$(git -C "$TARGET_REAL" rev-parse --show-toplevel 2>/dev/null) || true
  [ -n "$WT_TOP" ] || refuse "'$TARGET_REAL' is not inside a git repository"
  WT_TOP_REAL=$(real_dir "$WT_TOP") || true
  [ "$WT_TOP_REAL" = "$TARGET_REAL" ] || refuse "'$TARGET_REAL' is not a worktree root (its root is '${WT_TOP_REAL:-unresolvable}')"

  WT_GIT_DIR=$(git -C "$TARGET_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
  [ -n "$WT_GIT_DIR" ] || refuse "'$TARGET_REAL' has no resolvable git directory"
  WT_GIT_DIR=$(real_dir "$WT_GIT_DIR") || true
  [ -n "$WT_GIT_DIR" ] || refuse "'$TARGET_REAL' has an unresolvable git directory"
  WT_COMMON=$(common_dir_of "$TARGET_REAL") || true
  [ -n "$WT_COMMON" ] || refuse "'$TARGET_REAL' has no resolvable git common directory"
  [ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$TARGET_REAL' is a primary checkout, not an isolated worktree"

  PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
  [ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
  [ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$TARGET_REAL' is not a worktree of project '$PROJ_REAL'"

  TRUST_ROOT=$(repo_root_of "$WT_COMMON") || true
  [ -n "$TRUST_ROOT" ] \
    || refuse "'$TARGET_REAL' has no verifiable repository root to register (its common dir is '$WT_COMMON')"
else
  # The seed evidence, in the order that names the most useful reason first: the
  # marker decides whether this is a secondmate home at all, the id decides whose,
  # and the instance files and operational directories decide whether it is the
  # shape bin/fm-home-seed.sh leaves behind. Same evidence
  # bin/fm-claude-trust.sh accepts, for the same reason.
  [ -n "$SUB_ID" ] || refuse "no secondmate id was supplied, so '$TARGET_REAL' cannot be matched against its seed marker"
  SUB_MARKER="$TARGET_REAL/.fm-secondmate-home"
  [ ! -L "$SUB_MARKER" ] || refuse "'$SUB_MARKER' is a symlink; a seeded secondmate home carries the marker as a regular file"
  [ -f "$SUB_MARKER" ] || refuse "'$TARGET_REAL' carries no .fm-secondmate-home marker, so it is not a seeded secondmate home"
  [ -O "$SUB_MARKER" ] || refuse "'$SUB_MARKER' is not owned by this user"
  SUB_MARKER_ID=$(cat "$SUB_MARKER" 2>/dev/null) || true
  [ "$SUB_MARKER_ID" = "$SUB_ID" ] || refuse "'$TARGET_REAL' is marked for secondmate '${SUB_MARKER_ID:-unknown}', not '$SUB_ID'"
  [ -f "$TARGET_REAL/AGENTS.md" ] || refuse "'$TARGET_REAL' has no AGENTS.md, so it is not a firstmate home"
  [ -d "$TARGET_REAL/bin" ] || refuse "'$TARGET_REAL' has no bin/, so it is not a firstmate home"
  for sub_dir_name in data state config projects; do
    sub_dir="$TARGET_REAL/$sub_dir_name"
    if [ -L "$sub_dir" ] && [ ! -e "$sub_dir" ]; then
      refuse "'$sub_dir' is a broken symlink, so this home's $sub_dir_name directory cannot be shown to stay inside it"
    fi
    [ -e "$sub_dir" ] || continue
    [ -d "$sub_dir" ] || refuse "'$sub_dir' is not a directory, so '$TARGET_REAL' is not a seeded secondmate home"
    sub_dir_real=$(real_dir "$sub_dir") || true
    [ -n "$sub_dir_real" ] || refuse "'$sub_dir' cannot be resolved"
    case "$sub_dir_real" in
      "$TARGET_REAL"/*) ;;
      *) refuse "'$sub_dir' resolves to '$sub_dir_real', outside the home, so '$TARGET_REAL' is not a safe secondmate home" ;;
    esac
  done

  # A secondmate home is a whole firstmate instance, and Codex keys the launch on
  # its repository root: the home itself when bin/fm-home-seed.sh produced a
  # standalone clone, the parent checkout when it leased a linked worktree. Either
  # way that is the entry the operator's own Enter press would have written.
  HOME_COMMON=$(common_dir_of "$TARGET_REAL") || true
  [ -n "$HOME_COMMON" ] || refuse "'$TARGET_REAL' is not inside a git repository, so it has no repository root to register"
  TRUST_ROOT=$(repo_root_of "$HOME_COMMON") || true
  [ -n "$TRUST_ROOT" ] \
    || refuse "'$TARGET_REAL' has no verifiable repository root to register (its common dir is '$HOME_COMMON')"
fi

command -v node >/dev/null 2>&1 || refuse "node is required to record folder trust and was not found on PATH"

STORE="$CODEX_DIR_REAL/config.toml"
# A dotfile manager or a synced folder legitimately symlinks this store, so the
# link is followed to its final target and every check below judges that target.
# Writing the resolved path is what keeps the link itself in place, since
# staging beside the link and renaming would replace it with a regular file.
if [ -L "$STORE" ]; then
  STORE_REAL=$(real_file "$STORE") || true
  [ -n "$STORE_REAL" ] || refuse "'$STORE' is a symlink whose target cannot be resolved"
  STORE=$STORE_REAL
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

# Read-modify-write with a fingerprint check before the rename and a readback
# after it, the bin/fm-agy-trust.sh shape: an interactive Codex rewrites this
# same file when a human answers a dialog or a setting changes, so a store that
# moved under us is retried once and then refused rather than clobbered. The
# edit is stanza-scoped - the one `[projects."<root>"]` table for the resolved
# repository root is appended, or its existing `trust_level` line is checked -
# so every unrelated line, hook entry, and profile in the operator's own config
# survives byte for byte.
if ! node - "$STORE" "$TRUST_ROOT" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, root] = process.argv.slice(2);
if (/[\0\r\n]/.test(root)) throw new Error(`cannot register a path containing a line break: ${JSON.stringify(root)}`);
// TOML basic-key escaping, which is the form Codex itself writes.
const key = root.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
const header = `[projects."${key}"]`;
// The declared path inside any `[projects."<path>"]` table header, tolerant of
// the whitespace a hand-edited file adds, so an existing entry is recognised in
// the form it was written rather than only in the form this script would write.
const declaredKey = (line) => {
  const match = /^\s*\[projects\."((?:[^"\\]|\\.)*)"\]\s*$/.exec(line);
  return match ? match[1] : null;
};
const readStore = () => {
  try {
    return fs.readFileSync(store);
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
};
const fingerprint = (buf) => (buf === null ? "absent" : crypto.createHash("sha256").update(buf).digest("hex"));
// Where this repository's entry already lives, and what it says: the header
// line, the first line after its stanza, and the recorded trust_level text
// (null when the stanza declares none). Null when the file has no entry here.
const findEntry = (lines) => {
  let found = null;
  for (let i = 0; i < lines.length; i += 1) {
    if (declaredKey(lines[i]) !== key) continue;
    if (found !== null) throw new Error(`${store} declares an entry for ${root} more than once`);
    found = { line: i, end: lines.length, value: null };
    for (let j = i + 1; j < lines.length; j += 1) {
      if (/^\s*\[/.test(lines[j])) {
        found.end = j;
        break;
      }
      const body = lines[j].replace(/^\s+/, "");
      if (body === "" || body.startsWith("#")) continue;
      if (!/^trust_level\s*=/.test(body)) {
        throw new Error(`${store} holds an unexpected key under the entry for ${root}: ${lines[j].trim()}`);
      }
      found.value = body.replace(/^trust_level\s*=\s*/, "").replace(/\s+#.*$/, "").replace(/\s+$/, "");
    }
  }
  return found;
};
// Null when nothing is recorded, the entry when something is, and a refusal when
// a human already recorded a decision this write is not entitled to flip: a
// value that is not "trusted" is most often a hand-written policy, and silently
// granting every future interactive session of that repository what the operator
// declined is the failure mode this whole control must not become.
const recordedEntry = (text) => {
  const entry = findEntry(text.split("\n"));
  if (entry === null) return null;
  if (entry.value !== null && entry.value !== '"trusted"') {
    throw new Error(`${store} already records trust_level = ${entry.value} for ${root}; refusing to overwrite that decision`);
  }
  return entry;
};
const attempt = () => {
  const original = readStore();
  const before = fingerprint(original);
  const text = original === null ? "" : original.toString("utf8");
  const lines = text.split("\n");
  const firstHeader = lines.findIndex((line) => /^\s*\[/.test(line));
  const topLevel = firstHeader === -1 ? lines.length : firstHeader;
  // A top-level inline table or dotted-key form for `projects` is a form this
  // does not own; editing it correctly needs a TOML writer, so refuse loudly
  // rather than append a table Codex may read as a conflict.
  for (let i = 0; i < topLevel; i += 1) {
    if (/^\s*projects\s*=/.test(lines[i])) {
      throw new Error(`${store} sets "projects" inline rather than as [projects."<path>"] tables; refusing to guess at that form`);
    }
    if (new RegExp(`^\\s*projects\\."${key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"\\.trust_level\\s*=`).test(lines[i])) {
      throw new Error(`${store} sets trust for ${root} as a dotted key; refusing to guess at that form`);
    }
  }
  const entry = recordedEntry(text);
  let updated;
  if (entry !== null && entry.value !== null) return "recorded";
  if (entry !== null) {
    // The header exists but says nothing: record the decision inside the existing
    // stanza rather than declaring the same table a second time.
    lines.splice(entry.line + 1, 0, 'trust_level = "trusted"');
    updated = lines.join("\n");
  } else {
    const stanza = `${header}\ntrust_level = "trusted"\n`;
    const separator = text === "" ? "" : text.endsWith("\n") ? "\n" : "\n\n";
    updated = `${text}${separator}${stanza}`;
  }
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(store), `.config.toml.fm-trust.${unique}`);
  fs.writeFileSync(tmp, updated, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  const after = recordedEntry(fs.readFileSync(store, "utf8"));
  return after !== null && after.value === '"trusted"' ? "recorded" : "dropped";
};
try {
  for (let i = 0; i < 3; i += 1) {
    const result = attempt();
    if (result === "recorded") process.exit(0);
    if (result === "moved" && i >= 1) {
      console.error(`error: ${store} was modified while folder trust was being recorded; refusing to overwrite it`);
      process.exit(1);
    }
  }
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
console.error(`error: ${store} did not retain folder trust for ${root} after 3 attempts`);
process.exit(1);
NODE
then
  refuse "could not record folder trust for '$TRUST_ROOT' in '$STORE'"
fi

echo "trusted: $TRUST_ROOT"
