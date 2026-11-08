#!/usr/bin/env python3
"""Convert the M1 JSON fixtures into the binary layout the probe shader consumes.

Layout is fixed and little-endian so a GPU test can upload the file directly:

  record, 80 bytes, stride 80:
    u32  cascade
    i32  position[3]
    i32  local[3]
    u32  expected_slot
    u32  expected_wrapped[3]
    i32  expected_region[3]
    u32  expected_texel[3]
    u32  pad[3]

Only records are written; grid metadata travels in push constants so the buffer
can be bound at offset zero without a header.
"""

from __future__ import annotations

import json
import struct
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parent
SRC = WORKSPACE / "tests" / "renderer_hddagi_sparse" / "fixtures" / "addressing_vectors.json"
OUT_DIR = HERE / "fixtures"

RECORD = struct.Struct("<I3i3iI3I3i3I3I")


def main() -> int:
    data = json.loads(SRC.read_text())
    cases = data["cases"]
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    blob = bytearray()
    for c in cases:
        blob += RECORD.pack(
            c["cascade"],
            c["position"][0], c["position"][1], c["position"][2],
            c["local"][0], c["local"][1], c["local"][2],
            c["virtual_slot"],
            c["wrapped"][0], c["wrapped"][1], c["wrapped"][2],
            c["region"][0], c["region"][1], c["region"][2],
            c["atlas_texel"][0], c["atlas_texel"][1], c["atlas_texel"][2],
            0, 0, 0,
        )

    assert RECORD.size == 80, RECORD.size
    (OUT_DIR / "probe_fixtures.bin").write_bytes(blob)

    meta = {
        "count": len(cases),
        "record_bytes": RECORD.size,
        "layout": data["layout"],
        "atlas_page_slots": [8, 8],
    }
    (OUT_DIR / "probe_fixtures.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(f"wrote {len(cases)} records, {len(blob)} bytes, stride {RECORD.size}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
