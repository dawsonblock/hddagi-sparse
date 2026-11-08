# Frame budget — where the 28.6 ms goes

Executed 2026-11-07 on Apple M2 Pro, macOS 26.2, Metal 4, Forward+, 1600x900,
forest scene, 600 trees, static camera, 120 warmup + 300 measured frames.
Binary sha256: `29fa35ed5bc45167ed2e23368a82ecef49f029dd83fb9c31946bbf714eb77a9e`.

Each feature is priced by disabling exactly one thing and re-measuring. The numbers are
marginal costs, so they do not sum to 100% — features overlap.

## 1. The breakdown

Measured against the pre-fix baseline of **28.60 ms**.

| disabled | p50 | cost | share |
|---|---:|---:|---:|
| *(nothing — baseline)* | 28.60 | — | — |
| All directional shadows | 17.69 | **10.91** | **38.1%** |
| — grass shadows only | 24.16 | **4.44** | 15.5% |
| — tree shadows only | 24.44 | **4.17** | 14.6% |
| HDDAGI indirect (from `phase2_baseline.md`) | 23.61 | **4.92** | 17.2% |
| Volumetric fog | 26.33 | **2.27** | 7.9% |
| MSAA (4x) | 26.52 | **2.08** | 7.3% |
| SSAO | 28.20 | 0.40 | 1.4% |
| Depth fog | 28.32 | 0.28 | 1.0% |
| Glow | 28.36 | 0.25 | 0.9% |
| *remainder (geometry, sky, tonemap, present)* | | ~7.4 | 25.9% |

**Shadows are the frame.** They cost more than HDDAGI, volumetric fog and MSAA combined.

## 2. What was fixed

Grass shadow casting cost **4.44 ms (15.5%)** and changed **0.01% of pixels** (mean
absolute delta 0.01 of 255) against the identical frame with it enabled. The forest
floor is already in foliage shade, so grass shadows contribute essentially nothing.

`main.gd` and `bench.gd` now set `SHADOW_CASTING_SETTING_OFF` on the grass MultiMesh.

| | before | after |
|---|---:|---:|
| static p50 | 28.60 | **24.16 ms** |
| static FPS | 35.0 | **41.3** |
| moving p50 | 25.76 | 23.14 ms |

That is a 15.5% frame-time reduction for no measurable visual change.

## 3. What is worth attacking next, in order

**A. Tree shadows — 4.17 ms.** The same trick does not apply (tree shadows are the
dappled light on the floor and are clearly visible), but the cost is geometry, not
resolution: dropping the shadow map from 4096 to 1024 saves only 0.34 ms, so this is
draw cost from foliage pushed through the shadow pass. Levers, none measured yet:
`directional_shadow_max_distance` is 150 m — most of the forest beyond the first two
cascades contributes almost nothing visible; and shadow-only LODs.

**B. Distance-based tree LOD — up to 2.45 ms.** The scene renders every tree at
`oak_lod0`/`elm_lod0`/`pine_lod0`, the highest detail, at every distance. Forcing the
whole forest to LOD2 measured 21.71 ms against the 24.16 ms baseline, so 2.45 ms is
available. All of it is not free — near trees must stay at LOD0 — but the assets
already ship lod0..lod4, so splitting the forest into two or three distance rings with
separate `MultiMeshInstance3D` nodes and `visibility_range` recovers most of it without
touching near-field quality.

**C. Volumetric fog — 2.27 ms.** `volume_size=128` and `volume_depth=96` in
`project.godot`. Halving either is the standard trade and has not been measured here.
Worth an image comparison before adopting.

**D. MSAA 4x — 2.08 ms.** Dropping to 2x or switching to FXAA/TAA is a direct 7%
recovery. Needs a visual check on foliage edges, which is exactly where alpha-tested
leaves show aliasing.

**E. HDDAGI under motion — 1.3–3.6 ms.** GI costs 4.92 ms static, 6.20 ms moving and
8.55 ms teleporting. The teleport spike is fixed (`teleport_hitch.md`); the remaining
motion overhead is the target of the plan's Phase 3 dirty-region scheduling. It is real
but it is no longer the largest single item.

**F. First-visit pipeline compilation — ~700 ms.** The worst remaining defect by a wide
margin, and not a frame-budget item: the first time a viewpoint is visited, several
consecutive frames cost ~700 ms each (measured p95 709.8 cold vs 60.1 warm). That is
synchronous pipeline compilation, unaffected by the rebuild budget. Fixes are
pre-warming the viewpoints at load or an asynchronous compile path.

## 4. What is not worth doing

- **Shadow map resolution.** 4096 → 1024 saves 0.34 ms. It is a tempting knob and it
  buys almost nothing, because the shadow cost is geometry, not fill rate. Do not trade
  shadow quality for this.
- **Sparse bricks, for performance.** The memory-only case stands as recorded in
  `decision.md` and `phase2_baseline.md`; there is no frame-time case at all.
- **`solid_cell_ratio` tuning for speed.** 0.50/0.25/0.10 are indistinguishable
  (28.542/28.590/28.532 ms). It is a memory knob only.

## 5. Reproducing

```bash
cd hddagi-sparse

# baseline
SCENE=forest TREES=600 CAMERA=static GI=on RATIO=0.10 TAG=base ./tools/bench_run.sh

# price one feature
BENCH_VOLFOG=0   SCENE=forest ... TAG=no_volfog   ./tools/bench_run.sh
BENCH_SHADOWS=0  SCENE=forest ... TAG=no_shadows  ./tools/bench_run.sh
BENCH_MSAA=0     SCENE=forest ... TAG=no_msaa     ./tools/bench_run.sh
BENCH_SSAO=0     SCENE=forest ... TAG=no_ssao     ./tools/bench_run.sh
BENCH_FOG=0      SCENE=forest ... TAG=no_fog      ./tools/bench_run.sh
BENCH_GLOW=0     SCENE=forest ... TAG=no_glow     ./tools/bench_run.sh
BENCH_GRASS_SHADOW=1 SCENE=forest ... TAG=with_grass_shadow ./tools/bench_run.sh
BENCH_TREE_SHADOW=0  SCENE=forest ... TAG=no_tree_shadow   ./tools/bench_run.sh
BENCH_TREE_LOD=2     SCENE=forest ... TAG=treelod2         ./tools/bench_run.sh

# raw project-setting overrides
EXTRA="lights_and_shadows/directional_shadow/size=1024" \
  SCENE=forest ... TAG=shadow1024 ./tools/bench_run.sh
```

Per-run JSON is in `artifacts/bench/`.
