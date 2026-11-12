#!/usr/bin/env python3
"""Sample a Mac host and newly spawned WebKit processes without Instruments/root.

Usage: python3 tools/profile-mac-resources.py out.json -- app --profile meadow frames.json
For an ordinary wallpaper run, add --duration 20 before -- to stop it gracefully.
WebKit attribution is by process creation during this isolated run, not parent PID
(XPC services are parented to launchd). Avoid starting other WebKit apps meanwhile.
CPU counters are cumulative nanoseconds; 100% CPU means one fully occupied core.
Physical footprints include shared allocations: their sum is not unique memory.
"""
import argparse
import ctypes
import json
import subprocess
import threading
import time
from pathlib import Path


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user_ns", "system_ns", "package_idle_wakeups", "interrupt_wakeups",
            "pageins", "wired_bytes", "resident_bytes", "footprint_bytes",
            "start_abstime", "exit_abstime", "child_user_ns", "child_system_ns",
            "child_idle_wakeups", "child_interrupt_wakeups", "child_pageins",
            "child_elapsed_abstime", "disk_read_bytes", "disk_write_bytes",
        )
    ]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def nanoseconds_per_tick():
    # proc_pid_rusage CPU times are Mach absolute-time units, not nanoseconds on ARM.
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    base = Timebase()
    system.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
    if system.mach_timebase_info(ctypes.byref(base)) or not base.denom:
        raise RuntimeError("cannot obtain Mach timebase")
    return base.numer, base.denom


def processes():
    result = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
    return {int(line.strip().split(None, 1)[0]): line.strip().split(None, 1)[1]
            for line in result.splitlines() if len(line.strip().split(None, 1)) == 2}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--duration", type=float)
    # Split explicitly so the child's flags are never interpreted as sampler flags.
    import sys
    if "--" not in sys.argv:
        parser.error("supply -- followed by the app command")
    split = sys.argv.index("--")
    args = parser.parse_args(sys.argv[1:split])
    command = sys.argv[split + 1:]
    if not command:
        parser.error("missing app command")
    if args.duration is not None and args.duration <= 0:
        parser.error("duration must be positive")
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(Usage)]
    lib.proc_pid_rusage.restype = ctypes.c_int
    numer, denom = nanoseconds_per_tick()
    before = set(processes())
    started = time.monotonic()
    records, log, candidates = [], [], {}
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, bufsize=1)

    def drain():
        for line in child.stdout:
            log.append({"seconds": time.monotonic() - started, "text": line.rstrip()})
            print(line, end="", flush=True)

    reader = threading.Thread(target=drain, daemon=True)
    reader.start()
    stop_at = None
    try:
        while child.poll() is None:
            now = time.monotonic() - started
            for pid, path in processes().items():
                if pid == child.pid or (pid not in before and "com.apple.WebKit." in path):
                    candidates[pid] = "host" if pid == child.pid else Path(path).name
            entries = []
            for pid, name in candidates.items():
                usage = Usage()
                if lib.proc_pid_rusage(pid, 2, ctypes.byref(usage)) == 0:
                    entry = {key: getattr(usage, key) for key in (
                        "user_ns", "system_ns", "package_idle_wakeups", "interrupt_wakeups",
                        "resident_bytes", "footprint_bytes", "start_abstime")}
                    for key in ("user_ns", "system_ns"):
                        entry[key.replace("_ns", "_ticks")] = entry[key]
                        entry[key] = entry[key] * numer // denom
                    entries.append({"pid": pid, "role": name, **entry})
            records.append({"seconds": now, "processes": entries})
            if args.duration is not None and now >= args.duration and stop_at is None:
                child.terminate()
                stop_at = time.monotonic()
            if stop_at is not None and time.monotonic() - stop_at > 5:
                child.kill()
            time.sleep(0.5)
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
        reader.join(timeout=5)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps({
            "schema": 1, "host_pid": child.pid, "exit_code": child.wait(),
            "attribution": "host plus newly spawned WebKit candidates; isolate other WebKit launches",
            "cpu_units": "cumulative nanoseconds; 100% = one CPU core",
            "mach_timebase": {"numer": numer, "denom": denom},
            "memory_note": "summed physical footprints can double-count shared allocations",
            "samples": records, "log": log,
        }, indent=2) + "\n")
    return child.returncode


if __name__ == "__main__":
    raise SystemExit(main())
