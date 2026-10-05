---
name: pr-media-embed
description: Load before claiming a pull request done when its body carries a screenshot, recording, or any other evidence embed, and whenever a PR's evidence renders broken for a reviewer. Owns the evidence-embed contract: committed media, an address that resolves, and a verification receipt behind every done claim.
user-invocable: false
metadata:
  internal: true
---

# PR media embed

Evidence a reviewer cannot open is evidence that was not delivered, and a pull-request body can look perfectly correct while its media renders broken: the address was written against the local copy, the path is not in the commit that was pushed, or the address form resolves for the API token but not for a browser.
`bin/fm-pr-media.sh` is the single owner of what counts as a good media address, of how each shape is verified, and of the correction each failure needs; read its header or `--help` rather than learning the rules from prose.

The lane obligation, in order:

1. Put the media where the address can point. Commit it to the branch, or upload it with `bin/fm-pr-media.sh <pr> --attach <file>` and use the address it prints.
   A file that exists only on a lane's disk has no address, so it cannot be verified at all.
2. Write the evidence as a rendered embed in the body, at the published head, and never as a bare filename or a path relative to the repository: `bin/fm-pr-media.sh` refuses both, because neither resolves for a reviewer reading the pull request rather than this checkout.
3. Run `bin/fm-pr-media.sh <pr-number> --repo <owner>/<repo>` after the body exists on the forge, against the published body at the published head, never against a local draft of either.
   Add `--require-embeds` on any task whose deliverable includes visual evidence, so a body that quietly dropped every address fails instead of passing vacuously.
4. Act on the exit code, not on the prose around it: `0` means every address was proven, `1` means at least one was not, and `2` means something could not be read, which is never a pass.
   A failure is not a formatting nuisance: the done line is not yet true, because the reviewer would be reading broken evidence.
5. Paste the receipt block into the PR's Evidence section, or into the report firstmate reads when the body is owned by the pipeline.
   The receipt is what makes the done claim checkable by someone who is not looking at this machine, and it is where a later reader learns which codes were actually observed.

Every failing line in the receipt already names the correction to apply, including the head-pinned address to substitute, so fix the address as printed and re-run rather than reasoning about it from memory.
An upload the forge refuses is reported with the fallback: commit the file and address it at the head.
Do not spend the turn diagnosing the upload endpoint, and never report an attachment as verified from an unauthenticated fetch, because on a private repository the credential is what makes that address readable.

`--shape-only` exists for an offline dry run: it checks address shapes, prints `not-checked` where the network decides, and can never produce the green receipt a done claim cites.
