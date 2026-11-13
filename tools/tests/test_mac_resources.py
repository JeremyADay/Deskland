#!/usr/bin/env python3
"""Cross-check Mach CPU counter conversion against Python's process CPU clock."""
import ctypes
import importlib.util
import os
from pathlib import Path
import sys
import time

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "sampler", Path(__file__).resolve().parents[1] / "profile-mac-resources.py")
sampler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sampler)
lib = ctypes.CDLL("/usr/lib/libproc.dylib")
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(sampler.Usage)]
numer, denom = sampler.nanoseconds_per_tick()


def cpu_time():
    usage = sampler.Usage()
    assert lib.proc_pid_rusage(os.getpid(), 2, ctypes.byref(usage)) == 0
    return (usage.user_ns + usage.system_ns) * numer / denom / 1e9


before_counter, before_clock = cpu_time(), time.process_time()
# Burn CPU rather than sleeping; the clocks should agree even under scheduler contention.
while time.process_time() - before_clock < 0.2:
    pass
elapsed_counter, elapsed_clock = cpu_time() - before_counter, time.process_time() - before_clock
assert abs(elapsed_counter - elapsed_clock) < 0.01, (elapsed_counter, elapsed_clock)
print(f"Mach CPU conversion passed: counter={elapsed_counter:.4f}s, clock={elapsed_clock:.4f}s")
