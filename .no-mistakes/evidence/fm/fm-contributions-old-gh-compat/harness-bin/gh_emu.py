"""Minimal gh api / gh pr view emulation for an older GitHub CLI.

gh api prints each fetched page as its own JSON document (no --slurp), so a
caller must assemble the pages itself. Links are followed from Link headers.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request

BASE = os.environ["GH_EMU_BASE"]
MODE = os.environ.get("GH_EMU_MODE", "emu")
# The gh binary to forward to: the installed current CLI, or a pinned older
# release that predates `api --slurp`.
REAL = os.environ.get("GH_EMU_REAL") or os.environ["GH_EMU_REAL_245"]


def emit(body):
    sys.stdout.write(body.decode())


def api(endpoint, paginate):
    url = BASE + "/" + endpoint
    while True:
        request = urllib.request.Request(url)
        with urllib.request.urlopen(request) as response:
            body = response.read()
            link = response.headers.get("Link", "")
        emit(body)
        if not paginate:
            return
        match = re.search(r'<([^>]+)>\s*;\s*rel="next"', link)
        if not match:
            return
        url = match.group(1)


def main(argv):
    if argv[0] == "api":
        endpoint = argv[1]
        paginate = "--paginate" in argv[2:]
        if MODE.startswith("real"):
            # Drive the real GitHub CLI binary, pointed at the local fixture.
            rest = [a for a in argv[2:] if a != "--paginate"]
            cmd = [REAL, "api", BASE + "/" + endpoint] + (["--paginate"] if paginate else []) + rest
            subprocess.run(cmd, check=True)
            return
        api(endpoint, paginate)
        return
    if argv[0] == "pr" and argv[1] == "view":
        doc = {"headRefOid": os.environ["GH_EMU_HEAD"], "reviewDecision": "APPROVED"}
        if "-q" in argv or "--jq" in argv:
            field = argv[(argv.index("-q") if "-q" in argv else argv.index("--jq")) + 1]
            doc = doc[field.lstrip(".") or "headRefOid"]
            emit(("%s\n" % doc).encode())
            return
        emit((json.dumps(doc) + "\n").encode())
        return
    sys.stderr.write("unexpected gh emu call: %s\n" % " ".join(argv))
    sys.exit(1)


main(sys.argv[1:])
