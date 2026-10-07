# sparkDash Mac-node deployment record

Task: sparkdash-deploy-macnode. Ship branch `fm/sparkdash-deploy-macnode`.
All facts below were measured on 2026-10-07 (epoch 1791414215 onward); commands are quoted so the
result is reproducible.

## Stage 1 - Mac side: DONE, verified

Local checkout `/Users/kesslerio/projects/sparkDash`:

- before: `main` at `4fea2ea`, `git rev-list --left-right --count main...origin/main` = `0 2`
  (2 behind fork main), dirty only in `.gitignore`.
- `git fetch origin` -> `origin/main` = `aaddfe7` (`git merge-base --is-ancestor aaddfe7 origin/main`
  -> YES; same check against the old HEAD -> NO).
- `git stash push -- .gitignore` then `git merge --ff-only origin/main` -> HEAD `aaddfe7`.
  The stash pop conflicted (both sides append after `.worktrees/`), so the local ignore rule was
  re-applied by hand: the file now carries upstream's `__pycache__/`/`*.pyc` block **and** the
  captain-local `.compound-engineering/config.local.yaml` rule, still as one uncommitted `.gitignore`
  edit. `git merge-base --is-ancestor aaddfe7 HEAD` -> YES.

LaunchAgent:

- The README one-liner as written is broken for this layout. It runs `s|/Users/PLACEHOLDER|$HOME|g`
  first and `s|REPOS/sparkDash|$(pwd)|g` second, so an absolute `$(pwd)` yields
  `/Users/kesslerio//Users/kesslerio/projects/sparkDash/agents/macos/sparkdash_mac_agent.py` - a path
  that does not exist, so the agent never starts. Working form applies the repo prefix first:
  `sed -e "s|/Users/PLACEHOLDER/REPOS/sparkDash|$(pwd -P)|g" -e "s|/Users/PLACEHOLDER|$HOME|g" \
  agents/macos/ai.onyx.sparkdash-mac-agent.plist > ~/Library/LaunchAgents/ai.onyx.sparkdash-mac-agent.plist`
- Installed to `~/Library/LaunchAgents/ai.onyx.sparkdash-mac-agent.plist` (0 remaining
  `PLACEHOLDER`), loaded with `launchctl bootstrap gui/$(id -u) …`.
- `launchctl list | grep sparkdash` -> `ai.onyx.sparkdash-mac-agent`, listener `Python … TCP *:8790 (LISTEN)`.
- `curl -m 10 http://localhost:8790/metrics` -> HTTP 200, 2587 bytes, schema `sparkdash.mac-agent/1`,
  host `MK-MacBook-Pro-5.local`, chip `Apple M5 Max`, arch arm64, 18 cores, 3 runtimes detected
  (`mtplx-mux` :8200 serving, `tensorfold` :8300 serving model `qwen3.8-27b`, `qflash`), 4 metrics
  declared unavailable (`cpu.perCore` no psutil, `gpu.utilization`/`gpu.power`/`ane.power` need root
  powermetrics).
- `curl -m 8 http://localhost:8790/health` -> `{"ok": true, "schema": "sparkdash.mac-agent/1", "agentVersion": "1.0.0"}`.
- Survives a kill: PID 5096 -> 9864 (`KeepAlive`) with `/metrics` still 200. Survives a rootless
  kickstart: `launchctl kickstart -k gui/$(id -u)/ai.onyx.sparkdash-mac-agent` -> PID 34059, `/metrics` 200.
- Reboot survival is structural, not reboot-tested: plist sits in `~/Library/LaunchAgents`,
  `RunAtLoad` and `KeepAlive` are true, bootstrapped into the `gui/<uid>` domain. No reboot was
  performed because it was not authorized.
- Reachability from john: `curl http://100.71.122.118:8790/metrics` from john -> 200. This Mac's
  tailnet address is `100.71.122.118` (`Tailscale ip -4`, `ifconfig` utun inet), LocalHostName
  `MK-MacBook-Pro-5`.

## Stage 2 - merge fork main into `feat/llm-proxy-auth` on john: STOPPED, beyond a routine merge

