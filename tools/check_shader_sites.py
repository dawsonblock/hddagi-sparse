#!/usr/bin/env python3
"""M0.06 coverage check for the payload access map.

Scans the HDDAGI shader directory for every declaration and access of the
per-voxel payloads and asserts that each one appears in artifacts/shader_sites.json.

The point is drift detection: when a later milestone adds a sparse read site and
forgets to register it, this check fails. Exit code 1 means the map is stale.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

WORKSPACE = Path(__file__).resolve().parent.parent
SHADERS = WORKSPACE.parent / "godot-dynamic_gi_2" / "servers" / "rendering" / "renderer_rd" / "shaders" / "environment"
SITES = WORKSPACE / "artifacts" / "shader_sites.json"

LIGHT = r"(?:light_cascades|hddagi_light_cascades)"
NEIGHBOUR = r"(?:voxel_neighbours|hddagi_voxel_neighbours)"
DISOC = r"hddagi_voxel_disocclusion"
ALBEDO = r"hddagi_albedo_cascades"

PATTERNS = [
    ("read", re.compile(rf"texelFetch\s*\(\s*sampler3D\s*\(\s*{LIGHT}")),
    ("read", re.compile(rf"imageLoad\s*\(\s*{NEIGHBOUR}")),
    ("read", re.compile(rf"imageLoad\s*\(\s*{DISOC}")),
    ("read", re.compile(rf"imageLoad\s*\(\s*{ALBEDO}")),
    ("write", re.compile(r"imageStore\s*\(\s*(?:dst_light|light_tex)\b")),
    ("write", re.compile(r"imageStore\s*\(\s*voxel_neighbours\b")),
    ("write", re.compile(r"imageStore\s*\(\s*dst_disocclusion\b")),
    ("write", re.compile(r"imageStore\s*\(\s*dst_albedo\b")),
    ("read", re.compile(r"\bload_voxel_neighbours\s*\(")),
    ("read", re.compile(r"\bload_voxel_disocclusion\s*\(")),
    ("declare", re.compile(r"layout\s*\([^)]*binding\s*=\s*\d+[^)]*\)\s*uniform[^;]*\b"
                           rf"(?:{LIGHT}|{NEIGHBOUR}|{DISOC}|{ALBEDO}|dst_light|light_tex|dst_disocclusion|dst_albedo)\s*;")),
]


def main() -> int:
    if not SHADERS.is_dir():
        print(f"shader directory not found: {SHADERS}")
        return 2
    if not SITES.exists():
        print(f"site map not found: {SITES}")
        return 2

    data = json.loads(SITES.read_text())
    registered = {(s["file"], s["line"]) for s in data["sites"]}

    found = set()
    for path in sorted(SHADERS.glob("hddagi_*.glsl")):
        for lineno, line in enumerate(path.read_text(errors="replace").splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith("//"):
                continue
            for _, pattern in PATTERNS:
                if pattern.search(line):
                    found.add((path.name, lineno))
                    break

    missing = sorted(found - registered)
    stale = sorted(registered - found)

    print(f"shader files scanned : {len(list(SHADERS.glob('hddagi_*.glsl')))}")
    print(f"sites in source      : {len(found)}")
    print(f"sites in map         : {len(registered)}")

    if stale:
        print("\nmap entries with no matching source line (renamed or removed):")
        for f, ln in stale:
            print(f"  {f}:{ln}")

    if missing:
        print("\nUNREGISTERED payload access sites (map is stale):")
        for f, ln in missing:
            print(f"  {f}:{ln}")
        return 1

    print("\nOK: every payload access in source is registered.")
    return 0 if not stale else 1


if __name__ == "__main__":
    sys.exit(main())
