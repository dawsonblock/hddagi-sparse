# hddagi-sparse — M0 work tree

Working area for the HDDAGI sparse-brick cascade proposal. Nothing here modifies the
supplied source trees; every tool reads them read-only.

## Layout

```
artifacts/
  manifest.json           source provenance: archive hash, per-tree hashes, version, VCS state
  engine_version.txt      one-line identity of the engine tree
  allocations.json        every HDDAGI texture/buffer, declared dims, format, estimated bytes
  allocations.csv         same, flat
  shader_sites.json       every payload declaration/read/write across the HDDAGI shaders
  memory_model.json       residency sweep, atlas packing, overhead, break-even
  memory_model.md         readable version of the same
  decision.md             M0.09 record: what passed, what is blocked, recommendation
  m1_report.md            M1 record: semantics, test inventory, mutation evidence
  m2_scaffold.md          M2 scaffold: capability table, shader map, integration recipe
  macos_bringup.md        engine builds and HDDAGI renders on Metal
  light_process_buffers.md measured: 56 -> 28 MiB default (11.2 MiB safe) on a dense forest
  phase2_baseline.md      measured: frame times, GI cost 0.7-3.4 ms, teleport hitch
  teleport_hitch.md       root cause + fix: worst frame 106 -> 64 ms, stutter -90%
  wind.md                 foliage sway: globals registered, calibrated, ~0.1 ms cost
  frame_budget.md         where the frame goes; grass shadows removed for 15.5%
  bench/                  per-run JSON from the Phase 2 harness; README.md indexes it
  app_package.md          packaged app provenance: hashes, checks, limitations
  app_build/              per-build manifest, report and logs (captures are local)
  bench_hardening.md      why a failed bench run cannot look like a speedup
  cold_start.md           packaged 1,500-tree cold vs warm, distributions and hitches
  lod.md                  distance tree LOD + shadow LOD: -21.8%, 0.8% of pixels
tests/renderer_hddagi_sparse/
  hddagi_brick_layout.h       grid, coordinate conversion, atlas addressing
  hddagi_brick_allocator.*    page table, states, generations, scroll replay
  test_*.cpp                  43 cases, dependency-free
  run_tests.sh                build + run
  fixtures/                   deterministic GPU-facing vectors
engine/
  hddagi_sparse_plan.h/.cpp   capability checks + dispatch planning, no RD dependency
  test_sparse_plan.cpp        15 cases
  RD_ADAPTER.md               uncompiled RenderingDevice integration recipe
gpu/
  shaders/                    four compute shaders, compiled and SPIR-V validated
  hddagi_sparse_gpu_model.h   CPU twin of those shaders, same byte layouts
  test_gpu_model.cpp          7 cases: fixture parity, allocator invariants, canary
  make_fixture_bin.py         JSON fixtures -> 80-byte binary records
  build.sh                    compile shaders + validate + run twin tests
  run_gpu_tests.sh            execute the kernels on this GPU (Metal)
  metal/                      Swift harnesses for probe, canary and allocator
platform/
  RUN_ON_MAC.md               how to launch the app and see the self-test
  make_mac_app.sh             stage, validate and swap the double-clickable app
  verify_app.py               bundle provenance + headless and rendered smoke checks
  test_verify_app.py          capture-parser and image-check regressions
  engine_changes.patch        every engine change as a diff against the supplied tree
  build_and_run.sh            build in a copy, run the smoke project
  test_project/               HDDAGI smoke scene with frame capture, plus bench.gd
    hddagi_hud.gd             performance HUD, top-left; autoloaded, F3 toggles
    hddagi_wind.gd            registers the foliage wind globals and gusts them
    hddagi_settings_menu.gd   F1 menu: wind, lighting, fog, overlay toggle
tools/
  make_manifest.py        M0.01
  hddagi_allocations.py   M0.04
  check_shader_sites.py   M0.06 coverage enforcement
  memory_model.py         M0.08
  bench_run.sh            Phase 2 runner: one config -> artifacts/bench/<tag>.json
  capture_check.py        blank/flat capture rejection, shared by app and bench checks
  test_failure_modes.sh   failure-injection regressions for bench and packaging
  profile_cold_warm.sh    {cold,warm} x {static,teleport,cut} on the packaged config
  analyze_runs.py         distributions and spike counts from bench JSON
  check_engine_copies.sh  verifies platform/ copies and that the patch reproduces them
```

## Status

**Engine builds and runs on macOS. M0 partially complete, M1 complete, M2 kernels
execute on GPU behind an opt-in gate but do not light anything yet, and Phase 2 frame
times are measured.**

