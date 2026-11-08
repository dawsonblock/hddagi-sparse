#!/usr/bin/env python3
"""Runs a command with a hard timeout and records peak RSS.

Used by tools/bench_run.sh instead of `/usr/bin/time -l` so a hung engine cannot
stall a benchmark forever. The child is started in its own session; on timeout the
whole process group is killed, so no orphan godot process survives.

Writes stats JSON:
  {"exit_code": int, "timed_out": bool, "max_rss_bytes": int, "elapsed_s": float}

Exit code is 124 on timeout (like timeout(1)), otherwise the child's exit code.
"""

import argparse
import json
import os
import resource
import signal
import subprocess
import sys
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--timeout", type=float, required=True, help="seconds")
    ap.add_argument("--log", required=True, help="combined stdout/stderr path")
    ap.add_argument("--stats", required=True, help="stats JSON path")
    ap.add_argument("command", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    cmd = args.command
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        print("run_timed.py: no command", file=sys.stderr)
        return 2

    started = time.monotonic()
    timed_out = False
    with open(args.log, "wb") as log:
        proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT,
                                start_new_session=True)
        try:
            code = proc.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                code = proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                code = proc.wait()
            code = 124
    elapsed = time.monotonic() - started

    rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    if sys.platform != "darwin":
        rss *= 1024  # Linux reports KiB
    stats = {
        "exit_code": code,
        "timed_out": timed_out,
        "max_rss_bytes": int(rss),
        "elapsed_s": round(elapsed, 3),
    }
    with open(args.stats, "w") as f:
        json.dump(stats, f)

    return 124 if timed_out else code


if __name__ == "__main__":
    sys.exit(main())
