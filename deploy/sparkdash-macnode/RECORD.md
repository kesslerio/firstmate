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

## Stage 2 - merge fork main into `feat/llm-proxy-auth` on john: SKIPPED by ruling (Option A)

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

## Stage 3 - how the dashboard is actually launched on john: FOUND and APPLIED via Option A

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

## Stage 4 - register this Mac as a spark: DONE, verified through the running dashboard

Registered through the live dashboard's own `POST /api/sparks` as Unit type **Apple Silicon Mac**
(`kind: "mac"`), host `100.71.122.118` (tailnet), agent port `8790`, no SSH block, so no credentials
were stored. Full evidence, including the field-name correction, is in "Stage 4 applied" below.

## Stage 4 prep - the exact entry and where it persists

- Create path: `POST /api/sparks` (`server/index.js:432` in the `aaddfe7` tree) -> `registry.addSpark(body)`,
  then `startMonitor(spark)`.
- `validateSparkTarget` (`server/validate.js:154`) requires `lanIp` or `ssh.host` unless `isLocal`, so
  the Mac entry still needs its address; the agent endpoint is a separate block.
- The block is `agent: { url?, host?, port? }` - **not** `macAgent`. `normalizeMacAgent` keeps the agent
  transport when a usable port is present, otherwise the `mac` unit falls back to SSH. `kind` is
  case-sensitive and normalized by `SparkRegistry` line 606: only `"host"`, `"mac"`, `"spark"` survive;
  `"MAC"` or `"windows"` become `spark`, so the unit-type choice must be lowercase `mac`.
- Working body:
  `{ id: "mk-macbook-pro-5", name: "MK-MacBook-Pro-5", kind: "mac", lanIp: "100.71.122.118",
  agent: { host: "100.71.122.118", port: 8790 } }` - no ssh block, so no credentials get stored.
- Persistence is release-independent: `config/sparks.json` lives on john at
  `/home/kesslerio/sparkDash-opencode-e2e/config/sparks.json`, which the compose file mounts as
  `/app/config`; the existing convention is a timestamped `sparks.json.bak-before-<change>` copy
  before any manual edit. A Mac entry therefore survives both a release swap and a container restart.

## Stage 5 - screenshots: DONE

Both captured from the live dashboard on john through the browser, full page, verified on disk:

- `/Users/kesslerio/projects/firstmate/data/sparkdash-deploy-macnode/overview-with-mac-node.png`
  (1280x1116, 150402 bytes) - overview with 5/5 online and the `MK-MacBook-Pro-5` card rendered
  `MAC / STANDALONE / ONLINE`, unified memory 94.4 / 128 GB, CPU 74%, **GPU usage unavailable**,
  **GPU Power unavailable**, LLM unavailable, and RUNTIMES chips `mtplx-mux :8200`,
  `tensorfold :8300 qwen3.8-27b`, `qflash :11234`.
- `/Users/kesslerio/projects/firstmate/data/sparkdash-deploy-macnode/node-mk-macbook-pro-5.png`
  (1280x1292, 152756 bytes) - node page `/spark/mk-macbook-pro-5`: header `Mac (Mac17,6) · Apple M5 Max`,
  uptime 7h 58m; GPU panel usage/power `unavailable`, thermal pressure dash, throttle OK, unified memory
  96.0 / 128.0 GB, available 32.0 GB; CPU usage 83% with temperature and CPU power `unavailable`,
  model `Apple M5 Max · 18 cores`; RAM 96.0 / 128.0 GB at 75%; MODEL RUNTIMES listing all three as
  serving with ports; storage `/System/Volumes/Data disk3s5` 43% (1588 / 3722 GB); network `en0`
  192.168.4.125; LLM service `unavailable · not_observed` on :8888.
- An earlier viewport-only capture of the same overview is kept as `overview-with-mac-node-viewport.png`.

## Stage 2 applied - skipped by ruling

The ruling picked Option A, so no merge was attempted or needed. `/opt/sparkDash` ended the task
exactly as found: 23 dirty entries, HEAD `17c9560`, `stash@{0}` present. `feat/llm-proxy-auth` was
never checked out, committed, stashed, or reset.

## Stage 3 applied - the release swap, with the one wrinkle

Sequence executed on john (read-only checks first, single `ExecStart` line changed):

1. `cp -a ~/sparkDash-releases/mama-live-rates-20260930 ~/sparkDash-releases/mac-node-20261007`
   (19 MB base, no `node_modules`; the untracked `docker-compose.live.yml` is preserved by the copy).
