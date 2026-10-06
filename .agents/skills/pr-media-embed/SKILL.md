---
name: pr-media-embed
description: Load before claiming a pull request done when its task owes screenshots, recordings, or other visual evidence, even if its body contains no media addresses, and whenever a PR's evidence renders broken for a reviewer. Owns the evidence-delivery procedure and verification receipt behind every done claim.
user-invocable: false
metadata:
  internal: true
---

# PR media embed

Evidence a reviewer cannot open is evidence that was not delivered, and a pull-request body can look perfectly correct while its media renders broken: the address was written against the local copy, the path is not in the commit that was pushed, or the address form resolves for the API token but not for a browser.
[`bin/fm-pr-media.sh`](../../../bin/fm-pr-media.sh) is the single owner of accepted media addresses, verification mechanics, exit codes, and corrections; read its header or help before running it.

The lane obligation, in order:

1. Put the media where the address can point.
   Commit it to the branch, or use an existing forge attachment.
   A file that exists only on a lane's disk has no address, so it cannot be verified at all.
2. Embed the evidence in the PR body using the address and media-position rules in the helper's header.
3. Run the absolute helper command supplied in the generated delivery instructions after the body exists on the forge, against the published body and head.
   When reading this skill directly, use the linked helper's header for invocation and require evidence addresses.
   Run it even when the body has no media addresses, so missing evidence fails.
4. Gate the done claim on a successful exit according to the helper's exit-code contract.
   A failure is not a formatting nuisance: the done line is not yet true, because the reviewer would be reading broken evidence.
5. Paste the receipt block into the PR's Evidence section, or into the report firstmate reads when the body is owned by the pipeline.
   The receipt is what makes the done claim checkable by someone who is not looking at this machine, and it is where a later reader learns which codes were actually observed.

The helper checks every rendered image variant and fetched media container according to its header; its receipt does not replace visual inspection or recording playback.
Apply the correction in each failing line and re-run.
