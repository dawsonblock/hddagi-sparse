#!/usr/bin/env python3
"""Summarizes bench JSONs as a distribution with spike counts, not just an average.

    python3 tools/analyze_runs.py artifacts/bench/cold_static_t1500.json ...

Prints a Markdown table. Columns:
  p50/p95/p99/max   frame time distribution in ms
  >33/>50/>80       frames over 33 ms (30 FPS), 50 ms and 80 ms
  time>50           total ms spent in frames over 50 ms (what a hitch feels like)
  worst#            index of the worst frame in the measured window
  start             process time to the scene being built (cold start), ms
"""

import json
import sys


def summarize(path):
    with open(path) as f:
        d = json.load(f)
    raw = d.get("raw_frame_ms") or []
    if not raw:
        raise SystemExit(f"{path}: no raw_frame_ms")
    over = lambda t: sum(1 for x in raw if x > t)  # noqa: E731
    worst_idx = max(range(len(raw)), key=lambda i: raw[i])
    timing = d.get("timing_ms") or {}
    return {
        "tag": d.get("tag", path),
        "p50": d["frame_ms"]["p50"],
        "p95": d["frame_ms"]["p95"],
        "p99": d["frame_ms"]["p99"],
        "max": d["frame_ms"]["max"],
        "o33": over(33),
        "o50": over(50),
        "o80": over(80),
        "time50": sum(x for x in raw if x > 50),
        "worst": worst_idx,
        "start": timing.get("scene_built", 0),
        "frames": len(raw),
        "trees": d.get("trees"),
        "camera": d.get("camera"),
        "gi": d.get("gi"),
        "sha": (d.get("binary_sha256") or "")[:12],
    }


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    rows = [summarize(p) for p in sys.argv[1:]]
    print("| tag | trees | cam | p50 | p95 | p99 | max | >33 | >50 | >80 | time>50 | worst# | start |")
    print("|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for r in rows:
        print(f"| {r['tag']} | {r['trees']} | {r['camera']} | {r['p50']:.2f} | {r['p95']:.2f} | "
              f"{r['p99']:.2f} | {r['max']:.1f} | {r['o33']} | {r['o50']} | {r['o80']} | "
              f"{r['time50']:.0f} | {r['worst']} | {r['start']} |")
    shas = {r["sha"] for r in rows}
    print()
    print(f"binary sha256 (first 12): {', '.join(sorted(shas))}")


if __name__ == "__main__":
    main()
