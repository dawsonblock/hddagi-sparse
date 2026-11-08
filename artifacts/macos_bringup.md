# macOS bring-up — the fork builds and HDDAGI runs

Executed 2026-11-08 on Apple M2 Pro (12 CPU cores, 19 GPU cores, Metal 4), macOS 26.2.
This is the first time the supplied engine has been compiled or executed in this
project. It closes M0.02 for macOS and unblocks every later milestone's *engine*
half, though not the Vulkan-specific parts.

## Result

| step | outcome |
|---|---|
| SCons 4.11.1 installed (`pip install --user scons`) | ok |
| `scons platform=macos target=editor dev_build=yes vulkan=no -j12` | **ok**, 4,421 translation units, no errors |
| binary `bin/godot.macos.editor.dev.arm64` (270 MB) | ok, reports `4.8.dev.custom_build` |
| HDDAGI smoke project, 300 frames | **ok**, no shader or GPU errors |
| `Viewport.DEBUG_DRAW_HDDAGI` for 300 frames | **ok** |

Backend line from the run:

```
Metal 4.0 - Forward+ - Using Device #0: Apple - Apple M2 Pro (Apple8)
```

## Visual confirmation

An error-free run is not proof: a black frame is also error-free. Two frames were
captured and inspected.

`artifacts/visual_baseline/macos_normal.png` — the scene renders correctly: sky,
ground plane, five wall slabs, six boxes, directional shadows.

`artifacts/visual_baseline/macos_hddagi_debug.png` — `DEBUG_DRAW_HDDAGI` shows the
same scene as a blocky quantised volume on black. That is the voxelised cascade data,
drawn by reading the HDDAGI textures. The geometry is recognisably the same objects
at the same positions, which is what a correct cascade volume should look like.

This is the difference between "no errors were printed" and "the GI volume actually
contains the scene".

## Why the debug draw matters

`DEBUG_DRAW_HDDAGI` is not a pass-through. It renders the cascade volume by reading
`voxel_light_tex`, `voxel_bits_tex` and `voxel_region_tex` in `hddagi_debug.glsl`.
It cannot run without those resources existing and being readable. Running it for 300
frames without error is therefore evidence that HDDAGI actually initialised on Metal,
not merely that the scene loaded.

## The assumption that turned out to be wrong

Before building I expected HDDAGI to be impossible on macOS, because
`gi.cpp:460-470` creates the light texture with `shareable_formats` containing
`E5B9G9R9_UFLOAT_PACK32` and a shared view with that format override. Metal has no
`RGB9E5` in the core set as far as I knew.

It does: `drivers/metal/pixel_formats.cpp:451` maps
`E5B9G9R9_UFLOAT_PACK32 -> MTLPixelFormatRGB9E5Float`. Checking the mapping before
starting a multi-hour build was worth more than the build itself would have been.

## Build isolation

The build happens in a copy (`../hddagi-build/godot-dynamic_gi_2`), never in the
supplied tree. The supplied tree's hash is unchanged and re-verified after the build;
that is the whole reason the copy exists. `platform/build_and_run.sh` reproduces the
sequence.

Disk cost: 355 MB for the copy plus roughly 4 GB of objects. This machine had 20 GB
free, which is enough but not generous.

## What this proves

- The fork compiles cleanly with the development checks on.
- The renderer initialises on Metal 4 Forward+.
- HDDAGI allocates and populates its cascade resources on this backend.
- No shader compilation failures across the HDDAGI variants that the smoke scene
  exercises (integration, screen probes, preprocess, direct light, debug).

## What this does not prove

- **Nothing about Vulkan.** This is Metal. The M2 gate names Vulkan on the RTX 3080 Ti
  and remains unmet.
- **No numerical image comparison.** Frames were inspected by eye and archived, not
  compared against a reference with SSIM or an HDR diff. The captures establish that
  the pipeline produces a plausible image, not that it is correct.
- **Nothing about performance.** No timings, no frame times, no memory measurement.
- **Nothing about the sparse path**, which does not exist in the engine yet. The
  kernels are validated separately (`m2_scaffold.md`), but they are not wired in.
- Only one configuration: 6 cascades, 16x8x16, default screen-probe mode, one view.

## Next, in order

1. Capture a frame and confirm the image is sane, not just error-free. A black frame
   also produces no errors.
2. Sweep the cascade formats and screen-probe modes in the smoke project and record
   which variants compile on Metal.
3. Add the capability probe from `engine/RD_ADAPTER.md` as a startup check and log its
   verdict on Metal, which will show whether the sparse path would be accepted here.
4. Only then consider wiring the sparse kernels in on this platform, with the
   understanding that a Metal result does not satisfy the Vulkan gate.

## Warning seen

```
WARNING: Property not found: 'rendering/textures/streaming/enabled'.
```

This is pre-existing in the fork, unrelated to HDDAGI, and appears on every run. It is
recorded here so it is not mistaken for a new regression later.
