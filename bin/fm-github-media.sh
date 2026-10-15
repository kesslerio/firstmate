#!/usr/bin/env bash
# fm-github-media.sh - optional approved native GitHub media entrypoint.
# Usage, schema, state and lease mechanics have one owner: the backing helper's
# module help, printed by fm-github-media.sh --help.
# Python 3 with stdlib fcntl is required only when using this command.
set -eu
if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' 'fm-github-media: Python 3 is required for media delivery; no operation started' >&2
  exit 2
fi
exec python3 -B "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/libexec/github-media/fm-github-media-state.py" "$@"