- **The fork builds and runs on this Mac** (Metal 4, Forward+): 4,421 translation
  units, HDDAGI smoke scene renders, `DEBUG_DRAW_HDDAGI` shows the voxelised volume.
  See `artifacts/macos_bringup.md`. The Windows/Vulkan path is still unbuilt, so
  M0.05 and M0.07 (GPU counters and timings) remain blocked.
- **Frame times and resident memory are now measured** (`artifacts/phase2_baseline.md`):
  GI costs 4.9–8.6 ms per frame (17–30%) in a 600-tree forest, rising with camera
  dynamism (static 4.92, move 6.20, teleport 8.55 ms). Every teleport costs a ~100 ms
  hitch that does not occur with GI off. HDDAGI's resident footprint is ~100 MB, about
  a third of the 291.6 MiB declared estimate — and the 56 → 11.2 MiB light-process
  reduction changes neither frame time nor resident memory, so it is an allocation
  saving rather than a residency saving. GPU timestamps do not exist on the Metal
  driver in this fork, so these are wall-clock frame times with CPU render time
  recorded alongside as a GPU-bound check.
- **The frame budget is measured** (`artifacts/frame_budget.md`). Shadows are 38% of
  the frame, more than GI, volumetric fog and MSAA combined. Grass shadow casting cost
  4.44 ms and changed 0.01% of pixels, so it is now off: **28.60 → 24.16 ms, 35 → 41
  FPS**. Shadow map resolution was ruled out as a lever (4096 → 1024 saves 0.34 ms);
  the cost is geometry, not fill rate.
- **The teleport hitch is fixed** (`artifacts/teleport_hitch.md`). A teleport marked
  every cascade dirty and rebuilt all six in one frame; at ~13-15 ms per cascade that
  was a ~100 ms freeze. `rendering/global_illumination/hddagi/full_rebuild_budget`
  (default 1) now spreads them: worst frame 106 -> 64 ms, frames over 80 ms 9 -> 0,
  total time in frames over 50 ms 1325 -> 127 ms (-90%), median unchanged. Converged
  images are identical (0.007% of pixels); only the transition differs. A separate,
  larger defect remains: first visit to a viewpoint costs ~700 ms per frame for
  several frames, which is synchronous pipeline compilation, not cascade work.
- M1 (CPU oracle) is complete: 43 test cases pass, clean under ASan/UBSan, and the
  suite is proven to fail under deliberate mutation.
- M2 kernels **execute on this machine's GPU** (Apple M2 Pro, Metal): translation
  parity 1,180/1,180, atlas canary 524,288/524,288 texels, allocator invariants hold.
  The capability/dispatch decision core is tested (15 cases). They are now behind
  `rendering/global_illumination/hddagi/sparse_enabled` (default false), which runs the
  probe/self-test only; there is no radiance store or atlas sampling, so the dense
  renderer remains authoritative. `artifacts/sparse_status.md` records the gate, the
  image-parity/RSS measurements and the exact missing pieces. The M2 gate still names
  Vulkan on the RTX 3080 Ti, so it is not met. See `artifacts/m2_scaffold.md`.

Read `artifacts/decision.md` for the M0 gate and `artifacts/m1_report.md` for M1.

No number in `artifacts/` is a VRAM measurement. They are source-derived arithmetic.

## Foliage wind

The forest sways. The foliage shaders declare five `global uniform` wind parameters and
every material already sets `wind_enabled = true`, but nothing in this fork registered
them, so every material warned "Shader uses global parameter ... but it was removed"
on every frame and nothing moved. `platform/test_project/hddagi_wind.gd` registers them
and drives a gust envelope on `wind_power`.

Only `wind_power` is animated: `wind_velocity`, `wind_turbulence` and
`wind_sway_frequencies` are **phase** terms in the shader (`wind_time = TIME -
dot(world_pos.xz, wind_effective_velocity)`), so varying them pops the whole forest at
once. Details and calibration in `artifacts/wind.md`.

Measured: 46% of pixels change between frames 3 s apart with a static camera, at a cost
of **≤0.1 ms** — the shader was already running the wind branch, so enabling it changes
values, not instruction count. `HDDAGI_WIND=0` pins `wind_power` to zero while leaving
the globals registered, so the shaders take the same path and log the same warnings as
with wind on while the foliage stays still; the benchmark runner sets that so timings
stay comparable with the pre-wind baseline. Capture mode (`HDDAGI_CAPTURE=1`) turns wind
off for the same reason it hides the HUD: captures are compared pixel for pixel.

## Distance LOD

