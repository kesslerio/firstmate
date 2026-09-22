#!/usr/bin/env python3
"""fm-procinfo.py - ps-free process facts for bin/fm-session-lock-lib.sh.

Prints one line: <ppid>TAB<comm>TAB<args> for the pid given as argv[1],
using only sysctl(3) and libproc - the same kernel state `ps` reads, just
without executing /bin/ps. It exists because an EDR-style policy can deny
the ps binary's exec outright (even `ps -V`), and a session lock whose
identity walk needs ps can then never be acquired at all.

comm is the full executable path, matching `ps -o comm=`'s macOS semantics
of reporting argv[0]'s path, so the library's path-component harness match
keeps its evidence. args is the executable path followed by the recorded
argv tail.

Fail-closed by design: every read is verified against the requested pid
before anything is printed. No pid, no verification, no output - exit 1.

Usage: fm-procinfo.py <pid>
"""
import ctypes
import ctypes.util
import os
import struct
import sys

CTL_KERN = 1
KERN_PROC = 14        # CTL_KERN, KERN_PROC, KERN_PROC_PID: one kinfo_proc
KERN_PROC_PID = 1
KERN_PROCARGS2 = 49   # CTL_KERN, KERN_PROCARGS2, pid: exec path + argv + env
PROC_PIDPATHINFO_MAXSIZE = 4 * 4096

# kinfo_proc LP64 offsets: p_pid lives in kp_proc, the real parent pid in
# kp_eproc.e_ppid. These are assumptions, so _self_kinfo() proves them
# against this very process (os.getpid() / os.getppid()) before they are
# ever used on a requested pid, and a mismatch ends the run instead of
# reporting a guess.
P_PID_OFF = 40
E_PPID_OFF = 560


def _libc():
    return ctypes.CDLL(ctypes.util.find_library("c") or "libc.dylib",
                       use_errno=True)


_libc_cache = None


def libc():
    global _libc_cache
    if _libc_cache is None:
        _libc_cache = _libc()
    return _libc_cache


def _sysctl(mib):
    """Run a sysctl(3) mib, return the raw buffer, or None if it fails."""
    mib_arr = (ctypes.c_int * len(mib))(*mib)
    size = ctypes.c_size_t(0)
    ret = libc().sysctl(mib_arr, len(mib), None, ctypes.byref(size), None, 0)
    if ret != 0 or size.value == 0:
        return None
    buf = ctypes.create_string_buffer(size.value)
    ret = libc().sysctl(mib_arr, len(mib), buf, ctypes.byref(size), None, 0)
    if ret != 0:
        return None
    return buf.raw[: size.value]


def _self_kinfo():
    """Return this process's own kinfo_proc, only if both offsets verify.

    The buffer read for os.getpid() must carry os.getpid() at P_PID_OFF and
    os.getppid() at E_PPID_OFF. If either read disagrees, the layout
    assumption is wrong on this system and every ppid_of() call that uses
    these offsets returns None instead.
    """
    buf = _sysctl((CTL_KERN, KERN_PROC, KERN_PROC_PID, os.getpid()))
    if buf is None or len(buf) < E_PPID_OFF + 4:
        return None
    if struct.unpack_from("<i", buf, P_PID_OFF)[0] != os.getpid():
        return None
    if struct.unpack_from("<i", buf, E_PPID_OFF)[0] != os.getppid():
        return None
    return buf


def ppid_of(pid, offsets_verified):
    """Return the pid's parent pid, or None.

    offsets_verified is the self-kinfo proof that P_PID_OFF/E_PPID_OFF are
    right here; the target buffer must additionally describe exactly the
    pid asked for, so a mismatched or truncated read never reports a guess.
    """
    if offsets_verified is None:
        return None
    buf = _sysctl((CTL_KERN, KERN_PROC, KERN_PROC_PID, pid))
    if buf is None or len(buf) < E_PPID_OFF + 4:
        return None
    if struct.unpack_from("<i", buf, P_PID_OFF)[0] != pid:
        return None
    return struct.unpack_from("<i", buf, E_PPID_OFF)[0]


def exec_path(pid):
    """Return the executable path via libproc proc_pidpath, or None."""
    buf = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    n = libc().proc_pidpath(
        ctypes.c_int(pid), buf, ctypes.c_uint(PROC_PIDPATHINFO_MAXSIZE)
    )
    if n <= 0:
        return None
    try:
        return buf.raw[:n].split(b"\0", 1)[0].decode("utf-8")
    except UnicodeDecodeError:
        return None


def _procargs(pid):
    """Return (exec_path, argv_tail) via KERN_PROCARGS2, or (None, None)."""
    buf = _sysctl((CTL_KERN, KERN_PROCARGS2, pid))
    if buf is None or len(buf) < 4:
        return None, None
    argc = struct.unpack_from("<i", buf, 0)[0]
    if argc <= 0 or argc > 4096:
        return None, None
    # Layout: int32 argc, exec path (NUL), NUL padding, argc NUL-terminated
    # argv strings (argv[0] repeats the invoked name), then NUL padding,
    # then env strings we do not need.
    strings = buf[4:].split(b"\0")
    if not strings or not strings[0]:
        return None, None
    try:
        execfile = strings[0].decode("utf-8")
    except UnicodeDecodeError:
        return None, None
    argv = []
    for raw in strings[1:]:
        if not raw:
            continue  # padding before argv, and between argv and env
        if len(argv) >= argc:
            break
        try:
            argv.append(raw.decode("utf-8"))
        except UnicodeDecodeError:
            argv.append("?")
    # argv[0] is the invoked name; the caller already holds a verified
    # executable path, so only the tail after argv[0] adds information.
    return execfile, argv[1:]


def main():
    if len(sys.argv) != 2 or not sys.argv[1].isdigit():
        print("usage: fm-procinfo.py <pid>", file=sys.stderr)
        return 2
    pid = int(sys.argv[1])
    verified = _self_kinfo()
    ppid = ppid_of(pid, verified)
    if ppid is None:
        return 1
    path = exec_path(pid)
    if path is None:
        # proc_pidpath covers same-user processes unprivileged today, but if
        # it ever fails the argv exec field is the second source, and only a
        # verified exec path is worth reporting as comm.
        path, _ = _procargs(pid)
        if path is None:
            return 1
    _, argv_tail = _procargs(pid)
    if argv_tail is None:
        args = path
    else:
        args = " ".join([path] + argv_tail)
    sys.stdout.write("%d\t%s\t%s\n" % (ppid, path, args))
    return 0


if __name__ == "__main__":
    sys.exit(main())