2. Inside the new dir: `git fetch origin main` -> `6b6fec7..aaddfe7`, then
   `git checkout --detach origin/main`; `git merge-base --is-ancestor aaddfe7 HEAD` -> YES, and
   `git diff --stat 6b6fec7 HEAD` = **28 files changed, 2943 insertions(+), 35 deletions(-)** - the
   Mac-node merge. `docker-compose.live.yml` still present and untracked.
3. `docker compose -f docker-compose.live.yml build` **before** touching the unit, exit 0,
   image `mac-node-20261007-sparkdash:latest`. (Necessary: the compose `build:` block has no `image:`
   key, so the image tag is project-scoped by release-directory name, which is why the new release
   gets a fresh build instead of reusing `mama-live-rates-20260930-sparkdash:latest`.)
4. Unit swap with backup, then `daemon-reload` and `systemctl restart sparkdash-boot.service`.

Unit diff as applied (`/etc/systemd/system/sparkdash-boot.service`, single line, backup
`sparkdash-boot.service.bak-20261007162148` kept beside it - matching the host's existing
`.bak-20260930`, `.bak-memfix-20260929`, `.bak-omlxlive-20260929` convention):

```diff
--- /etc/systemd/system/sparkdash-boot.service.bak-20261007162148
+++ /etc/systemd/system/sparkdash-boot.service
@@ -9,7 +9,7 @@
 # Wait up to 120s for tailscale0 to have an IPv4 address; publishing
 # 100.120.26.16:5556 cannot bind before tailscale is up.
 ExecStartPre=/bin/sh -c "for i in $(seq 1 120); do ip -4 addr show tailscale0 2>/dev/null | grep -q \"inet \" && exit 0; sleep 1; done; exit 1"
-ExecStart=/usr/bin/docker compose -f /home/kesslerio/sparkDash-releases/mama-live-rates-20260930/docker-compose.live.yml up -d --force-recreate
+ExecStart=/usr/bin/docker compose -f /home/kesslerio/sparkDash-releases/mac-node-20261007/docker-compose.live.yml up -d --force-recreate

 [Install]
 WantedBy=multi-user.target
```

**Wrinkle worth knowing:** the first boot restart failed with `Conflict. The container name
"/sparkDash-opencode-e2e" is already in use`. Both release directories declare the same
`container_name`, so the new compose project cannot claim the name while the old project's container
is still running; `--force-recreate` only recreates within its own project. The whole dashboard
stayed up on the old container throughout. Recovery was to release the name through the old project
and restart the unit:

```bash
docker compose -f /home/kesslerio/sparkDash-releases/mama-live-rates-20260930/docker-compose.live.yml down
sudo systemctl reset-failed sparkdash-boot.service
sudo systemctl restart sparkdash-boot.service
```

After that: `systemctl is-active` -> `active`, `docker ps` shows
`sparkDash-opencode-e2e  Up 10 seconds  5555/tcp, 100.120.26.16:5556->5556/tcp`, and
`docker inspect` reports `project=mac-node-20261007`, `image=mac-node-20261007-sparkdash`,
`restart=always`. `curl http://100.120.26.16:5556/` -> 200 and
`docker exec sparkDash-opencode-e2e ls /app/server/collectors` contains `MacAgentCollector.js`,
which is the deployment proof that the Mac-node merge is serving.

**Rollback is one command** (old release fully recoverable - dir, compose file, built image, and unit
backup all intact; it needs the same name-release step, so it is one compound line, not two commands):

```bash
sudo cp -a /etc/systemd/system/sparkdash-boot.service.bak-20261007162148 /etc/systemd/system/sparkdash-boot.service \
  && sudo systemctl daemon-reload \
  && docker compose -f /home/kesslerio/sparkDash-releases/mac-node-20261007/docker-compose.live.yml down \
  && sudo systemctl reset-failed sparkdash-boot.service \
  && sudo systemctl restart sparkdash-boot.service
```

## Stage 4 applied - the Mac entry

Backed up first per the host convention (`sparks.json.bak-before-macnode-20261007T162255`), then
`POST /api/sparks` against the live server:

```json
{"id":"mk-macbook-pro-5","name":"MK-MacBook-Pro-5","kind":"mac",
 "lanIp":"100.71.122.118","agent":{"host":"100.71.122.118","port":8790}}
```

- Response: `success: true`, `kind: "mac"`, `agent: {url: null, host: "100.71.122.118", port: 8790}`,
  `lanIp: 100.71.122.118`, `ssh.host` left empty so no credentials were stored, `role: standalone`.
- The field is `agent`, **not** `macAgent`, and `kind` is case-sensitive (`"MAC"` normalizes to
  `spark`) - corrected in the Stage 4 prep note below.
