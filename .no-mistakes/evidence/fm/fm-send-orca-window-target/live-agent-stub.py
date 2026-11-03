#!/usr/bin/env python3
"""Disposable worker pane for live firstmate/Orca send checks.

Not the product under test: it only stands in for a harness TUI so the real
firstmate send path can type into a live Orca terminal and read a composer.
Modes: normal | dialog | exit-pending | exit-submitted
"""
import os, signal, sys, tty

log = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else "normal"
text = ""

def out(s):
    os.write(1, s.encode())

def draw():
    rule = "─" * (len(text) + 4)
    out("╭%s╮\n│ > %s │\n╰%s╯\n" % (rule, text, rule))

def append(path, line):
    with open(path, "a") as f:
        f.write(line + "\n")

tty.setraw(0)
if mode == "dialog":
    # A blocking picker owns the screen: no composer row below the footer, which
    # is exactly the recorded dialog shape fm-composer-lib detects.
    out("Background work is running\n❯ 1. Exit and stop tasks\nEnter to confirm · Esc to cancel\n")
    while True:
        try:
            b = os.read(0, 1)
        except OSError:
            break
        if not b or b == b"\x03":
            break
    raise SystemExit(0)
draw()
while True:
    try:
        b = os.read(0, 1)
    except OSError:
        break
    if not b:
        break
    c = b.decode("utf-8", "ignore")
    if c == "\x03":
        break
    if c in ("\r", "\n"):
        if mode == "swallow-first" and not os.path.exists(log + ".swallowed"):
            open(log + ".swallowed", "w").close()
            draw()
            continue
        append(log, text)
        out("submitted\n")
        text = ""
        draw()
    elif c == "\x7f":
        text = text[:-1]
        draw()
    elif c == "\x1b":
        continue
    elif c.isprintable():
        if not os.path.exists(log + ".started"):
            open(log + ".started", "w").close()
        text += c
        draw()
    if mode == "clear-after-line" and text.endswith("handled/."):
        text = ""
        draw()
        continue
    if mode == "hijack" and text.endswith("handled/."):
        # Another writer replaced the composer after firstmate typed its doorbell.
        text = "user draft now present"
        draw()
        continue
    if mode in ("exit-pending", "exit-pending-hard") and text == "/quit":
        append(log + ".pending", text)
        if mode == "exit-pending-hard":
            # Close the whole pane, not just this program: the recorded Orca
            # handle must become non-writable for the failed-Enter path.
            os.kill(os.getppid(), signal.SIGKILL)
        break
    if mode == "exit-submitted" and text == "/submit":
        append(log, text)
        text = ""
        out("submitted\n")
        draw()
        break
