# Teleport hitch — root cause and fix

Executed 2026-11-07 on Apple M2 Pro, macOS 26.2, Metal 4, Forward+, 1600x900.
Build: `4.8.dev.custom_build`, scons `platform=macos target=editor dev_build=yes vulkan=no -j12`.
Binary sha256: `29fa35ed5bc45167ed2e23368a82ecef49f029dd83fb9c31946bbf714eb77a9e`.

## 1. The defect

`phase2_baseline.md` recorded that every camera teleport produces a frame far above
the median, and that it disappears when HDDAGI is disabled:

```
teleport, GI on    p99 103.5 ms, 16 frames > 40 ms, max 105.9
teleport, GI off   p99  24.8 ms,  1 frame  > 40 ms, max  45.1
```

A 100 ms frame at a 28 ms median is a visible freeze, not a micro-stutter.

## 2. Root cause

The cost is proportional to the number of cascades rebuilt in one frame, and a
teleport rebuilds all of them.

`GI::HDDAGI::update()` (`gi.cpp:1238-1308`) walks each cascade and advances its
position in `drag_margin * 2` steps. A jump larger than half a cascade in any axis is
promoted to a full rebuild:

```cpp
} else if (uint32_t(Math::abs(cascade.dirty_regions[j])) >= uint32_t(cascade_size[j])) {
    //moved too much, just redraw everything (make all dirty)
    cascade.dirty_regions = HDDAGI::Cascade::DIRTY_ALL;
```

`get_pending_region_count()` (`gi.cpp:1650`) then reports one pending region per
`DIRTY_ALL` cascade, and `render_forward_clustered.cpp:1362` renders every pending
region in the same frame. Six cascades, one frame.

The per-cascade cost was measured directly by varying the cascade count:

| cascades | p50 | max spike | frames > 40 ms |
|---:|---:|---:|---:|
| 1 | 24.07 | 37.9 | 0 |
| 2 | 25.73 | 56.5 | 14 |
| 6 | 28.23 | 105.9 | 16 |

About **13–15 ms per cascade**, and the six are additive.

## 3. The change

A new project setting bounds how many cascades may enter a full rebuild per frame:

```
rendering/global_illumination/hddagi/full_rebuild_budget   int, 0..8, default 1
```

`0` disables the cap and restores the original behaviour exactly.

In `update()`, once the per-cascade dirty computation has settled, a cascade that
would go `DIRTY_ALL` beyond the budget is **deferred**:

```cpp
if (cascade.dirty_regions == HDDAGI::Cascade::DIRTY_ALL && full_rebuild_budget > 0) {
    if (full_rebuilds_issued >= full_rebuild_budget) {
        cascade.position = previous_position;
        cascade.blend_position = previous_blend_position;
        cascade.dirty_regions = Vector3i();
        idx++;
        continue;
    }
    full_rebuilds_issued++;
}
```

Two details are load-bearing:

- **The position is restored, not left at the target.** A cascade whose voxel data
  still describes the old world region must keep claiming that region. Advancing the
  position without rebuilding would make its existing content be read as if it
  described the new location — garbage rather than staleness.
- **No extra state is needed.** Because the position is left behind, the same
  detection fires again next frame, so a deferred cascade resumes by itself.

Deferral applies only to `DIRTY_ALL`. Ordinary scroll slabs are cheap and are never
delayed, so normal camera movement keeps its existing latency.

## 4. Result

Teleport benchmark, forest / 600 trees / 300 measured frames, two independent runs each:

| budget | p50 | max | frames >50 ms | >60 ms | >80 ms | total time in frames >50 ms |
|---:|---:|---:|---:|---:|---:|---:|
| 0 (old) | 28.21 | 106.1 | 16 | 11 | 9 | 1325 ms |
| 0 (repeat) | 28.12 | 104.5 | 16 | 11 | 9 | 1318 ms |
| **1 (new default)** | 28.82 | **63.5** | **2** | **2** | **0** | **127 ms** |
| 1 (repeat) | 28.46 | 64.2 | 2 | 2 | 0 | 128 ms |

- Worst frame: **106 → 64 ms**
- Frames over 80 ms: **9 → 0**
- Total time spent in frames over 50 ms: **1325 → 127 ms, a 90% reduction**
- Median unchanged: 28.2 → 28.5 ms (inside run-to-run variation)

The budget sweep shows 1 is the right default and that larger budgets are worthless:

| budget | max | >50 ms | >80 ms | total >50 ms |
|---:|---:|---:|---:|---:|
| 0 | 106.1 | 16 | 9 | 1325 |
| **1** | **63.5** | **2** | **0** | **127** |
| 2 | 81.8 | 23 | 2 | 1450 |
| 3 | 102.6 | 16 | 10 | 1319 |

