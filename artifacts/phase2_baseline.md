# Phase 2 baseline — measured frame times and resident memory

Executed 2026-11-07 on Apple M2 Pro (12 CPU cores, 19 GPU cores, 16 GB unified),
macOS 26.2, Metal 4, Forward+. This is the first time this project has recorded frame
timings or process memory. Until now every performance statement in `artifacts/` was
arithmetic over declared allocation sizes.

Binary under test:

```
sha256  d896666bba841b6951548eee204bc420018857ce134ce45a7e92d63ae2ffd7db
built   2026-11-07 21:07
version 4.8.dev.custom_build
scons   platform=macos target=editor dev_build=yes vulkan=no -j12
```

## 1. Method

`platform/test_project/bench.gd` builds a scene, drives a camera path, and samples one
record per frame after discarding warmup frames.

| metric | source | real? |
|---|---|---|
| `frame_ms` | wall clock between `_process` calls | yes |
| `cpu_render_ms` | `RenderingServer.viewport_get_measured_render_time_cpu` | yes |
| `static_mb` | `Performance.MEMORY_STATIC` (CPU-side engine allocations) | yes |
| `peak_rss_mb` | `/usr/bin/time -l`, maximum resident set size | yes |
| `gpu_ms` | `RenderingServer.viewport_get_measured_render_time_gpu` | **no — always 0** |

`Engine.max_fps = 0` and `VSYNC_DISABLED`, so frame time is not capped by the display.
300 measured frames for every run except the 4,000-tree forest, which uses 60 because
that scene runs at 9 FPS.

### GPU timing is structurally unavailable on this backend

`drivers/metal/rendering_device_driver_metal.cpp:2430-2431`:

```cpp
void RenderingDeviceDriverMetal::timestamp_query_pool_get_results(...) {
    // Metal doesn't support timestamp queries, so we just clear the buffer.
```

`viewport_get_measured_render_time_gpu` therefore returns 0 for every frame. This is
not a harness bug; the Metal driver in this fork has no timestamp implementation.

`frame_ms` remains usable as a GPU proxy, because `cpu_render_ms` is 0.50–0.94 ms
against a 5–110 ms frame: the CPU finishes submitting in under 4% of the frame. That
justifies attributing deltas *between configurations* to the GPU. It does **not** give
per-pass attribution, which Phase 3 and Phase 4 will need.

### Resolution is 1600x900, not 1920x1080

The built-in display is 1728x1117 points. A 1920-wide window is silently clamped by
the window server; the first attempt produced a 1623x1017 viewport. The harness now
pins the window to 1600x900 and records the actual viewport in every JSON. This
deviates from the plan's recommended 1920x1080 and should be treated as a known
difference against any future run.

### Noise floor

Four runs of the *identical* configuration (forest, 600 trees, static, ratio 0.10):

```
28.532   28.533   28.558   28.592 ms      spread 0.060 ms (0.2%)
```

**Differences below about 0.1 ms p50 are not measurable on this scene.** The empty and
room scenes are far less stable — their `p95` is more than double their `p50`, so
their medians are bimodal and only differences above roughly 1 ms mean anything there.

### The measurement trap that invalidated the first pass

The first version of this benchmark ran against `platform/test_project`, which had no
`.godot` import cache. Textures silently failed to load:

```
ERROR: Failed loading resource: res://demo/terrain/forest_ah.png
ERROR: Cannot open file 'res://demo/foliage/materials/oak_bark.tres'
```

The forest still rendered — tree *meshes* are `.res` files that need no import, so the
scene looked plausible and produced no crash — but every material was a fallback. It
measured **6.6 ms/frame instead of 28.5 ms**, a 4.3x understatement. The only visible
symptom was `static_mb` being 5 MB lower than the imported copy.

The project has since been imported (`--headless --import`) and the missing
`oak_bark.tres` copied in, so `platform/test_project` is now self-sufficient. Every
number below is from the imported project. Any benchmark run against a fresh copy of
this tree without importing will reproduce the wrong numbers.

## 2. Results

1600x900, 6 cascades, 16x8x16, default screen probes.

