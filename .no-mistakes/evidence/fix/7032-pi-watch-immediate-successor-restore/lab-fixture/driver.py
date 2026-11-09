#!/usr/bin/env python3
"""Drive the real Pi CLI (RPC mode) with the worktree's Pi watch extension."""
import json, os, subprocess, sys, time, pathlib

lab = pathlib.Path(os.environ["LAB"])
ctl = lab / "ctl"
home = lab / "home"
state = home / "state"
project = lab / "project"
ext = os.environ["WATCH_EXT"]
hold = lab / "hold.ts"
hold_log = ctl / "hold.log"
arm_log = ctl / "arms.log"

def setup_queue():
    (state / ".wake-queue").write_text(
        "1700000001\t1\tsignal\ttask-1\tsignal: lab-project/task-1 (queued)\n"
        "1700000002\t2\tsignal\ttask-2\tsignal: lab-project/task-2 (queued)\n")
    for n in (1, 2, 3):
        (state / f"task-{n}.meta").write_text(f"project=lab-project\nwindow=lab-task-{n}\n")

def tail(path):
    try:
        return path.read_text()
    except FileNotFoundError:
        return ""

def wait_for(pred, timeout, desc):
    end = time.time() + timeout
    while time.time() < end:
        value = pred()
        if value:
            return value
        time.sleep(0.05)
    return None