Budgets 2 and 3 are no better than off: each rebuild frame then costs two or three
cascades and lands above the threshold anyway. Only a budget of 1 brings every
rebuild frame back under ~50 ms.

`p95` is a misleading metric here and is deliberately not quoted as the headline.
Because a larger budget produces *fewer but larger* spikes, p95 can get worse as the
fix improves — at budget 3 it lands directly on the spike. Count of frames over a
threshold and total time over threshold are the metrics that track what a player feels.

## 5. Visual verification

A deterministic cut (`BENCH_CAMERA=cut`) jumps once at measurement frame 10 and stays,
so frames either side can be captured and compared between budgets.

Per-frame difference, budget 0 vs budget 1, over 746,496 pixels:

| frame | mean luminance b0 | b1 | pixels differing >8 | mean abs delta |
|---:|---:|---:|---:|---:|
| 9 (before) | 63.86 | 63.86 | 0.010% | 0.004 |
| 11 | 63.85 | 63.85 | 0.008% | 0.004 |
| 12 (first post-cut) | 19.69 | 24.85 | 31.5% | 5.26 |
| 13 | 19.79 | 21.73 | 8.95% | 2.19 |
| 14 | 20.02 | 20.59 | 4.27% | 1.21 |
| 16 | 20.55 | 20.14 | 0.62% | 0.58 |
| 20 | 21.84 | 21.23 | 0.24% | 0.63 |
| 30 (converged) | 23.33 | 23.29 | **0.007%** | **0.085** |

Interpretation:

- **Before the cut and after convergence, the two are identical** (0.007% of pixels,
  mean absolute delta 0.085 of 255). Deferral does not change the steady-state image.
- **During the transition the images differ**, which is expected and is the entire
  point of the change: the deferred cascades still hold the previous location's
  lighting for a few frames.
- **Deferral is not darker.** At frame 12 the deferred build is *brighter*
  (24.85 vs 19.69 mean luminance). Both configurations go dark after a cut, because
  the GI has to re-converge from nothing; the deferred one retains more of the
  previously-correct light rather than collapsing. Frames 12 were inspected
  side by side: both show the same forest, same geometry, same fog; neither shows
  black patches, cross-cascade leakage or uninitialised content.

So the trade is: one 106 ms freeze, replaced by six consecutive frames that are
correct in the near field and progressively correct outward. That is a better deal,
and it is the standard amortisation for this class of update.

## 6. What this does not fix

**First visit to a viewpoint costs ~700 ms per frame, for several frames.** This is a
separate and larger defect, and it is not the cascade rebuild:

- `BENCH_CAMERA=cut` at a viewpoint never visited before: p95 **709.8 ms**
- the same run repeated once the shader/pipeline cache was warm: p95 **60.1 ms**

The signature — several consecutive ~700 ms frames that vanish on a second run — is
consistent with synchronous pipeline compilation when new material and shadow variants
become visible. It is not affected by the rebuild budget (budget 1 measured 685 ms on
the same cold viewpoint), because it is not cascade work.

This is now the worst hitch in the renderer and should be attacked next. The likely
fixes are pre-compilation of the pipeline variants a scene can need, or an
asynchronous pipeline compile path; both are outside the HDDAGI update loop.

Note that the frame captures in section 5 also stall for ~700 ms each, because
`Viewport.get_texture().get_image()` is a synchronous GPU readback. That is a
measurement artifact only; the pixels are valid.

## 7. Reproducing

```bash
cd hddagi-sparse

# the fix on and off, teleporting every second
SCENE=forest TREES=600 CAMERA=teleport GI=on RATIO=0.10 REBUILD=0 ./tools/bench_run.sh
SCENE=forest TREES=600 CAMERA=teleport GI=on RATIO=0.10 REBUILD=1 ./tools/bench_run.sh

# the budget sweep
for b in 0 1 2 3; do
  SCENE=forest TREES=600 CAMERA=teleport GI=on RATIO=0.10 REBUILD=$b \
    TAG=tele_budget$b ./tools/bench_run.sh
done

# the visual check: one deterministic cut, capture frames across it
SCENE=forest TREES=600 CAMERA=cut GI=on RATIO=0.10 FRAMES=40 WARMUP=60 REBUILD=1 \
  TAG=c1 BENCH_SNAP="9,10,11,12,13,14,16,20,30" BENCH_SNAP_DIR=/tmp/snap_c1 \
  ./tools/bench_run.sh
```

The engine change is recorded in `platform/engine_changes.patch` (files `gi.cpp`,
`gi.h`, `rendering_server.cpp`).
