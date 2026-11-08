#!/usr/bin/env python3
"""M0.04 HDDAGI allocation accountant (source-derived).

Enumerates every texture and buffer that GI::HDDAGI::create() allocates, plus the
HDDAGI screen-probe group that lives in gi_hddagi_screen_probes.cpp, and reports
declared dimensions, format and estimated bytes.

What this is NOT:
  * It is not measured VRAM. Driver allocation granularity, compression, tiling
    and shared views are not modelled. The RFC explicitly forbids conflating the
    two, so every number here is tagged "source_derived".
  * It is not a runtime trace. No engine build was executed to produce it.

Each entry carries a `source` reference so a reviewer can check the formula
against the tree instead of trusting this script.

Usage:
  python3 tools/hddagi_allocations.py [--json PATH] [--csv PATH]
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

# ---------------------------------------------------------------------------
# Engine constants, copied from the source and cited.
# ---------------------------------------------------------------------------
MAX_CASCADES = 8          # gi.h:748
CASCADE_SIZE = 128        # gi.h:749
REGION_CELLS = 8          # gi.h:750
MAX_DYNAMIC_LIGHTS = 128  # gi.h:751
MAX_STATIC_LIGHTS = 1024  # gi.h:752
LIGHTPROBE_OCT_SIZE = 5   # gi.h:753
SOLID_CELL_RATIO = 0.5    # gi.h:943 hddagi_solid_cell_ratio default
SIZE_OF_LIGHT_PROCESS_CELL = 16      # gi.h:786-791, 4 x uint32
SIZE_OF_LIGHT = 112                  # gi.h:410-429 static_assert
SIZE_OF_INTEGRATE_CAMERA_UBO = 224   # gi.h:499-502, 56 floats
SIZE_OF_CASCADE_UBO = 48             # gi.h:761-767, 12 x 4 bytes

BYTES_PER_TEXEL = {
    "R8_UNORM": 1,
    "R8_UINT": 1,
    "R8G8B8A8_UNORM": 4,
    "R16_UINT": 2,
    "R16_SFLOAT": 2,
    "R32_UINT": 4,
    "R32_SFLOAT": 4,
    "R32G32_UINT": 8,
    "R16G16B16A16_SFLOAT": 8,
    "R32G32B32A32_UINT": 16,
    "E5B9G9R9_UFLOAT_PACK32": 4,
}

CASCADE_FORMATS = {
    # gi.cpp:362-380
    "16x8x16": (128, 64, 128, 1.0),
    "16x16x16": (128, 128, 128, 1.0),
    "16x16x16_50_PERCENT_HEIGHT": (128, 128, 128, 2.0),
    "16x16x16_75_PERCENT_HEIGHT": (128, 128, 128, 1.5),
}

MIB = 1024 * 1024


def tex3d(name, group, source, fmt, w, h, d, layers=1, shared=False, note=""):
    bpp = BYTES_PER_TEXEL[fmt]
    nbytes = 0 if shared else int(w) * int(h) * int(d) * int(layers) * bpp
    return {
        "name": name,
        "group": group,
        "kind": "texture_3d" if layers == 1 else "texture_2d_array",
        "source": source,
        "format": fmt,
        "bytes_per_texel": bpp,
        "width": int(w),
        "height": int(h),
        "depth": int(d),
        "array_layers": int(layers),
        "bytes": nbytes,
        "shared_view": shared,
        "note": note,
    }


def buf(name, group, source, nbytes, note=""):
    return {
        "name": name,
        "group": group,
        "kind": "buffer",
        "source": source,
        "format": "n/a",
        "bytes": int(nbytes),
        "note": note,
    }


def world_volume(cascades: int, cascade_format: str, history_frames: int, multibounce: bool):
    w, h, d, _ = CASCADE_FORMATS[cascade_format]
    C = cascades
    out = []

    # --- occupancy / source-of-truth group (gi.cpp:410-456) -----------------
    out.append(tex3d("voxel_bits_tex", "occupancy", "gi.cpp:411-420", "R32G32_UINT",
                     w // 4, (h // 4) * C, d // 4,
                     note="4x4 block bitfield, dense source of truth"))
    out.append(tex3d("voxel_region_tex", "occupancy", "gi.cpp:445-455", "R8_UINT",
                     w // REGION_CELLS, (h // REGION_CELLS) * C, d // REGION_CELLS,
                     note="8x8x8 region occupancy"))
    out.append(tex3d("region_version_data", "occupancy", "gi.cpp:424-432", "R16_UINT",
                     w // REGION_CELLS, (h // REGION_CELLS) * C, d // REGION_CELLS,
                     note="R16 wraps; cannot serve as page generation"))

    # --- migratable payload group (gi.cpp:436-479) --------------------------
    out.append(tex3d("voxel_light_tex_data", "payload", "gi.cpp:460-466", "R32_UINT", w, h * C, d,
                     note="packed radiance; E5B9G9R9 shared view added at gi.cpp:468-470"))
    out.append(tex3d("voxel_light_tex", "payload", "gi.cpp:468-470", "E5B9G9R9_UFLOAT_PACK32", w, h * C, d,
                     shared=True, note="shared view, no additional backing store"))
    out.append(tex3d("voxel_light_neighbour_data", "payload", "gi.cpp:473-478", "R32_UINT", w, h * C, d))
    out.append(tex3d("voxel_disocclusion_tex", "payload", "gi.cpp:435-441", "R8_UINT", w, h * C, d))

    # --- surface render targets (gi.cpp:481-507) ----------------------------
    out.append(tex3d("render_albedo", "surface_render", "gi.cpp:481-488", "R16_UINT",
                     w // 2, (h // 2) * C, (d // 2) * 6, note="anisotropic x6"))
    out.append(tex3d("render_emission", "surface_render", "gi.cpp:491-497", "R32_UINT",
                     w // 2, (h // 2) * C, d // 2))
    out.append(tex3d("render_emission_aniso", "surface_render", "gi.cpp:492-498", "R32_UINT",
                     w // 2, (h // 2) * C, d // 2))
    out.append(tex3d("render_aniso_normals", "surface_render", "gi.cpp:501-505", "R32_UINT", w, h * C, d))

    # --- light process buffers (gi.cpp:510-513, 617-624) --------------------
    solid_cells = int(float(w * h * d) * SOLID_CELL_RATIO)
    out.append(buf("light_process_buffer_render", "light_process", "gi.cpp:510",
                   SIZE_OF_LIGHT_PROCESS_CELL * solid_cells,
                   note=f"solid_cell_count={solid_cells} at ratio {SOLID_CELL_RATIO}"))
    out.append(buf("light_process_dispatch_buffer_render", "light_process", "gi.cpp:511", 16))
    for i in range(C):
        out.append(buf(f"cascades[{i}].light_process_buffer", "light_process", "gi.cpp:620",
                       SIZE_OF_LIGHT_PROCESS_CELL * solid_cells))
        out.append(buf(f"cascades[{i}].light_process_dispatch_buffer", "light_process", "gi.cpp:621", 16))
        out.append(buf(f"cascades[{i}].light_process_dispatch_buffer_copy", "light_process", "gi.cpp:622", 16))
        out.append(buf(f"cascades[{i}].light_position_bufer", "light_process", "gi.cpp:624",
                       SIZE_OF_LIGHT * max(MAX_STATIC_LIGHTS, MAX_DYNAMIC_LIGHTS)))

    out.append(buf("cascades_ubo", "uniform", "gi.cpp:513", SIZE_OF_CASCADE_UBO * MAX_CASCADES))

    # --- light probe group (gi.cpp:516-594) ---------------------------------
    pd = (w // REGION_CELLS, h // REGION_CELLS, d // REGION_CELLS)  # gi.cpp:516
    oct = LIGHTPROBE_OCT_SIZE + 2                                   # gi.cpp:522-523
    lp_w = (pd[0] + 1) * oct
    lp_h = (pd[1] + 1) * (pd[2] + 1) * oct
    for name in ("lightprobe_specular_data", "lightprobe_diffuse_data", "lightprobe_diffuse_filter_data"):
        out.append(tex3d(name, "lightprobe", "gi.cpp:519-532", "R32_UINT", lp_w, lp_h, 1, layers=C,
                         note="2D array, one layer per cascade"))
    for name in ("lightprobe_specular_tex", "lightprobe_diffuse_tex", "lightprobe_diffuse_filter_tex"):
        out.append(tex3d(name, "lightprobe", "gi.cpp:534-538", "E5B9G9R9_UFLOAT_PACK32", lp_w, lp_h, 1,
                         layers=C, shared=True))

    cache_w = (pd[0] + 1) * LIGHTPROBE_OCT_SIZE
    cache_h = (pd[1] + 1) * (pd[2] + 1) * LIGHTPROBE_OCT_SIZE
    cache_layers = C * history_frames
    out.append(tex3d("lightprobe_hit_cache_data", "lightprobe", "gi.cpp:540-546", "R32_UINT",
                     cache_w, cache_h, 1, layers=cache_layers, note="layers = cascades * frames_to_converge"))
    out.append(tex3d("lightprobe_hit_cache_version_data", "lightprobe", "gi.cpp:548-549", "R16_UINT",
                     cache_w, cache_h, 1, layers=cache_layers))
    out.append(tex3d("lightprobe_moving_average_history", "lightprobe", "gi.cpp:551-554", "R32_UINT",
                     cache_w, cache_h, 1, layers=cache_layers))
    out.append(tex3d("lightprobe_moving_average", "lightprobe", "gi.cpp:556-559", "R32_UINT",
                     cache_w * 3, cache_h, 1, layers=C, note="width *= 3 because there is no RGB32UI"))
    out.append(tex3d("lightprobe_ambient_tex", "lightprobe", "gi.cpp:562-567", "R16G16B16A16_SFLOAT",
                     pd[0] + 1, (pd[1] + 1) * (pd[2] + 1), 1, layers=C))
    out.append(tex3d("lightprobe_neighbour_visibility_map", "lightprobe", "gi.cpp:569-577", "R32_UINT",
                     pd[0] + 1, (pd[1] + 1) * (pd[2] + 1), 1, layers=C))
    out.append(tex3d("lightprobe_geometry_proximity_map", "lightprobe", "gi.cpp:579-582", "R8_UNORM",
                     pd[0] + 1, (pd[1] + 1) * (pd[2] + 1), 1, layers=C))
    out.append(tex3d("lightprobe_camera_visibility_map", "lightprobe", "gi.cpp:583", "R8_UNORM",
                     pd[0] + 1, (pd[1] + 1) * (pd[2] + 1), 1, layers=C))
    out.append(tex3d("lightprobe_process_frame", "lightprobe", "gi.cpp:591-593", "R32_UINT",
                     pd[0] + 1, (pd[1] + 1) * (pd[2] + 1), 1, layers=C))
    out.append(buf("lightprobe_camera_buffers", "lightprobe", "gi.cpp:585-589",
                   C * 4 * SIZE_OF_INTEGRATE_CAMERA_UBO, note="4 uniform buffers per cascade"))

    # --- occlusion (gi.cpp:596-615) -----------------------------------------
    for i in range(2):
        out.append(tex3d(f"occlusion_data[{i}]", "occlusion", "gi.cpp:598-610", "R16_UINT",
                         w + 2, (h + 2) * C, d + 2, note="+2 border on every axis for blending"))

    # --- optional multibounce albedo (gi.cpp:1271-1279) ---------------------
    if multibounce:
        out.append(tex3d("voxel_albedo_data", "multibounce_optional", "gi.cpp:1271-1279", "R16_UINT", w, h * C, d,
                         note="allocated lazily only when irradiance-cache multi-bounce is active"))
    return out


def screen_probes(resolution, half_res: bool, views: int, directional: bool,
                  adaptive: bool, probe_size: int, specular: bool, svgf: bool):
    """gi_hddagi_screen_probes.cpp:160-216, 532-570, 619-704."""
    internal_w = resolution[0] // (2 if half_res else 1)
    internal_h = resolution[1] // (2 if half_res else 1)
    gi_w, gi_h = internal_w, internal_h

    if directional:
        probe = 16                                  # SCREEN_PROBE_DIRECTIONAL_PROBE_SIZE, line 49
    else:
        probe = max(1, min(probe_size, 32))         # line 171
    base_x = math.ceil(gi_w / probe)
    base_y = math.ceil(gi_h / probe)

    dir_x, dir_y = base_x, base_y
    if directional and adaptive:
        capacity = (base_x * base_y) // 2           # CAPACITY_DIVISOR = 2, line 55
        rows = math.ceil(capacity / base_x) if capacity else 0
        dir_y = base_y + rows
    dir_atlas = (dir_x * 8, dir_y * 8)              # SCREEN_PROBE_DIRECTIONAL_SIZE = 8, line 50

    resolve = (internal_w, internal_h) if directional else (gi_w, gi_h)
    surface = (dir_x, dir_y) if directional else (base_x, base_y)
    surface_layers = views * 2 if directional else views
    hist_layers = views * 2

    out = []
    out.append(tex3d("screen_probe_surface", "screen_probe", "gi_hddagi_screen_probes.cpp:540",
                     "R32G32B32A32_UINT", surface[0], surface[1], 1, layers=surface_layers))
    out.append(tex3d("screen_probe_resolved_radiance", "screen_probe", "gi_hddagi_screen_probes.cpp:541",
                     "R16G16B16A16_SFLOAT", resolve[0], resolve[1], 1, layers=views))
    if directional:
        for name, fmt, size, layers in (
            ("directional_radiance", "R16G16B16A16_SFLOAT", dir_atlas, hist_layers),      # :543
            ("directional_history_age", "R8_UINT", (dir_x, dir_y), hist_layers),          # :544
            ("directional_filter_scratch", "R16G16B16A16_SFLOAT", dir_atlas, hist_layers),  # :545
            ("directional_irradiance", "R16G16B16A16_SFLOAT", dir_atlas, views),          # :546
            ("directional_trace_count", "R8_UINT", dir_atlas, views),                     # :547
            ("directional_adaptive_mark", "R8_UINT", (base_x, base_y), views),            # :548
            ("directional_adaptive_tile_data", "R32G32B32A32_UINT", (base_x, base_y), hist_layers),  # :549
        ):
            out.append(tex3d(name, "screen_probe", "gi_hddagi_screen_probes.cpp", fmt, size[0], size[1], 1, layers=layers))
        out.append(tex3d("directional_adaptive_counter", "screen_probe", "gi_hddagi_screen_probes.cpp:550",
                         "R32_UINT", 1, 1, 1, layers=views))
        out.append(tex3d("directional_ambient_u32", "screen_probe", "gi_hddagi_screen_probes.cpp:552-562",
                         "R32_UINT", internal_w, internal_h, 1, layers=views))
    else:
        out.append(tex3d("screen_probe_raw_radiance", "screen_probe", "gi_hddagi_screen_probes.cpp:569",
                         "R16G16B16A16_SFLOAT", base_x, base_y, 1, layers=views))
    if specular:
        for name, fmt in (("specular_raw", "R16G16B16A16_SFLOAT"),
                          ("specular_normal_roughness", "R8G8B8A8_UNORM"),
                          ("specular_view_z", "R32_SFLOAT"),
                          ("specular_motion", "R16G16B16A16_SFLOAT"),
                          ("specular_denoised", "R16G16B16A16_SFLOAT")):
            out.append(tex3d(name, "screen_probe_specular", "gi_hddagi_screen_probes.cpp:638-642",
                             fmt, gi_w, gi_h, 1, layers=views))
    if svgf:
        for name, fmt in (("denoiser_input", "R16G16B16A16_SFLOAT"),
                          ("denoiser_normal_roughness", "R8G8B8A8_UNORM"),
                          ("denoiser_view_z", "R32_SFLOAT"),
                          ("denoiser_motion", "R16G16B16A16_SFLOAT"),
                          ("denoiser_output", "R16G16B16A16_SFLOAT")):
            out.append(tex3d(name, "screen_probe_denoiser", "gi_hddagi_screen_probes.cpp:700-704",
                             fmt, resolve[0], resolve[1], 1, layers=views))
    return out


def build(scenario):
    entries = world_volume(scenario["cascades"], scenario["cascade_format"],
                           scenario["history_frames"], scenario["multibounce"])
    entries += screen_probes((scenario["width"], scenario["height"]), scenario["gi_half_res"],
                             scenario["views"], scenario["directional"], scenario["adaptive"],
                             scenario["probe_size"], scenario["specular"], scenario["svgf"])

    groups = {}
    for e in entries:
        g = groups.setdefault(e["group"], {"bytes": 0, "resources": 0})
        g["bytes"] += e["bytes"]
        g["resources"] += 1
    for g in groups.values():
        g["mib"] = round(g["bytes"] / MIB, 3)

    return {
        "scenario": scenario,
        "method": "source_derived",
        "caveat": "Declared allocation sizes from source arithmetic. Not measured VRAM.",
        "resources": entries,
        "groups": groups,
        "total_bytes": sum(e["bytes"] for e in entries),
        "total_mib": round(sum(e["bytes"] for e in entries) / MIB, 3),
    }


DEFAULT_SCENARIO = {
    "cascades": 6,
    "cascade_format": "16x8x16",
    "history_frames": 6,
    "multibounce": False,
    "width": 1920,
    "height": 1080,
    "gi_half_res": False,
    "views": 1,
    "directional": False,
    "adaptive": False,
    "probe_size": 8,
    "specular": True,
    "svgf": False,
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cascades", type=int, default=DEFAULT_SCENARIO["cascades"])
    ap.add_argument("--format", default=DEFAULT_SCENARIO["cascade_format"], choices=sorted(CASCADE_FORMATS))
    ap.add_argument("--history", type=int, default=DEFAULT_SCENARIO["history_frames"])
    ap.add_argument("--width", type=int, default=DEFAULT_SCENARIO["width"])
    ap.add_argument("--height", type=int, default=DEFAULT_SCENARIO["height"])
    ap.add_argument("--half-res", action="store_true")
    ap.add_argument("--views", type=int, default=1)
    ap.add_argument("--directional", action="store_true")
    ap.add_argument("--adaptive", action="store_true")
    ap.add_argument("--probe-size", type=int, default=DEFAULT_SCENARIO["probe_size"])
    ap.add_argument("--no-specular", action="store_true")
    ap.add_argument("--svgf", action="store_true")
    ap.add_argument("--multibounce", action="store_true")
    ap.add_argument("--json", default=None)
    ap.add_argument("--csv", default=None)
    args = ap.parse_args()

    scenario = {
        "cascades": args.cascades,
        "cascade_format": args.format,
        "history_frames": args.history,
        "multibounce": args.multibounce,
        "width": args.width,
        "height": args.height,
        "gi_half_res": args.half_res,
        "views": args.views,
        "directional": args.directional,
        "adaptive": args.adaptive,
        "probe_size": args.probe_size,
        "specular": not args.no_specular,
        "svgf": args.svgf,
    }
    report = build(scenario)

    if args.json:
        Path(args.json).write_text(json.dumps(report, indent=2) + "\n")
    if args.csv:
        lines = ["group,name,kind,source,format,width,height,depth,layers,bytes,mib,note"]
        for e in report["resources"]:
            lines.append(",".join(str(x).replace(",", ";") for x in (
                e["group"], e["name"], e["kind"], e["source"], e["format"],
                e.get("width", ""), e.get("height", ""), e.get("depth", ""),
                e.get("array_layers", ""), e["bytes"], round(e["bytes"] / MIB, 4), e.get("note", ""))))
        Path(args.csv).write_text("\n".join(lines) + "\n")

    print(f"{'group':28s} {'resources':>9s} {'MiB':>10s}")
    for g, v in sorted(report["groups"].items(), key=lambda kv: -kv[1]["bytes"]):
        print(f"{g:28s} {v['resources']:9d} {v['mib']:10.3f}")
    print(f"{'TOTAL':28s} {len(report['resources']):9d} {report['total_mib']:10.3f}")


if __name__ == "__main__":
    main()
