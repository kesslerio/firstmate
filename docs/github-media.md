# GitHub media delivery

Firstmate's optional media command publishes approved image/video bytes to an existing GitHub PR or issue and returns confirmed receipts to the normal body owner.
The [GitHub media skill](../.agents/skills/github-media/SKILL.md) is the agent entry point.
The [command module's help](../libexec/github-media/fm-github-media-state.py), printed by `bash bin/fm-github-media.sh --help`, is the sole owner of exact input schemas, supported body changes, dependency qualification, journal and handoff mechanics.

## Qualify before publication

Use a task-approved manifest, a qualified native runtime and explicit reviewed dependency paths and digests.
The parser is the immutable Nix store cmark-gfm 0.29.0.gfm.13 executable; the validator owns its options and content policy.
Keep the validator in a stable reviewed artifact location; do not silently follow a changing checkout or activated global hook.
The content-policy owner is ai-dotfiles `pr-body-lint` in explicit attachment-body mode.
Review the actual target's repository-local guidance before qualifying the validator; conflicting templates remain a hold, and existing issue edits do not acquire issue-creation templates.

Ordinary GitHub reads and body edits use `gh-axi`.
The native exception is limited to the reviewed helper's attachment edits.
Authentication and permission recovery remain operator-owned; no alternate identity, browser uploader or install fallback is implied.

## Run through the existing task worker

Use command help for preparation, publication, body-owner review, completion and recovery under the owning home/task.
Unknown outcomes, unreadable ownership and live descendants retain the claim even when a lock appears free.
Use the existing worker completion/hold path; the primary never waits in a foreground polling loop.

## Offline verification and remaining acceptance

Run the maintained synthetic behavioral tests through [the test runner](../bin/fm-test-run.sh):

```sh
bash bin/fm-test-run.sh tests/fm-github-media.test.sh tests/fm-github-media-hygiene.test.sh tests/fm-github-media-safety.test.sh
```

The [guarded real-policy test](../tests/fm-github-media-hygiene.test.sh) requires all four explicit reviewed policy/parser source paths and digests supplied as documented in its header.
With all four bindings absent it reports a gated omission, not a policy pass.
Partial, unsafe or stale bindings fail before effects.
Its backend remains synthetic even when the real validator is supplied; it never uploads or calls GitHub.
The [live acceptance guard](../tests/fm-github-media-live.test.sh) owns separately authorized target-specific acceptance.
Offline synthetic attestations, body hashes and attachment-shaped URLs do not establish real image rendering, video playback, remote byte equality or exactly-once publication.
