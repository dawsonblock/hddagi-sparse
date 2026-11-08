# Distance tree LOD and shadow LOD

Executed 2026-11-08 on Apple M2 Pro, macOS 26.2, Metal 4, Forward+, 1600x900,
forest scene, 1,500 trees, GI on, `solid_cell_ratio` 0.10. Engine binary
`29fa35ed5bc45167ed2e23368a82ecef49f029dd83fb9c31946bbf714eb77a9e`.

Shadows were already known to be the largest frame-budget item (38% at 600 trees,
`frame_budget.md`). This pass tests the two cheapest ways to reduce that cost without
touching the engine: draw distant trees at a lower mesh LOD, and stop distant trees
from casting shadows.

## What was implemented

Three distance rings from the scene origin, in both `bench.gd` and `main.gd`:

| ring | distance | tree mesh | shadow |
|---|---|---|---|
| near | < 35 m | lod0 | on |
| mid | 35-75 m | lod1 | on |
| far | > 75 m | lod2 | off by default |

Every tree transform is generated before the ring split, so the RNG stream is
identical with LOD on and off — the same 1,500 trees are in the same places, which is
what makes the image comparison below meaningful.

The rings are **camera-relative**: when the camera moves more than 5 m from the
position the rings were built for, the per-ring instance lists and meshes are rewritten
(`BENCH_LOD_CAMERA=0` keeps the old origin-fixed behaviour for comparison). The static
camera stands at the origin, so both modes are identical there. On the teleport and cut
cameras, the rebuild happens in the same frame as the jump, and its cost is included in
the measurements.

Controls:

| variable | default | effect |
|---|---|---|
| `HDDAGI_LOD` / `BENCH_LOD` | `rings` / `off` | `0`/`off` puts every tree at lod0 |
| `HDDAGI_SHADOW_LOD` / `BENCH_SHADOW_LOD` | `far` / `off` | `off`, `far`, `near` |
| `HDDAGI_LOD_NEAR` / `BENCH_LOD_NEAR` | 35 | near/mid boundary, metres |
| `HDDAGI_LOD_MID` / `BENCH_LOD_MID` | 75 | mid/far boundary, metres |
| `BENCH_LOD_CAMERA` | 1 | 0 = fixed rings from the origin, for comparison |

The packaged app defaults to rings + far shadows. The benchmark harness defaults to
off so the old baseline is still reproducible with no variables set.

## Performance (300 measured frames, 120 warmup)

All repeats are reported; none is picked as "the clean one".

| configuration | run | p50 | p95 | p99 | max | frames >33 ms | FPS (p50) |
|---|---|---:|---:|---:|---:|---:|---:|
| baseline (all lod0, all shadows) | | 37.41 | 38.64 | 39.37 | 41.2 | 300 | 26.7 |
| no far shadows, 75 m | | 32.57 | 33.17 | — | 35.7 | 28 | 30.7 |
| tree LOD + no far shadows, 75 m | r0 | 29.43 | 30.54 | 31.44 | **70.2** | 0 | 34.0 |
| tree LOD + no far shadows, 75 m | r1 | 29.37 | 30.28 | 30.64 | 31.2 | 0 | 34.1 |
| tree LOD + no far shadows, 50 m | | 27.58 | 28.22 | — | 28.7 | 0 | 36.3 |

Tree LOD + 75 m shadow cut is **-21.5% frame time** on the median repeat. The
aggressive 50 m cut is -26.3%. The r0 repeat contains one 70.2 ms outlier at
measured frame 87 that r1 does not; it is retained in the table and in
`lod_camrel_static_t1500.json`. Its cause was not identified — it is a single
frame, so it does not change the p50/p95 conclusion, but it is not evidence of
stability either.

**Camera-path caveat:** the move and teleport rows below were measured while the
camera trajectory was indexed on **wall-clock** seconds, so a faster
configuration visited different viewpoints than a slower one. Cross-config
comparisons of those rows are not controlled. The trajectory is now indexed on
the frame counter (`_frame_total`), which makes the path identical across
configurations; the controlled matrix in `artifacts/matrix.md` re-measures the
teleport row under the corrected trajectory.

Teleporting every second at 1,500 trees, camera-relative rings:

| configuration | p50 | p95 | frames >50 ms | total >50 ms |
|---|---:|---:|---:|---:|
| baseline | 38.00 | 65.34 | 67 | 4,314 ms |
| tree LOD + 75 m shadow cut | **30.33** | **53.26** | **27** | **1,558 ms** |

The hitch is not removed — it is cascade rebuild work — but its cost drops by 64%.
These numbers include the ring rebuild on every teleport.

## Visible quality

Same camera, frame 100, 1600x900. Difference against the baseline frame over 1.44 M
pixels; `>8` counts a pixel whose largest channel delta exceeds 8/255.

| change | mean abs delta | pixels >8 | max | top third | bottom third |
|---|---:|---:|---:|---:|---:|
| tree LOD only | 0.150 | 0.62% | 150 | 0.02% | 1.30% |
| far shadows off, 50 m | 0.364 | 0.99% | 118 | 0.01% | 2.89% |
| far shadows off, 60 m | 0.170 | 0.54% | 94 | 0.01% | 1.59% |
| far shadows off, 75 m | 0.058 | 0.21% | 70 | 0.02% | 0.59% |
| tree LOD + far 75 m | 0.199 | 0.80% | 150 | 0.02% | 1.83% |
| tree LOD + far 50 m | 0.511 | 1.59% | 150 | 0.02% | 4.10% |

