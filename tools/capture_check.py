#!/usr/bin/env python3
"""Shared capture sanity checks.

A capture that exists on disk proves nothing: a missing import, a failed shader
or a dead GPU path all still write a PNG. Contrast (max - min) is the
load-bearing check -- a solid white frame has a high max and a high mean, so
brightness alone would accept it.

The capture line is JSON so paths containing spaces survive:
    CAPTURE_STATS {"path": "...", "min": 18, "max": 221, ...}

CLI, used by tools/bench_run.sh:
    python3 tools/capture_check.py --log run.log --marker BENCH_CAPTURE_STATS \
        --kind normal
"""

import argparse
import json
import sys

DEFAULT_MARKER = "CAPTURE_STATS "


def parse_stats(output, marker=DEFAULT_MARKER):
    """Returns every parseable stats object printed with `marker`."""
    stats = []
    for line in output.splitlines():
        i = line.find(marker)
        if i < 0:
            continue
        payload = line[i + len(marker):].strip()
        try:
            d = json.loads(payload)
        except json.JSONDecodeError:
            continue
        if isinstance(d, dict) and {"min", "max", "mean"} <= set(d):
            stats.append(d)
    return stats


def image_ok(stats, kind="normal"):
    """Rejects blank, flat and blown-out captures. Returns (ok, reason)."""
    if not stats:
        return False, "no stats reported"
    lo = int(stats["min"])
    hi = int(stats["max"])
    mean = float(stats["mean"])
    span = hi - lo
    if kind == "normal":
        if hi < 50:
            return False, f"too dark (max={hi})"
        if span < 30:
            return False, f"flat image (range={span})"
        # A rendered frame can be legitimately dark (a viewpoint under the canopy
        # measured mean 19 with range 246), so contrast is the gate and mean only
        # rejects a nearly-black frame with a single bright pixel.
        if mean < 5:
            return False, f"nearly black (mean={mean})"
        return True, f"range={span} mean={mean}"
    if hi < 20:
        return False, f"too dark (max={hi})"
    if span < 10:
        return False, f"flat image (range={span})"
    return True, f"range={span} max={hi}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--marker", default=DEFAULT_MARKER)
    ap.add_argument("--kind", default="normal", choices=["normal", "debug"])
    args = ap.parse_args()
    text = open(args.log, errors="replace").read()
    stats = parse_stats(text, args.marker)
    if not stats:
        print(f"FAIL no {args.marker.strip()} line in {args.log}", file=sys.stderr)
        return 1
    ok, why = image_ok(stats[-1], args.kind)
    if not ok:
        print(f"FAIL capture {args.kind}: {why}", file=sys.stderr)
        return 1
    print(f"ok   capture {args.kind}: {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
