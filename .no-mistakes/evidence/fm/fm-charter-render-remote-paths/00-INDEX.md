# Live validation: remote-route secondmate charters name host-local paths

The product surface here is the charter file a secondmate agent obeys. Every
artifact below is the real generated charter, or the real CLI transcript that
produced it, from a drive of the shipped scripts against isolated temp homes.
No real fleet home, Herdr session, or remote host was touched.

| file | what it shows |
|---|---|
| `01-fm-brief-remote-route-charter.md` | `bin/fm-brief.sh` with `FM_SECONDMATE_REMOTE_HOME` renders `<remote-home>/state/parent-route/<id>.inbox` and `<remote-home>/state/parent-replies.status`; zero parent-home paths remain. `-full.md` is the whole charter. |
| `02-local-route-charter-unchanged.md` | A local-route charter is byte-identical to the base commit's rendering. |
| `03-remote-home-input-guards.md` | Relative, newline-bearing, quote-bearing, and non-secondmate uses of the new input are refused before anything is written. |
| `04-rehome-remote-to-local.md` | Remote -> local rehome. Base commit publishes the retired host's paths into a local mate (4 mentions); the change publishes this home's own paths (0). |
| `05-remote-seed-and-rehome.md` | Full `bin/fm-remote-home-seed.sh` drive over the deterministic local SSH boundary, plus retire-and-rehome onto a replacement host. Compared against 990e590, where the rehomed mate is still pointed at the retired host. |
| `06-adversarial-path-shapes.md` | Nine remote-home path shapes (spaces, `[]`, `$`, `&`, `*`, dots, prefix overlap, trailing slash) all converge at publish. |
| `07-remote-seed-quote-guard.md` | A single-quoted destination home is refused before the route or durable charter exists. |
| `08-documented-hand-scaffold-flow.md` | The flow docs/remote-secondmates.md now documents, driven verbatim. |
| `fm-brief.test.log`, `fm-secondmate-safety.test.log`, `fm-remote-secondmate-lifecycle-e2e.test.log` | The repository suites that own these paths. |

Reference commits: base `8c1cdb7`, renderer-only intermediate `990e590`, change `ddf1e44`.