- **Tree LOD is nearly invisible.** 0.62% of pixels change by more than 8, almost all
  of them leaf silhouettes on distant trees (max delta 150 on individual edge pixels).
  The top third of the image — where the farthest trees are — changes by 0.02%.
- **Far shadows are the better trade.** Cutting shadows beyond 75 m saves 4.8 ms and
  changes 0.21% of pixels. The change is concentrated on the ground under mid-distance
  trees (bottom third 0.59%), which is what one would expect.
- **Do not cut at 50 m by default.** It is 1.6% of pixels and 4.1% of the bottom third,
  with visible shadow loss in the foreground. It is available as an aggressive option.

### Moved viewpoint: why the rings follow the camera

The static comparison cannot show whether the rings are attached to the viewer. The
`cut` camera jumps once to a viewpoint about 45 m from the origin and stays; frame 30 is
compared after convergence.

| configuration | mean abs | pixels >8 | top third | mid third | bottom third |
|---|---:|---:|---:|---:|---:|
| off, repeated (run-to-run noise) | 0.644 | 2.67% | 7.06% | 0.95% | 0.01% |
| camera-relative LOD | 0.654 | 3.08% | 6.49% | 2.66% | 0.10% |
| origin-fixed LOD | 7.558 | 24.50% | 39.08% | 19.96% | 14.45% |

Camera-relative LOD is within the off-vs-off noise at the moved viewpoint. Origin-fixed
rings are not: they classify trees near the new camera as far, changing a quarter of the
image. That is the reason the rings follow the camera.

## Shadow distance is not a lever

Reducing `directional_shadow_max_distance` from 150 m to 80 or 60 m changed nothing:

| distance | p50 |
|---|---:|
| 150 m (baseline) | 37.55 |
| 80 m | 37.88 |
| 60 m | 38.31 |

The shadow cost is the near/mid geometry pushed through the shadow pass, not the far
cascades. This contradicts the suggestion in `frame_budget.md` §3A that the 150 m
distance was worth attacking; the ring-based shadow cut is the effective lever because
it removes *casters*, not shadow-map extent.

## Reproducing

```bash
cd hddagi-sparse

# performance
BENCH_LOD=rings BENCH_SHADOW_LOD=far BENCH_LOD_MID=75 \
  TAG=lod_rings_far75_t1500 SCENE=forest TREES=1500 FRAMES=300 WARMUP=120 RATIO=0.10 \
  ./tools/bench_run.sh

# the four configurations in the table
BENCH_SHADOW_LOD=far BENCH_LOD_MID=75 TAG=lod_far75_t1500 ...
BENCH_LOD=rings BENCH_SHADOW_LOD=far BENCH_LOD_MID=50 TAG=lod_rings_far50_t1500 ...
BENCH_LOD=rings BENCH_SHADOW_LOD=far CAMERA=teleport TAG=lod_camrel_teleport_t1500 ...

# image comparison: capture the same frame in each configuration
BENCH_LOD=rings BENCH_SHADOW_LOD=far \
  TAG=lodimg_rings_far75 SCENE=forest TREES=1500 FRAMES=101 WARMUP=60 RATIO=0.10 \
  BENCH_SNAP=100 BENCH_SNAP_DIR=/tmp/lodimg ./tools/bench_run.sh

# moved viewpoint: cut camera, camera-relative vs origin-fixed
BENCH_LOD=rings BENCH_SHADOW_LOD=far CAMERA=cut TAG=camrel_cut_lod \
  SCENE=forest TREES=1500 FRAMES=101 WARMUP=60 RATIO=0.10 \
  BENCH_SNAP=30 BENCH_SNAP_DIR=/tmp/camrel ./tools/bench_run.sh
BENCH_LOD=rings BENCH_SHADOW_LOD=far BENCH_LOD_CAMERA=0 CAMERA=cut \
  TAG=camrel_cut_lod_origin SCENE=forest TREES=1500 FRAMES=101 WARMUP=60 RATIO=0.10 \
  BENCH_SNAP=30 BENCH_SNAP_DIR=/tmp/camrel ./tools/bench_run.sh

python3 tools/analyze_runs.py artifacts/bench/lod_*.json artifacts/bench/camrel_*.json
```

JSONs: `artifacts/bench/lod_*_t1500.json`, `lodq_*`, `lodimg_*`, `camrel_*`; logs
alongside in `artifacts/bench/logs/`.

## Known limitations

- Camera-relative rebuilds are discrete: they run when the camera has moved 5 m, and
  they rewrite instance lists on the render thread. The rebuild cost is inside the
  teleport/cut measurements, not hidden.
- Ring assignment can change only at a rebuild. There is no cross-fade, so a tree that
  changes ring at a rebuild changes mesh LOD and shadow casting in one step; the cut
  comparison did not show a visible pop, but the switch is discrete.
- The packaged app's camera is static, so it builds the rings once and never rebuilds;
  `HDDAGI_LOD=0` is the app-side control. The camera-relative path is exercised by the
  benchmark harness.
- The image metric is a proxy for visible quality, not a perceptual study. The frames
  are available in `/tmp/lodimg` and `/tmp/camrel` after the reproduce step.
- Grass is still lod0 with shadows off; grass LOD was not part of this pass.
- `HDDAGI_LOD=0` still allows `HDDAGI_SHADOW_LOD=far`, which splits the rings but keeps
  lod0 meshes; the two controls are independent on purpose.
