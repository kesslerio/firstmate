#!/usr/bin/env bash
# Builds a disposable firstmate lab home plus a throwaway git project, so the
# real bin/fm-spawn.sh and bin/fm-sol-cap-lib.sh can be driven live.
# Usage: live-fixture.sh  -> prints the lab home path on stdout.
set -u

ROOT={run-worktree}
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX) || exit 1
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/config" "$LAB/data" "$LAB/projects"
printf '%s\n' codex > "$LAB/config/crew-harness"

# Throwaway project with an origin, so a cold-start spawn has somewhere to work.
PROJ=$LAB/project
mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
git -C "$PROJ" config user.email fm-lab@example.invalid
git -C "$PROJ" config user.name "fm lab"
printf 'lab project\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" commit -q -m init
git init -q --bare "$LAB/project.origin.git"
git -C "$PROJ" remote add origin "$LAB/project.origin.git"
git -C "$PROJ" push -q -u origin main 2>/dev/null
git -C "$LAB/project.origin.git" symbolic-ref HEAD refs/heads/main

printf 'brief\n' >/dev/null
mkdir -p "$LAB/data/backlog"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
cat > "$LAB/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
TOML

printf '%s\n' "$LAB"