`/opt/sparkDash`: branch `feat/llm-proxy-auth`, HEAD `17c9560`, merge-base with `origin/main`
(`aaddfe7`) = `b3cf0a1`, `git rev-list --left-right --count HEAD...origin/main` = `9 163`.
HEAD is 3 commits ahead of `origin/feat/llm-proxy-auth` (`5ba4d00`, `9c34a92`, `17c9560`) - unpushed.
There is also `stash@{0}` ("approach-A-wip-llm-auth").

Dirty tree is far larger than "local docker-compose.yml edits to preserve": 18 modified files
(1492 insertions / 412 deletions) plus 5 untracked (`config/sparks-llm-keys.json`,
`server/collectors/openclawGateway.js`, `server/collectors/sessionSourceHealth.js`,
`server/collectors/ssh.js.bak-20260818`, `src/components/SessionSourceFields.tsx`).
The only compose change is a bind mount: `+ - /home/kesslerio/.ssh:/root/.ssh:ro`.

Object-level merge check, no worktree touched
(`git merge-tree --write-tree --name-only HEAD origin/main`, git 2.43, exit 1)
reports **29 conflicting files**:

- content: `package.json`, `server/collectors/DecodeBench.js`, `server/collectors/LlmProbe.js`,
  `server/collectors/LlmStreaming.js`, `server/collectors/ShowcaseManager.js`, `server/config.js`,
  `server/index.js`, `server/secretsStore.js`, `server/sparks/SparkMonitor.js`,
  `server/sparks/SparkRegistry.js`, `src/api/client.ts`, `src/api/types.ts`,
  `src/components/SettingsDialog.tsx`, `src/components/SparkPage/LlmPanel.tsx`,
  `src/components/SparkPage/SparkPage.tsx`
- add/add: `server/__tests__/session-sources.test.js`, `server/collectors/HermesSessions.js`,
  `server/collectors/OpenClawSessions.js`, `server/collectors/__tests__/HermesSessions.test.js`,
  `server/collectors/__tests__/OpenClawSessions.test.js`,
  `server/collectors/__tests__/occupancyPoller.test.js`, `server/collectors/__tests__/sessionIo.test.js`,
  `server/collectors/__tests__/sessionProjector.test.js`, `server/collectors/occupancyPoller.js`,
  `server/collectors/sessionIo.js`, `server/collectors/sessionProjector.js`,
  `server/sessionSources.js`, `server/sparks/__tests__/SparkMonitor.conversations.test.js`,
  `src/components/SparkPage/ConversationList.tsx`

15 of those 29 are files that are **also dirty in the working tree**, so a merge cannot even be
attempted in place without first committing or stashing the captain's uncommitted session/LLM work.
`.gitignore` auto-merges without conflict, so "gitignore-of-record" is not the problem.

No merge was attempted; nothing on john's `/opt/sparkDash` was committed, stashed, reset, or rewritten.

## Stage 3 - how the dashboard is actually launched on john: FOUND, but not where the brief expected

- `sparkdash-boot.service` (`/etc/systemd/system/`, Type=oneshot, RemainAfterExit, waits for
  `tailscale0`) runs exactly one thing:
  `ExecStart=/usr/bin/docker compose -f /home/kesslerio/sparkDash-releases/mama-live-rates-20260930/docker-compose.live.yml up -d --force-recreate`
- That compose file defines `container_name: sparkDash-opencode-e2e`, `restart: always`,
  `command: ["node", "--watch", "server/index.js"]`, `ports: "100.120.26.16:5556:5556"`,
  `environment: PORT=5556`, and mounts `./server` + `./src/shared` **from that release directory**,
  not from `/opt/sparkDash`. So `/opt/sparkDash` does not serve the dashboard at all.