| scene | camera | GI | trees | n | p50 | p95 | p99 | cpu_render p50 | peak RSS |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| empty | static | on | – | 300 | 4.957 | 11.670 | 13.019 | 0.638 | 349.6 |
| empty | static | off | – | 300 | 5.219 | 11.937 | 13.977 | 0.501 | 357.5 |
| room | static | on | – | 300 | 7.891 | 10.069 | 11.093 | 0.941 | 366.8 |
| room | static | off | – | 300 | 5.095 | 11.227 | 13.068 | 0.617 | 362.6 |
| forest | static | on | 600 | 300 | 28.532 | 29.844 | 30.718 | 0.826 | 452.7 |
| forest | static | off | 600 | 300 | 23.612 | 24.698 | 25.405 | 0.562 | 352.9 |
| forest | move | on | 600 | 300 | 25.759 | 33.707 | 34.476 | 0.749 | 457.0 |
| forest | move | off | 600 | 300 | 19.559 | 20.707 | 21.517 | 0.533 | 364.5 |
| forest | teleport | on | 600 | 300 | 28.230 | 54.550 | 103.480 | 0.734 | 454.7 |
| forest | teleport | off | 600 | 300 | 19.682 | 24.192 | 24.773 | 0.552 | 354.1 |
| forest | static | on | 4000 | 60 | 110.629 | 111.880 | 112.318 | 0.750 | 461.1 |
| forest | static | off | 4000 | 60 | 105.310 | 106.400 | 106.584 | 0.627 | 357.5 |

Ratio sweep, all forest / 600 / static / GI on:

| `solid_cell_ratio` | declared buffers | p50 | peak RSS |
|---:|---:|---:|---:|
| 0.50 | 56.0 MiB | 28.542 | 453.3 |
| 0.25 | 28.0 MiB | 28.590 | 455.4 |
| 0.10 | 11.2 MiB | 28.532 | 452.7 |

### Isolated GI cost

Paired on/off, same scene and camera, `frame_ms` p50 and peak-RSS difference:

| scene | camera | GI off | GI on | GI cost | share | RSS delta |
|---|---|---:|---:|---:|---:|---:|
| empty | static | 5.219 | 4.957 | **−0.26** | not measurable | −8.0 MB |
| room | static | 5.095 | 7.891 | **+2.80** | 35% | +4.2 MB |
| forest 600 | static | 23.612 | 28.532 | **+4.92** | 17% | +99.9 MB |
| forest 600 | move | 19.559 | 25.759 | **+6.20** | 24% | +92.5 MB |
| forest 600 | teleport | 19.682 | 28.230 | **+8.55** | 30% | +100.6 MB |
| forest 4000 | static | 105.310 | 110.629 | **+5.32** | 5% | +103.6 MB |

## 3. Findings

**P1. GI costs 4.9–8.6 ms per frame once there is geometry to voxelise.** On an empty
world it is not measurable: the on/off delta is −0.26 ms, i.e. the wrong sign and
inside the empty scene's noise. That is consistent with HDDAGI doing almost no
light-process work when no solid cells are found. In a 600-tree forest it is 17–30% of
the frame.

**P2. GI cost rises monotonically with camera dynamism.**

```
static    4.92 ms
move      6.20 ms   (+26%)
teleport  8.55 ms   (+74%)
```

These are valid comparisons because on/off pairs see identical content within each
camera mode. This is the strongest evidence in the project so far for Phase 3:
dirty-region scheduling and adaptive cascade updates target exactly this term. If a
scheduler removed the *excess* over the static baseline it would recover 1.3–3.6 ms,
which is 5–13% of the frame and far above the 0.1 ms noise floor.

**P3. Every teleport costs a ~100 ms hitch, and it is GI-specific.**
Frames over 40 ms during the 300-frame teleport run:
```
GI on    16 spikes, max 105.9 ms, p99 103.5
GI off    1 spike,  max  45.1 ms, p99  24.8
```

The spikes recur once per teleport cycle (~36 frames at 28 ms). This is the plan's
"large camera teleport" case, and it is a real, reproducible defect: a 100 ms freeze
is roughly 3.5x the median frame and would be plainly visible. Continuous motion does
not do this (1 spike with GI on), so the cost is specifically the full re-voxelisation
and lighting rebuild on a large positional jump.

> **Addressed in `teleport_hitch.md`.** The rebuild is now budgeted across frames:
> worst frame 106 → 64 ms, frames over 80 ms 9 → 0, total stutter time −90%, median
> unchanged. The numbers above are the pre-fix baseline and are left as recorded.

**P4. The `solid_cell_ratio` change is free in time and does not change resident
memory.** 0.50 / 0.25 / 0.10 give 28.542 / 28.590 / 28.532 ms — a 0.058 ms spread,
identical to the noise floor — and 453.3 / 455.4 / 452.7 MB peak RSS, a 2.7 MB spread
inside RSS noise.

So the 44.8 MiB reduction in *declared* light-process allocation from
`light_process_buffers.md` costs nothing and saves nothing measurable. **It is a
budget reduction, not a residency reduction.** Those buffers were largely untouched
pages; shrinking them bounds worst-case allocation without releasing memory the scene
was actually using. That does not make the change wrong — a lower ceiling is worth
having — but the earlier claim of a "90% saving" is a saving in address space, not in
memory the machine was under pressure for.

