#!/usr/bin/env python3
"""M0.08 sparse-brick memory model.

Answers the only question that matters before M1: given a residency fraction,
does an application-managed atlas actually use less memory than the dense
resources it replaces, once page tables, brick metadata, request buffers and
atlas packing slack are paid for?

Deliberately conservative in the directions the RFC calls out:
  * capacity is what costs memory, not momentary occupancy;
  * atlas dimensions round up to whole page slots;
  * the dense bytes removed are the *declared* dense sizes, i.e. the best case;
  * no credit is taken for driver-level dedup or compression.

Usage:
  python3 tools/memory_model.py [--cascades 6] [--format 16x8x16] [--json ...]
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

MIB = 1024 * 1024
BRICK_EDGE = 8
VOXELS_PER_BRICK = BRICK_EDGE ** 3

PAGE_ENTRY_BYTES = 16      # RFC section 6 layout sketch
BRICK_META_BYTES = 32      # RFC section 6 layout sketch
COUNTER_BYTES = 256
MAX_ATLAS_SLOTS_PER_AXIS = 2048   # 16384 texels / 8

FIELDS = {
    # name: (bytes per voxel, dense format)
    "light": (4, "R32_UINT"),
    "neighbour": (4, "R32_UINT"),
    "disocclusion": (1, "R8_UINT"),
}

CASCADE_FORMATS = {
    "16x8x16": (128, 64, 128),
    "16x16x16": (128, 128, 128),
    "16x16x16_50_PERCENT_HEIGHT": (128, 128, 128),
    "16x16x16_75_PERCENT_HEIGHT": (128, 128, 128),
}


def pack_atlas(capacity: int):
    """Smallest page-slot factorization >= capacity, near-cubic.

    Returns (px, py, pz, slots). Raises if capacity cannot fit the per-axis limit.
    """
    if capacity <= 0:
        return 0, 0, 0, 0
    best = None
    for px in range(1, MAX_ATLAS_SLOTS_PER_AXIS + 1):
        if -(-capacity // px) > MAX_ATLAS_SLOTS_PER_AXIS * MAX_ATLAS_SLOTS_PER_AXIS:
            continue
        remaining = -(-capacity // px)
        # choose py as the near-square divisor of remaining
        py = math.isqrt(remaining)
        while remaining % py != 0 and py < remaining:
            py += 1
        pz = -(-remaining // py)
        if py > MAX_ATLAS_SLOTS_PER_AXIS or pz > MAX_ATLAS_SLOTS_PER_AXIS:
            continue
        slots = px * py * pz
        if best is None or slots < best[3]:
            best = (px, py, pz, slots)
    if best is None:
        raise ValueError(f"capacity {capacity} exceeds atlas limits")
    return best


def model(cascades: int, cascade_format: str, mode: str, residency: float, split_pools: bool):
    w, h, d = CASCADE_FORMATS[cascade_format]
    bricks_per_cascade = (w // BRICK_EDGE) * (h // BRICK_EDGE) * (d // BRICK_EDGE)
    virtual_pages = bricks_per_cascade * cascades
    voxels = w * h * d * cascades

    fields = ["light"] if mode == "light_only" else ["light", "neighbour", "disocclusion"]
    dense_bytes = sum(FIELDS[f][0] for f in fields) * voxels

    pools = []
    if split_pools:
        for f in fields:
            cap = math.ceil(virtual_pages * residency)
            px, py, pz, slots = pack_atlas(cap)
            payload = slots * VOXELS_PER_BRICK * FIELDS[f][0]
            pools.append({"field": f, "capacity": cap, "atlas_slots": slots,
                          "atlas_dims": [px * BRICK_EDGE, py * BRICK_EDGE, pz * BRICK_EDGE],
                          "atlas_bytes": payload})
    else:
        cap = math.ceil(virtual_pages * residency)
        px, py, pz, slots = pack_atlas(cap)
        bpp = sum(FIELDS[f][0] for f in fields)
        pools.append({"field": "+".join(fields), "capacity": cap, "atlas_slots": slots,
                      "atlas_dims": [px * BRICK_EDGE, py * BRICK_EDGE, pz * BRICK_EDGE],
                      "atlas_bytes": slots * VOXELS_PER_BRICK * bpp})

    atlas_bytes = sum(p["atlas_bytes"] for p in pools)
    total_capacity = sum(p["capacity"] for p in pools)
    total_slots = sum(p["atlas_slots"] for p in pools)

    page_table_bytes = virtual_pages * PAGE_ENTRY_BYTES * (len(pools) if split_pools else 1)
    meta_bytes = total_capacity * BRICK_META_BYTES
    request_bitset = math.ceil(virtual_pages / 8) * (len(pools) if split_pools else 1)
    compacted_requests = total_capacity * 4 * (len(pools) if split_pools else 1)
    overhead = page_table_bytes + meta_bytes + request_bitset + compacted_requests + COUNTER_BYTES

    sparse_bytes = atlas_bytes + overhead
    net_saved = dense_bytes - sparse_bytes

    return {
        "mode": mode,
        "split_pools": split_pools,
        "residency": residency,
        "virtual_pages": virtual_pages,
        "bricks_per_cascade": bricks_per_cascade,
        "dense_bytes": dense_bytes,
        "dense_mib": round(dense_bytes / MIB, 3),
        "atlas_bytes": atlas_bytes,
        "atlas_mib": round(atlas_bytes / MIB, 3),
        "atlas_slack_slots": total_slots - total_capacity,
        "overhead_bytes": overhead,
        "overhead_mib": round(overhead / MIB, 3),
        "sparse_bytes": sparse_bytes,
        "sparse_mib": round(sparse_bytes / MIB, 3),
        "net_saved_bytes": net_saved,
        "net_saved_mib": round(net_saved / MIB, 3),
        "saving_ratio": round(net_saved / dense_bytes, 4) if dense_bytes else 0.0,
        "pools": pools,
    }


def break_even(cascades, fmt, mode, split_pools):
    """Largest residency fraction that still yields a net saving."""
    lo, hi = 0.0, 1.0
    if model(cascades, fmt, mode, 0.0, split_pools)["net_saved_bytes"] <= 0:
        return None
    for _ in range(60):
        mid = (lo + hi) / 2
        if model(cascades, fmt, mode, mid, split_pools)["net_saved_bytes"] > 0:
            lo = mid
        else:
            hi = mid
    return round(lo, 4)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cascades", type=int, default=6)
    ap.add_argument("--format", default="16x8x16", choices=sorted(CASCADE_FORMATS))
    ap.add_argument("--json", default=None)
    ap.add_argument("--markdown", default=None)
    ap.add_argument("--subsystem-mib", type=float, default=None,
                    help="HDDAGI subsystem total from the allocation accountant, for context")
    args = ap.parse_args()

    sweep = []
    for mode in ("light_only", "three_field"):
        for split in (False, True):
            if mode == "light_only" and split:
                continue
            be = break_even(args.cascades, args.format, mode, split)
            for r in (0.10, 0.25, 0.33, 0.50, 0.67, 0.75, 0.90, 1.00):
                row = model(args.cascades, args.format, mode, r, split)
                row["break_even_residency"] = be
                sweep.append(row)

    report = {
        "scenario": {"cascades": args.cascades, "cascade_format": args.format},
        "assumptions": {
            "brick_edge": BRICK_EDGE,
            "page_entry_bytes": PAGE_ENTRY_BYTES,
            "brick_meta_bytes": BRICK_META_BYTES,
            "max_atlas_slots_per_axis": MAX_ATLAS_SLOTS_PER_AXIS,
            "dense_bytes_removed": "declared dense sizes; best case, no driver slack",
            "capacity_is_cost": "allocated pool capacity, not momentary occupancy",
        },
        "sweep": sweep,
    }
    if args.json:
        Path(args.json).write_text(json.dumps(report, indent=2) + "\n")

    lines = []
    lines.append(f"# Sparse-brick memory model: {args.cascades} cascades, {args.format}\n")
    lines.append("Source-derived arithmetic. Capacity is what costs memory, not occupancy.\n")
    lines.append("| mode | pools | residency | dense MiB | atlas MiB | overhead MiB | net saved MiB | saving % of dense |")
    lines.append("|---|---|---|---|---|---|---|---|")
    for row in sweep:
        lines.append(
            f"| {row['mode']} | {'split' if row['split_pools'] else 'unified'} | {row['residency']:.0%} "
            f"| {row['dense_mib']:.2f} | {row['atlas_mib']:.2f} | {row['overhead_mib']:.2f} "
            f"| {row['net_saved_mib']:.2f} | {row['saving_ratio'] * 100:.1f}% |")
    be = {m: break_even(args.cascades, args.format, m, False) for m in ("light_only", "three_field")}
    lines.append("")
    lines.append("## Break-even residency\n")
    for m, v in be.items():
        lines.append(f"- `{m}`: net saving stays positive only below **{v:.1%}** residency." if v else f"- `{m}`: never positive.")
    if args.subsystem_mib:
        row50 = next(r for r in sweep if r["mode"] == "three_field" and not r["split_pools"] and r["residency"] == 0.5)
        lines.append("")
        lines.append("## Context against the whole HDDAGI footprint\n")
        lines.append(f"- HDDAGI subsystem at this scenario (M0.04): **{args.subsystem_mib:.1f} MiB**")
        lines.append(f"- Net saving at 50% three-field residency: **{row50['net_saved_mib']:.1f} MiB** "
                     f"= **{row50['net_saved_mib'] / args.subsystem_mib * 100:.1f}%** of the subsystem")
    text = "\n".join(lines) + "\n"
    if args.markdown:
        Path(args.markdown).write_text(text)
    print(text)


if __name__ == "__main__":
    main()