The forest is split into three camera-relative distance rings: near (< 35 m) at lod0,
mid (35-75 m) at lod1, far (> 75 m) at lod2, with the far ring not casting shadows. The
rings are rebuilt when the camera moves 5 m. At 1,500 trees that is
**37.41 -> 29.37 ms p50 (-21.5%)**, every measured frame under 33 ms in the repeat run,
and 0.80% of pixels changing by more than 8/255; teleport hitch time drops 64%.
`HDDAGI_LOD=0` puts every tree back at lod0, `HDDAGI_SHADOW_LOD=off` restores all
shadows, and `HDDAGI_LOD_NEAR` / `HDDAGI_LOD_MID` move the boundaries. The benchmark
harness defaults to off so the old baseline stays reproducible. Details and the quality
table are in `artifacts/lod.md`.

## Settings menu (F1)

`platform/test_project/hddagi_settings_menu.gd` adds a panel on the right, opened and
closed with **F1**, that adjusts the running scene live:

| section | controls |
|---|---|
| Wind | enabled, strength, gust depth |
| Lighting | HDDAGI indirect on/off, GI energy, sun energy, sun elevation, sun azimuth, ambient, exposure |
| Fog | depth fog on/off + density, volumetric fog on/off + density, length, anisotropy |
| Overlay | show CPU / GPU / FPS (same switch as F3) |

It locates the scene's `WorldEnvironment` and `DirectionalLight3D` when it opens rather
than requiring the scene to register them, so it works in both `main.tscn` and
`bench.tscn`, and it re-reads the live values on every open so the controls never
disagree with the scene.

Wind strength and gust depth are the only wind controls exposed, because the other wind
parameters are phase terms in the shader and would pop the forest — see `artifacts/wind.md`.

Cost is **+0.007 ms** while open and zero when closed (its `_process` is disabled
outside the open state). `HDDAGI_MENU=0` disables it entirely; `tools/bench_run.sh`
sets that so benchmark timings are unaffected.

## Performance HUD

The running project shows a HUD in the top-left, autoloaded from
`platform/test_project/hddagi_hud.gd`:

```
19.0 FPS  peak 147.5
frame 37.49 ms
cpu   2.80 ms   7%
gpu  34.69 ms  93% (est)
mem  81.8 MB
```

- `FPS` is wall-clock rate; it turns amber below 55 and red below 30.
- `peak` appears only when the worst frame in the refresh window is more than twice
  the mean, so a hitch is not averaged away.
- `cpu` is `viewport_get_measured_render_time_cpu` and its share of the frame.
- `gpu` is `viewport_get_measured_render_time_gpu` where the backend supports it.
  **On Metal in this fork it always reads 0** — `rendering_device_driver_metal.cpp:2430`
  clears the timestamp buffer because Metal timestamps are unimplemented — so the HUD
  falls back to `frame - cpu` and labels the line `(est)`. It is an estimate and is
  marked as one; it is never presented as a measurement.
- `mem` is `Performance.MEMORY_STATIC`.

F3 hides it. `HDDAGI_HUD=0` disables it entirely; `tools/bench_run.sh` sets that by
default because the overlay costs a measurable **0.32 ms/frame (1.1%)** on the
600-tree forest (28.30 → 28.62 ms p50).

## Quick start

```bash
python3 tools/make_manifest.py
python3 tools/hddagi_allocations.py --json artifacts/allocations.json --csv artifacts/allocations.csv
python3 tools/check_shader_sites.py
python3 tools/memory_model.py --subsystem-mib 291.628 \
        --json artifacts/memory_model.json --markdown artifacts/memory_model.md
```

`check_shader_sites.py` exits non-zero when a shader payload access exists that is not
registered in `shader_sites.json`. It is intended to be run after every shader change
in later milestones.

```bash
./tools/check_engine_copies.sh
```

`check_engine_copies.sh` fails if the copies of the sparse self-test in `platform/`, the
engine patch and the build tree disagree, or if `engine_changes.patch` no longer applies
with `-p1` to the supplied tree and reproduces the build byte for byte.

```bash
cd tests/renderer_hddagi_sparse
./run_tests.sh                 # build and run the CPU oracle
./run_tests.sh --fixtures      # also regenerate fixtures/
CXXFLAGS="-fsanitize=address,undefined" BUILD=build-san ./run_tests.sh
```

```bash
cd gpu
./build.sh                     # compile + validate shaders, run the twin tests
./run_gpu_tests.sh             # execute the kernels on this machine's GPU (Metal)

cd ../engine
./build.sh                     # capability and dispatch decisions
```
