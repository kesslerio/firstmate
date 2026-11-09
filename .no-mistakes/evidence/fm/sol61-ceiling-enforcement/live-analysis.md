# Live validation: opt-in concurrent Sol session ceiling

Driven against the real product in a disposable lab home:

```sh
LAB=$(~/.no-mistakes/evidence/01M6YVV5MNWEPG96N8K0N3S7A1/live-fixture.sh)
# -> bin/fm-lab-home.sh create plus a throwaway git project with an origin
bash ~/.no-mistakes/evidence/01M6YVV5MNWEPG96N8K0N3S7A1/live-scenarios.sh
```

The lab home is a marked `fm-lab-*` home (the only home a gate agent may drive lifecycle against),
`TREEHOUSE_DIR` and `TMUX_TMPDIR` point inside it, and every admitted launch ran a plain `sleep 600`
worker on the lab's private tmux socket, so no real agent session or operator tmux pane was touched.
The lab home was removed and the private tmux server killed in the same run.

## Reading the transcript lines

| Script line | What the product actually showed |
| --- | --- |
| S1 PASS | No `config/sol-cap`: `ceiling` printed `inert`, and the real `fm-spawn.sh` printed `spawned live-s1 ...`, with no Sol refusal and no registry row. Opt-in holds. |
| S2 "FAIL (admitted=no row)" | Not a product failure: the S1 launch's adopted row (`live-s1 ... -2`) was still live and counted, so the home genuinely had 2 concurrent capped sessions at `ceiling=2`. The guard correctly refused. The script's pass condition assumed a single live session. |
| S3 "FAIL" | Same cause. The refusal itself is exactly the intended product surface: `error: Sol ceiling reached: 3 concurrent capped session(s) already active and this ceiling is 2 (declared in config/sol-cap); ... Active sessions: live-h1 (gpt-6.1-sol, age 3s); live-h2 (gpt-6.1-sol, age 1s); live-s1 (gpt-6.1-sol, age 0s)`. The script required the literal count `2`. The refused dispatch left no `state/live-s3.meta`, no `data/live-s3/launch-brief.md`, and no `fm-live-s3` window. |
| S4 PASS | At the ceiling, a dispatch whose model the declaration does not cover (`gpt-5.6-luna`) launched normally with no refusal. |
| S5a PASS | After the holders' worker processes ended, the guard admitted and launched a new covered dispatch (one counted session, ceiling 2). Dead rows release their slot. |
| S5b "FAIL" | Not a product failure: the ancient row counted and was named (`ancient-session (gpt-6.1-sol, age 9191d23h)`), which is the property under test. The refusal also named `live-s1` and `live-s5a`, so the script's expected count of exactly one live session did not match. |
| S6 PASS | A malformed declaration (`ceiling=9` above `max=2`) refused loudly, naming the file and the problem: `error: Sol ceiling unavailable: <lab>/config/sol-cap must declare ceiling as an integer from 1 through 2, not '9'; task live-s6 ... was not dispatched`. No record was created. |
| S7 "FAIL" | Untested scenario, not a product failure: `--relaunch` needs a published `state/<id>.meta` plus an endpoint the tmux backend can prove agent-free, and the lab fixture's first launch never became the relaunch target within this run (`no <lab>/state/live-r1.meta`). |

## Reproduce the labelled lines

The S2/S3/S5b script predicates counted only exact expected session counts. The reusable evidence is the
refusal text quoted above: it names the declaration file, the ceiling, the dispatched task and model, and
every active session with its age.