- The release directory is itself a git checkout: branch `main`, HEAD `6b6fec7` (PR #31) - one PR
  **before** the Mac-node merge `aaddfe7` (PR #32). `docker-compose.live.yml` is untracked there
  (a hand-written deployment file). Release naming convention:
  `~/sparkDash-releases/<feature>-<YYYYMMDD>/`, existing entries include `mac-host-20260929`,
  `mac-host-memfix-20260929`, `omlx-live-activity-20260929`, `mama-live-rates-20260930`,
  `model-independent-llm-telemetry-20260831`, and one named by commit SHA.
- Live evidence: `docker ps` shows `sparkDash-opencode-e2e` Up 3 hours (`100.120.26.16:5556->5556`).
  `curl http://100.120.26.16:5556/` -> 200, `GET /api/sparks` returns 4 sparks:
  `qualitycorp` (kind `mac`, 100.96.225.114, SSH), `john`, `mama`, `ofus`. No entry for this Mac.
- Port 26000: **no evidence for it on john.** `netstat -tlnp` shows only `100.120.26.16:5556`;
  `grep -r 26000` over `/opt/sparkDash` and `~/sparkDash-releases` finds nothing;
  `git log -S26000 --all` in `/opt/sparkDash` finds nothing; `26000` does not appear anywhere in
  `origin/main`. On this Mac, `*:26000` is held by the Stream Deck Slack plugin, not sparkDash.
  The live dashboard is `http://100.120.26.16:5556`.

## Stage 4 - register this Mac as a spark: NOT DONE, depends on stage 3

The current server predates `aaddfe7`, so it has no Mac-agent transport (`MacAgentCollector`,
`MacAgentFields`, agent-port field, `unavailable`-aware runtime rendering are all in that merge).
Registering the Mac now would produce exactly the wrong-looking node the captain complained about.
Intended entry once the server is on the merged tree: Unit type **Apple Silicon Mac**, host
`100.71.122.118` (tailnet), agent port `8790`, no SSH.

## Stage 5 - overview screenshot: NOT DONE, depends on stage 3/4

Intended artifact: the overview route of the live dashboard (`http://100.120.26.16:5556/`) captured
with the Mac node rendered, written to
`/Users/kesslerio/projects/firstmate/data/sparkdash-deploy-macnode/overview-with-mac-node.png`.
Not captured yet because the running server still predates the Mac-node merge, so the node cannot
be registered.

## Stage 4 prep - the exact entry and where it persists (read-only inspection, nothing written)

- Create path: `POST /api/sparks` (`server/index.js:432` in the `aaddfe7` tree) -> `registry.addSpark(body)`,
  then `startMonitor(spark)`.
- `validateSparkTarget` (`server/validate.js:154`) requires `lanIp` or `ssh.host` unless `isLocal`, so
  the Mac entry still needs its address; the agent endpoint is a separate block.
- `normalizeMacAgent` (`server/sparks/SparkRegistry.js`, added by `aaddfe7`) accepts
  `macAgent: { url?, host?, port? }`; a usable port keeps the agent transport, otherwise it falls back
  to the SSH transport for a `mac` unit. Intended body:
  `{ id: "mk-macbook-pro-5", name: "MK-MacBook-Pro-5", kind: "mac", lanIp: "100.71.122.118",
  macAgent: { host: "100.71.122.118", port: 8790 } }` - no ssh block, so no credentials get stored.
- Persistence is release-independent: `config/sparks.json` lives on john at
  `/home/kesslerio/sparkDash-opencode-e2e/config/sparks.json`, which the compose file mounts as
  `/app/config`; the existing convention is a timestamped `sparks.json.bak-before-<change>` copy
  before any manual edit. A Mac entry therefore survives both a release swap and a container restart.

## Decision that is blocking stage 3/4

- **A (recommended, matches how john already deploys):** cut
  `~/sparkDash-releases/mac-node-20261007` from `origin/main` = `aaddfe7`, copy the existing
  `docker-compose.live.yml` (keeping `container_name: sparkDash-opencode-e2e`, port 5556 on the
  tailscale IP, and the `~/.ssh` bind), then repoint `sparkdash-boot.service`'s single `ExecStart`
  path at it and `systemctl start`. Reversible by pointing the path back
  (`mama-live-rates-20260930`). Does not touch `/opt/sparkDash`, its 18 dirty files, its stash, or
  the `feat/llm-proxy-auth` branch.
- **B (as briefed):** merge fork main into `feat/llm-proxy-auth` in `/opt/sparkDash` and deploy that
  tree. Requires a human to resolve 29 conflicts (15 overlapping the captain's uncommitted work) and
  would put that uncommitted session/LLM work in front of the live dashboard.
- **C:** leave the server on 6b6fec7 and only add the Mac entry; the node would show no runtimes.

Port question stands separately: keep the live tailscale port 5556 (evidence says that is the
dashboard) or introduce 26000 (no support found anywhere).
