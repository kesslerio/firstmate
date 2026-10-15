---
name: github-media
description: >-
  Load before publishing approved image/video attachments to an existing GitHub PR or issue,
  repairing its body for media delivery, placing confirmed media/captions, or handing off terminal target ownership.
user-invocable: false
metadata:
  internal: true
---

# GitHub media delivery

Use the optional [media command](../../../bin/fm-github-media.sh) through an already authorized worker in the owning home/task.
Its [module help](../../../libexec/github-media/fm-github-media-state.py) owns the exact schemas, allowed body edits, journal and recovery mechanics; read it before first use.
The [operator guide](../../../docs/github-media.md) explains prerequisites and qualification limits.

Keep the normal body owner responsible for wording, approvals and final review.
Return an invalid body to that owner for an explicitly approved repair before uploading.
After complete upload confirmation, obtain the reviewed final placement/captions draft; use the command's fixed `gh-axi` body edit under the same target lease.
Never turn a free lock, successful exit or uploaded URL into replay or completion authority.

Report confirmation, holds and evidence through the worker's existing completion/hold path in its launch brief and the supervisor's [task lifecycle](../../../AGENTS.md#7-task-lifecycle).
The primary does not foreground-poll delivery, and this skill introduces no listener, daemon, watch loop or standing readiness gate.
Independent rendered-image and video-playback review must supply its own evidence before completion; synthetic tests are not UI proof.
