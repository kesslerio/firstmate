#!/usr/bin/env python3
"""Adversarial lab run: a genuinely failed restoration must still alarm main."""
import json, os, subprocess, sys, time, pathlib

lab = pathlib.Path(os.environ["LAB"]); ctl = lab / "ctl"; state = lab / "home/state"
project = lab / "project"; hold = lab / "hold.ts"; hold_log = ctl / "hold.log"; arm_log = ctl / "arms.log"

def tail(p):
    try: return p.read_text()
    except FileNotFoundError: return ""

def wait_for(pred, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if pred(): return True
        time.sleep(0.05)
    return False

(state / ".wake-queue").write_text("1700000001\t1\tsignal\ttask-1\tsignal: lab-project/task-1 (queued)\n")
(state / "task-1.meta").write_text("project=lab-project\nwindow=lab-task-1\n")
(state / ".lock").write_text(f"{os.getpid()}\n")
for p in (hold_log, arm_log, ctl / "confirm.log", state / ".watch-extension.log"):
    p.write_text("")
for stale in list(ctl.glob("close-*")) + list(ctl.glob("released-*")) + list(ctl.glob("no-ready-*")) + [ctl / "counter"]:
    if stale.exists(): stale.unlink()
(ctl / "no-ready-2").write_text("unready\n")
(ctl / "no-ready-3").write_text("unready\n")

env = {k: v for k, v in os.environ.items() if k not in {
    "NO_MISTAKES_GATE", "FM_GATE_REFUSE_BYPASS", "FM_ROOT_OVERRIDE", "FM_STATE_OVERRIDE",
    "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_PROJECTS_OVERRIDE"}}
env.update({"FM_HOME": str(lab / "home"), "FM_ROOT_OVERRIDE": str(project),
            "FM_WATCH_EXTENSION_LOG_KEEP_LINES": "400", "FM_LAB_CTL": str(ctl),
            "FM_LAB_HOLD_LOG": str(hold_log), "FM_PI_ARM_READY_TIMEOUT_MS": "400",
            "FM_WATCH_REARM_RETRY_LIMIT": "1", "FM_WATCH_REARM_RETRY_BASE_MS": "10",
            "FM_WATCH_REARM_RETRY_MAX_MS": "20"})
proc = subprocess.Popen(["pi", "--mode", "rpc", "--no-session", "--no-mcp", "--no-skills",
                         "--no-prompt-templates", "-ne", "-e", os.environ["WATCH_EXT"], "-e", str(hold)],
                        cwd=str(project), env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=open(ctl / "pi.stderr", "wb"))
buf = b""; events = []
def send(obj):
    proc.stdin.write((json.dumps(obj) + "\n").encode()); proc.stdin.flush()
def pump(seconds):
    end = time.time() + seconds
    os.set_blocking(proc.stdout.fileno(), False)
    while time.time() < end:
        chunk = proc.stdout.read()
        if chunk:
            global buf
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if line.strip():
                    try: events.append(json.loads(line))
                    except Exception: pass
        else:
            time.sleep(0.02)
    os.set_blocking(proc.stdout.fileno(), True)
def call(obj, timeout=20):
    rid = obj.get("id"); send(obj)
    end = time.time() + timeout
    while time.time() < end:
        pump(0.2)
        for rec in events:
            if rec.get("type") == "response" and rec.get("id") == rid: return rec
    return None

result = {"checks": {}}
arm_resp = call({"id": "arm-1", "type": "prompt", "message": "/fm-watch-arm-pi"})
result["arm_command_response"] = arm_resp
result["checks"]["first_arm_started"] = wait_for(lambda: "start arm=1" in tail(arm_log), 20)
(ctl / "close-1").write_text("close\n")
result["checks"]["unready_successors_attempted"] = wait_for(lambda: "start arm=3" in tail(arm_log), 20)

def failure_in_main():
    resp = call({"id": "msgs", "type": "get_messages"}, timeout=10)
    body = json.dumps(resp)
    return "could not verify a ready successor watcher" in body, body
found, body = False, ""
end = time.time() + 25
while time.time() < end and not found:
    found, body = failure_in_main()
    if not found: time.sleep(0.5)
result["checks"]["typed_restoration_failure_reached_main"] = found
result["checks"]["branch_never_offered_the_failure"] = tail(hold_log) == ""
mresp = call({"id": "m2", "type": "get_messages"}, timeout=10)
result["main_messages"] = [m for m in json.loads(json.dumps(mresp or {})) .get("data", {}).get("messages", [])
                           if m.get("role") == "user"]
call({"id": "abort", "type": "abort"}, timeout=10)
pump(1.0)
result["arm_log"] = tail(arm_log).splitlines()
result["hold_log"] = tail(hold_log).splitlines()
result["extension_log"] = tail(state / ".watch-extension.log").splitlines()
try: proc.stdin.close()
except Exception: pass
try: proc.wait(timeout=20)
except subprocess.TimeoutExpired: proc.kill(); proc.wait()
print(json.dumps(result, indent=1))
