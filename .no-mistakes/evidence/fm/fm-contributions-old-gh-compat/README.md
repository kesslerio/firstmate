# Live validation: contribution polling on a gh too old for `api --slurp`

Change under test: `bin/fm-contributions.sh` now retrieves each paginated forge
read with `gh api <endpoint> --paginate` and assembles the pages locally with
`jq -s .` inside the same bounded read, instead of asking gh for
`--paginate --slurp` (a flag older GitHub CLI releases do not have).

## How the product was stood up

`live-drive.sh` runs the real `bin/fm-contributions.sh` (`poll`, `pending`,
`ack`, plus the registered check shim) against a disposable `FM_HOME` and a
local GitHub REST fixture (`api_server.py`) that serves **two pages per
paginated endpoint with real `Link: rel="next"` headers**. Every maintainer
signal sits on the second page, so a read that stops at page one cannot satisfy
the assertions. `harness-bin/gh` is the `gh` on PATH; it logs every invocation
and, in `real` modes, forwards `api` calls to a real GitHub CLI binary.

* `emu` mode — a stand-in that reproduces an older CLI: pages printed
  back-to-back, `--slurp` refused.
* `real` + `GH_245_BIN` — the unmodified upstream **gh 2.45.0** release binary
  (which has no `api --slurp`), pointed at the local fixture.
* `real` + installed gh — **gh 2.101.0**, for the no-regression case.

`api-request-log.txt` proves later pages were fetched (`...&page=2` requests);
`gh-argv-log.txt` proves the shipped code never asks for `--slurp`;
`contributions.json` is the durable persisted record.

## Scenarios driven (all pass, 49 assertions)

| scenario | result |
| --- | --- |
| poll an owned PR on a gh that rejects `api --slurp`: observation recorded from both pages, no unavailability, both second-page maintainer signals wake once | pass |
| re-poll does not re-ring; `pending` shows both signals; `ack` clears them with no replay | pass |
| poll a filed issue on that gh: second-page comment + `ready-for-pr` event surface, author/outsider comments filtered, no duplicates | pass |
| poll an owned PR with the **real gh 2.45.0** binary (no `api --slurp` at all) | pass |
| poll an owned PR with the installed gh 2.101.0 (no regression for current CLIs) | pass |
| the authenticated registered check surfaces the second-page signals on that gh | pass |
| adversarial: a corrupt page is a disclosed read failure with an error on the record, never silence | pass |
| adversarial: a page assembly that never returns is killed at the five-second read bound; poll stays silent (budget refusal, not forge failure), the prior record is byte-identical, no orphaned child survives | pass |
| regression reproduction: the pre-change script (`549e07f`) against the same **real gh 2.45.0** asks for `--paginate --slurp`, reports `observation unavailable`, records an error and wakes nothing | pass |

## Also exercised

* `bash tests/fm-contributions.test.sh` — the whole contributions behaviour
  suite, every case green (includes the old-gh pagination cases and the
  clock-pinned bounded-assembly case).
* `focused-contributions-clock.test.sh` — the three cases this change owns,
  run repeatedly to show the five-second reserve no longer depends on
  wall-clock seconds after the review round's clock pinning.
* `pr-check-security-suite.log` — `bash tests/fm-pr-check-security.test.sh`
  (45 assertions, no failures), whose fake gh now answers the product's
  bare-page reads, exercising the same retrieval surface through
  `bin/fm-pr-check.sh`.

## Re-run

```sh
SCRATCH=$(mktemp -d)
mkdir -p "$SCRATCH/base_pre"
git archive 549e07f37fd73aa01d74cd126b1111c99175abed bin | tar -x -C "$SCRATCH/base_pre"
curl -sSL -o "$SCRATCH/gh.zip" \
  https://github.com/cli/cli/releases/download/v2.45.0/gh_2.45.0_macOS_arm64.zip
(cd "$SCRATCH" && unzip -q gh.zip)
ROOT="$PWD" SCRATCH="$SCRATCH" EVIDENCE_DIR="$SCRATCH/out" \
  GH_245_BIN="$SCRATCH/gh_2.45.0_macOS_arm64/bin/gh" \
  bash live-drive.sh
```

Nothing here touched the operator's real `FM_HOME`, configuration, or gh
credentials: every run used a throwaway home, a throwaway `GH_CONFIG_DIR`, and a
fixture token, and the scratch tree was deleted afterwards.