- `GET /api/sparks/mk-macbook-pro-5/metrics` -> `online: true`, `kind: mac`, hardware
  `Mac (Mac17,6)` / `Apple M5 Max` / 18 cores / 128 GB, `runtimes` = 3 entries all `serving`
  (`mtplx-mux` :8200, `tensorfold` :8300 `qwen3.8-27b`, `qflash` :11234), and
  `metrics.gpu.unavailable` = `cpu.perCore`, `gpu.utilization`, `gpu.power`, `ane.power`.
- Persistence confirmed: `config/sparks.json` on the host now has 5 entries including
  `mk-macbook-pro-5` with `agent = {host: 100.71.122.118, port: 8790}`, and that file sits in the
  host-mounted config directory, not the release directory.

## Decision taken

The ruling arrived through the task inbox at 2026-10-07T23:19Z: **Pick A, as recommended** - cut the
new release from `origin/main` at `aaddfe7`, stage the unit repoint with a backup, restart through the
boot unit rather than raw docker, confirm 5556 serves again, register the Mac (Apple Silicon Mac,
tailnet address, agent port 8790), verify vitals + runtime inventory + honest unavailable tiles, take
the overview screenshot with the MacBook present, leave `/opt/sparkDash` and `feat/llm-proxy-auth`
completely untouched, and finish when the old release is recoverable within one command. All of those
were met above; the alternatives are kept below for the record.



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

## Collection-path check (asked after the first report)

Question: is the MacBook being read through the new Mac-agent path or the SSH collector?

**Answer: the agent path is what serves this node, and it is the only working transport.** No second
entry was added, and nothing about the existing entry's auth was changed to make the errors stop.

Config proof - exactly one entry with that id, agent block set, no SSH target:

```
kind=mac  agent={'url': None, 'host': '100.71.122.118', 'port': 8790}  lanIp=100.71.122.118
ssh={'host': '', 'user': 'root', 'auth': 'key'}      # host empty: nothing is targeted over SSH
ids: ['qualitycorp', 'john', 'mama', 'ofus', 'mk-macbook-pro-5']
```

Runtime proof - `GET /api/sparks/mk-macbook-pro-5/metrics` returns `runtimes` (3 entries, all
`serving`, with ports and served model) plus the agent's `unavailable` declarations
(`cpu.perCore`, `gpu.utilization`, `gpu.power`, `ane.power`). Per `SparkMonitor.js:676`
("Only agent-backed units can report runtimes / declared gaps") those fields cannot come from the
SSH collector, so the agent answered.

The `[MacSystemCollector]` lines are a fallback that fires on an occasional agent miss, not a second
collector: `MacAgentCollector extends MacSystemCollector` and each `collectX()` ends with
`if (!snapshot) return super.collectX()`, where the parent builds its target from `lanIp` as
`root@100.71.122.118` rather than from the empty `ssh.host`. Burst structure over 40 minutes
(`docker logs -t` bucketed by timestamp) is exactly **6 lines per burst** - gpu, cpu, ram,
unifiedMemory, storage, network - one burst per failed snapshot, roughly 5 bursts per 10 minutes
(`23:40:42`, `23:46:00`, `23:46:05`, `23:48:58`, `23:51:00`, `23:51:58`, `23:52:04`, `23:54:26`,
`23:59:40`, `23:59:55`, `00:00:10`, `00:00:14`).

Why the misses happen, measured from john: 12 sequential `curl … :8790/metrics` calls gave
**2 timeouts at the 6 s cap, then 3.56 s, 2.26 s, 1.41 s, and eight fast answers at 0.03-0.10 s** -
so the first requests after a quiet period are slow while warm requests are instant. The collector's
own `FETCH_TIMEOUT_MS = 4000` (`MacAgentCollector.js:22`) turns one of those cold starts into a null
snapshot and therefore 6 fallback errors. `SNAPSHOT_TTL_MS = 1500` is why warm polls are free.
The agent serves with `ThreadingHTTPServer` (`sparkdash_mac_agent.py:847`) and shares one
2-second sample across close-together requests.

SSH is genuinely unavailable as a transport, which rules out silencing the fallback that way:
`timeout 8 ssh -o BatchMode=yes kesslerio@100.71.122.118 hostname` from john answers
`Permission denied (publickey,password,keyboard-interactive)`, and the container's read-only
`/home/kesslerio/.ssh` holds john's own `id_ed25519` only. So the honest remaining options, none of
them mine to take here, are (a) leave the noise, (b) a code change so an agent-configured unit does
not fall back to SSH, or (c) install a john->Mac key as `kesslerio`, which is a credential change
nobody asked me to make.
