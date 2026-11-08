#!/usr/bin/env python3
"""Pixel diff between two captures, matching the metrics used in artifacts/lod.md.

    python3 tools/img_diff.py a.png b.png [--json out.json]

Reports:
  mean_abs    mean absolute per-channel delta, 0-255
  pct_gt8     percent of pixels whose largest channel delta exceeds 8/255
  max_diff    largest single channel delta
  thirds      pct_gt8 for the top/middle/bottom vertical thirds, so a change that
              only touches the sky band is distinguishable from a scene change
"""

import argparse
import json
import sys

import numpy as np
from PIL import Image


def diff(a_path: str, b_path: str) -> dict:
    a = np.asarray(Image.open(a_path).convert("RGB"), dtype=np.int16)
    b = np.asarray(Image.open(b_path).convert("RGB"), dtype=np.int16)
    if a.shape != b.shape:
        raise SystemExit(f"size mismatch: {a.shape} vs {b.shape}")
    d = np.abs(a - b)
    pix = d.max(axis=2)  # largest channel delta per pixel
    out = {
        "a": a_path,
        "b": b_path,
        "width": int(a.shape[1]),
        "height": int(a.shape[0]),
        "mean_abs": round(float(d.mean()), 3),
        "pct_gt8": round(100.0 * float((pix > 8).mean()), 3),
        "max_diff": int(d.max()),
    }
    h = a.shape[0]
    thirds = {}
    for name, (y0, y1) in {
        "top": (0, h // 3),
        "mid": (h // 3, 2 * h // 3),
        "bottom": (2 * h // 3, h),
    }.items():
        band = pix[y0:y1]
        thirds[name] = round(100.0 * float((band > 8).mean()), 3)
    out["thirds_pct_gt8"] = thirds
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--json")
    args = ap.parse_args()
    out = diff(args.a, args.b)
    if args.json:
        with open(args.json, "w") as f:
            json.dump(out, f, indent=2)
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