**P5. HDDAGI's resident footprint is ~100 MB in a forest, and it tracks content, not
declaration.** Peak-RSS delta between GI on and off:

```
room   (tiny geometry)    4.2 MB
forest 600              99.9 MB
forest 4000            103.6 MB
```

The declared subsystem estimate is 291.6 MiB. Measured residency is about a third of
that. Two consequences: the declared figures must never be quoted as memory *used*,
and residency is genuinely content-dependent — which is the property sparse storage
exists to exploit.

**P6. Tree density dominates the frame, and GI stops being the bottleneck.**
600 → 4,000 trees moves p50 from 28.5 to 110.6 ms. With GI off the dense scene is
still 105.3 ms, so GI contributes only 5% there. The remaining 105 ms is the base
forward renderer — alpha-tested foliage, shadows and volumetrics. **Optimising HDDAGI
cannot fix the dense-forest frame time.** This also retracts an earlier inference in
this project that "tree count barely matters": that was measured on the texture-less
project, where foliage was not actually being shaded.

**P7. Sparse bricks still have no performance case, and a weaker memory case than the
declared numbers suggest.** The sparse target is the 54 MiB dense radiance payload
inside a subsystem whose measured residency is ~100 MB. At 50% residency the model
predicts 26.6 MiB net — about 27% of measured GI residency, but still a bet that
residency is low, and P4 shows that declared-vs-resident gaps can swallow most of an
apparent saving. Nothing here says sparse is wrong; it says the evidence needed to
justify it is residency data, not frame times.

## 4. What this does not establish

- **No GPU timings and no per-pass attribution.** See section 1.
- **`peak_rss_mb` is process-wide.** It includes CPU-side engine data and allocator
  behaviour, so the ~100 MB is an upper bound on HDDAGI's GPU residency, not a VRAM
  reading. macOS exposes no per-resource GPU memory figure to a normal process.
- **Three of six scenes.** `empty`, `room`, `forest`. Open terrain,
  terrain-with-structures, moving sunlight and animated vegetation are not measured.
- **One backend, one resolution, one cascade format, one view.** No Vulkan, no
  1920x1080, no 16x16x16, no multi-view.
- **The moving-camera path is not content-matched to the static view.** Absolute
  static-vs-move frame times are therefore not comparable; only the GI deltas within
  each mode are.
- **60 samples for the 4,000-tree scene.** Its p50 is trustworthy, its tail is not.

## 5. What this changes in the plan

1. **Phase 3 is the highest-value work and now has a target.** The excess GI cost under
   motion is 1.3 ms (move) to 3.6 ms (teleport), plus the ~100 ms teleport hitch. Both
   are above the noise floor and both are update-path problems, which is precisely what
   dirty-region scheduling addresses.
2. **GPU timing is a prerequisite, not a nice-to-have.** Phase 3 and Phase 4 both need
   per-pass attribution, which requires either implementing `MTLCounterSampleBuffer`
   in `rendering_device_driver_metal.cpp` or capturing with Instruments / Metal System
   Trace. Without it a scheduler can be shown to help end-to-end but not to help for
   the reason claimed.
3. **Fix the teleport path before optimising steady state.** A 100 ms freeze is a worse
   user-visible defect than 1–3 ms of steady-state overhead, and it is cheap to
   demonstrate fixed.
4. **Stop quoting declared MiB as memory.** P4 and P5 show the gap is large in both
   directions. `light_process_buffers.md` and `decision.md` should be read with that in
   mind.
5. **Phase 5's sparse gate remains NO-GO on current evidence**, now for a sharper
   reason: the memory objective is not obviously binding, the frame-time objective is
   not memory-bound, and the one measured residency number (~100 MB) is dominated by
   content rather than by the payload sparse would replace.
6. **Re-baseline at 1920x1080 if that is the shipping target.** All numbers here are
   1600x900 because the display cannot host a 1920-wide window.

## 6. Reproducing

```bash
cd hddagi-sparse

# one configuration
SCENE=forest CAMERA=move GI=on RATIO=0.10 TREES=600 ./tools/bench_run.sh

# the noise floor (same config four times)
for i in 1 2 3 4; do SCENE=forest CAMERA=static GI=on RATIO=0.10 \
    TAG=rep_$i ./tools/bench_run.sh; done
```

Each run writes `artifacts/bench/<tag>.json` with per-frame samples, p50/p95/p99, CPU
render time, peak RSS and the engine's own `HDDAGI_PROCESS_BUDGET` line.

Configuration is applied through `override.cfg`, written before the run and removed
afterwards; `platform/test_project/project.godot` is never edited.

The project must be imported before benchmarking, or textures silently fail and the
forest measures 4.3x too fast:

```bash
godot --headless --path platform/test_project --import
```