class Pi:
    def __init__(self):
        env = {k: v for k, v in os.environ.items() if k not in {
            "NO_MISTAKES_GATE", "FM_GATE_REFUSE_BYPASS", "FM_ROOT_OVERRIDE",
            "FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_PROJECTS_OVERRIDE"}}
        env.update({
            "FM_HOME": str(home),
            "FM_ROOT_OVERRIDE": str(project),
            "FM_WATCH_EXTENSION_LOG_KEEP_LINES": "400",
            "FM_LAB_CTL": str(ctl),
            "FM_LAB_HOLD_LOG": str(hold_log),
        })
        self.events = []
        self.proc = subprocess.Popen(
            ["pi", "--mode", "rpc", "--no-session", "--no-mcp", "--no-skills", "--no-prompt-templates",
             "-ne", "-e", ext, "-e", str(hold)],
            cwd=str(project), env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=open(ctl / "pi.stderr", "wb"))
        self.buf = b""
        self.start = time.time()

    def send(self, obj):
        self.proc.stdin.write((json.dumps(obj) + "\n").encode())
        self.proc.stdin.flush()

    def read_events(self, deadline):
        """Drain available records until deadline, returning and recording them."""
        got = []
        os.set_blocking(self.proc.stdout.fileno(), False)
        while time.time() < deadline:
            chunk = self.proc.stdout.read()
            if chunk:
                self.events.extend(self._split(chunk))
                continue
            time.sleep(0.02)
        os.set_blocking(self.proc.stdout.fileno(), True)
        return got

    def _split(self, chunk):
        self.buf += chunk
        out = []
        while b"\n" in self.buf:
            line, self.buf = self.buf.split(b"\n", 1)
            if line.strip():
                try:
                    out.append(json.loads(line))
                except Exception:
                    out.append({"unparsed": line.decode("utf-8", "replace")})
        return out

    def response(self, rid, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            os.set_blocking(self.proc.stdout.fileno(), False)
            chunk = self.proc.stdout.read()
            os.set_blocking(self.proc.stdout.fileno(), True)
            if not chunk:
                time.sleep(0.02)
                continue
            for rec in self._split(chunk):
                self.events.append(rec)
                if rec.get("type") == "response" and rec.get("id") == rid:
                    return rec
        return None

    def stop(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()


def main():
    setup_queue()
    (state / ".lock").write_text(f"{os.getpid()}\n")
    for path in (hold_log, arm_log, ctl / "confirm.log", state / ".watch-extension.log"):
        path.write_text("")
    for stale in list(ctl.glob("close-*")) + list(ctl.glob("released-*")) + [ctl / "counter"]:
        if stale.exists():
            stale.unlink()
    if (ctl / "watcher-down").exists():
        (ctl / "watcher-down").unlink()
    pi = Pi()
    result = {"steps": [], "checks": {}}

    def note(name, value):
        result["checks"][name] = value
        result["steps"].append({"t": round(time.time() - pi.start, 3), **value} if isinstance(value, dict) else value)

    resp = pi.response("arm-1", timeout=25) if (pi.send({"id": "arm-1", "type": "prompt", "message": "/fm-watch-arm-pi"}) or True) else None
    note("arm_command_response", resp)

    ok = wait_for(lambda: "start arm=1" in tail(arm_log), 20, "arm1")
    if not ok:
        print(json.dumps({"fail": "arm 1 never started", "arm_log": tail(arm_log),
                          "stderr": tail(ctl / "pi.stderr"), "events": pi.events[-20:]}, indent=1))
        pi.stop()
        return 1

    (ctl / "close-1").write_text("close\n")
    ok = wait_for(lambda: "start arm=2" in tail(arm_log), 20, "arm2")
    note("successor_restored_after_close_1", bool(ok))

    ok = wait_for(lambda: '"event":"accepted"' in tail(hold_log), 15, "held")
    note("delivery_1_held_by_branch", bool(ok))

    # Second actionable close while the first wake delivery is still held.
    (ctl / "close-2").write_text("close\n")
    ok = wait_for(lambda: "start arm=3" in tail(arm_log), 20, "arm3")
    note("successor_restored_with_delivery_held", bool(ok))
    arm3 = [ln for ln in tail(arm_log).splitlines() if "arm=3" in ln]
    note("arm3_row", arm3[0] if arm3 else "")

    # Third actionable close while the first wake delivery is still held: the
    # successor that close 2 restored (gen3) is replaced by gen4 before the
    # queued wake for close 2 is ever delivered.
    (ctl / "close-3").write_text("close\n")
    ok = wait_for(lambda: "start arm=4" in tail(arm_log), 20, "arm4")
    note("third_successor_restored_with_delivery_held", bool(ok))
    arm4 = [ln for ln in tail(arm_log).splitlines() if "arm=4" in ln]
    note("arm4_row", arm4[0] if arm4 else "")

    pi.read_events(time.time() + 2.0)
    note("offers_before_release", [json.loads(l) for l in tail(hold_log).splitlines()] if tail(hold_log) else [])

    (ctl / "released-1").write_text("go\n")
    ok = wait_for(lambda: '"event":"accepted","n":2' in tail(hold_log), 20, "offer2")
    note("queued_wake_2_reached_branch_after_release", bool(ok))
    (ctl / "released-2").write_text("go\n")
    ok = wait_for(lambda: '"event":"accepted","n":3' in tail(hold_log), 20, "offer3")
    note("queued_wake_3_reached_branch_after_release", bool(ok))
    (ctl / "released-3").write_text("go\n")
    pi.read_events(time.time() + 2.0)
    arm4_pid = None
    for line in tail(arm_log).splitlines():
        if "arm=4" in line:
            arm4_pid = int(line.split("arm_pid=")[1].split()[0])
    note("successor_arm4_still_alive", bool(arm4_pid and os.path.exists(f"/proc/{arm4_pid}")))

    result["hold_log"] = [json.loads(l) for l in tail(hold_log).splitlines() if l.strip()]
    result["arm_log"] = tail(arm_log).splitlines()
    result["extension_log"] = tail(state / ".watch-extension.log").splitlines()
    result["confirm_log"] = tail(ctl / "confirm.log").splitlines()
    msgs = pi.send({"id": "msgs", "type": "get_messages"})
    mresp = pi.response("msgs", timeout=15)
    result["messages_response"] = mresp
    pi.read_events(time.time() + 0.5)
    result["events_tail"] = [e for e in pi.events if e.get("type") not in ("response",)][-40:]
    pi.stop()
    (ctl / "events.json").write_text(json.dumps(pi.events, indent=1))
    print(json.dumps(result, indent=1))
    return 0

sys.exit(main())
