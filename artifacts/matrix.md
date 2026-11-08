# Controlled 1,500-tree feature matrix

Executed 2026-11-08 on Apple M2 Pro, macOS 26.2, Metal 4, Forward+.
Engine binary `a3e594ca1e6748c5506f50e1962b6a31042f1ed508022589f7bf1eb40532c59b`
— the same build embedded in `HDDAGI.app`. Base project manifest
`6a5d68fe500f74bedf80be1e13d2a4c4d28f3394bb8f9306d493440944a2cb32`
(source project, `.godot/` and `override.cfg` excluded).

Driver: `tools/run_matrix.py`. Every run goes through `tools/bench_run.sh`
(exit-0 required, error-scan, contrast check, fresh-JSON validation, atomic
publish, timeout 180 s). `matrix_runs.json` records every completed run ID; the
summary only aggregates those IDs and re-validates binary hash, project manifest
hash and `timing_usable`, so a stale JSON cannot enter the table.

## Like-for-like contract

Same for every row: forest scene, **1,500 trees** (exact count asserted by the
harness), GI on unless the cell says off, `solid_cell_ratio` 0.10, 1600×900
unless stated, `msaa_3d` 2 (4x) unless stated, deterministic RNG seed 987654,
the same binary, and a **frame-indexed** camera trajectory — the viewpoint on
frame N is a pure function of N, so a faster cell sees the identical path
(`trajectory.indexed_by: frame` in every JSON). Each cell's effective toggles
are recorded in `settings`, read back from the live scene rather than the
request. Environment leakage is pinned: the driver clears every `BENCH_*` key
and sets an explicit baseline before each run.

- **warm** = the Godot shader cache present *and* the cell prewarmed once
  (`pre_<cell>`, 30+30 frames, 60+60 for teleport cells so all four jump
  targets are visited). All `m_*_rN` rows are warm.
- **cold** = the Godot shader cache directory moved aside once
  (`shader_cache.bak-cold-*`). OS page cache and any driver-level Metal caches
  are not controlled — "cold" does not mean "all caches cold".
- Repeats are **interleaved** (r0 of every cell, then r1s, then r2s) so machine
  drift lands on every cell evenly. All repeats are kept; the table uses the
  median, never the cleanest one.
- Timing runs never snapshot. `q_*` runs snapshot inside the window and are
  marked `run_kind: quality`, `timing_usable: false`; their frame times are not
  reported.

## Results (static camera, warm, 300 measured frames, 3 repeats)

Median across repeats; tails are worst-repeat values. Full per-repeat rows are
in `matrix/summary.json` and each `matrix/m_*.json`.

| cell | change vs base | rep p50s (ms) | median p50 | Δ vs base | worst-rep p95 | worst-rep p99 | max | peak RSS |
|---|---|---|---:|---:|---:|---:|---:|---:|
| base | — (all on, lod0, all shadows) | 37.59, 37.53, 37.39 | 37.53 | — | 38.39 | 38.80 | 40.1 | 466 |
| noshadow | sun shadow off | 26.30, 26.36, 26.39 | 26.36 | **-29.8%** | 27.26 | 27.76 | 29.6 | 464 |
| res720 | shipped toggles @1280x720 | 26.81, 26.96, 26.87 | 26.87 | -28.4% | 27.84 | 28.24 | 30.1 | 467 |
| bal_perf | shipped + MSAA2x + SSAO off @720p | 25.75, 25.86, 25.81 | 25.81 | **-31.2%** | 26.95 | 28.36 | 46.6 | 467 |
| shipped | LOD rings + far ring no-shadow (app default) | 29.55, 29.59, 29.55 | 29.55 | -21.3% | 30.39 | 30.88 | 31.3 | 466 |
| bal_looks | shipped + MSAA 2x + SSAO off | 27.99, 28.30, 27.94 | 27.99 | **-25.4%** | 29.93 | 31.90 | 71.0* | 468 |
| treelod | geometry LOD only | 31.13, 31.08, 31.02 | 31.08 | -17.2% | 31.98 | 32.73 | 33.0 | 465 |
| shadowlod | far ring stops casting only | 32.82, 32.90, 32.84 | 32.84 | -12.5% | 33.64 | 34.05 | 35.6 | 465 |
| nogi | HDDAGI GI off | 32.60, 32.62, 32.65 | 32.62 | -13.1% | 33.47 | 33.84 | 34.9 | **362** |
| novolfog | volumetric fog off | 35.37, 35.35, 35.38 | 35.37 | -5.8% | 36.33 | 36.88 | 43.3 | 467 |
| nofog | volumetric + cheap fog off | 35.32, 35.39, 35.26 | 35.32 | -5.9% | 36.12 | 36.70 | 38.0 | 466 |
| msaa0 | MSAA off | 35.59, 35.57, 35.53 | 35.57 | -5.2% | 36.50 | 37.12 | 38.6 | 466 |
| msaa2x | MSAA 4x→2x | 36.53, 36.58, 36.52 | 36.53 | -2.7% | 37.47 | 38.04 | 39.7 | 466 |
| nossao | SSAO off | 37.13, 37.11, 37.05 | 37.11 | -1.1% | 37.98 | 38.32 | 40.2 | 464 |
| noglow | bloom off | 37.22, 37.27, 37.24 | 37.24 | -0.8% | 38.17 | 38.60 | 41.0 | 465 |

\* `bal_looks` r1 contains a **three-frame hitch cluster**: 66.8, 68.8 and 71.0 ms
at measured frames 20, 22 and 23 (0-based), 206.6 ms total over >50 ms. r0/r2
have zero frames over 50 ms and worst frames of 31.5/31.3 ms, so this is a
hitch cluster inside one repeat, not steady state; the cause is unconfirmed and
all values are retained. `bal_perf` r0's max is 46.6 ms (frame 87) — elevated
but under 50 ms. The cluster is at frames 20–23, not the ~frame-87 area where
the earlier `lod.md` outlier and `bal_perf` r0's 46.6 ms sit, so no common-cause
pattern is claimed.

Repeat p50 spread is 0.04–0.36 ms on every cell: medians are trustworthy to
about ±0.2 ms. `>50 ms` counts on static-camera rows are 0 everywhere **except**
the `bal_looks` r1 cluster described above (3 frames, 206.6 ms).

Run accounting: **53 measured timing runs** (51 warm repeats: 13 isolation cells
+ 2 balanced cells + 2 teleport cells ×3, plus 2 single cold runs), 17 `pre_*`
prewarm runs (not measured), and 19 `q_*` quality runs — 89 bounded invocations
in total.

## What each feature costs — and what it costs the image

Pixel diffs: `q_<cell>_f100.png` vs the reference frame, 1.44 Mpx, `>8` = largest
channel delta over 8/255. `bal_perf`/`res720` are 720p and cannot be pixel-diffed
against 1600×900 references (marked skipped in `diffs/diffs.json`, honestly).
**A pixel-change percentage is a change proxy, not a perceptual quality score** —
4% of leaf-edge pixels differing is not the same experience as 4% of sky
differing. The "viewed" column below is my read of the actual captures in
`matrix/snaps/`; it is a subjective judgement, labelled as such.

| cell | Δ frame time | px >8 vs base | where it lands | viewed (subjective) |
|---|---:|---:|---|---|
| noshadow | **-29.8%** | **83.7%** | everywhere; sun/shade structure gone | flat lighting, no depth cues — destroys the look |
| nogi | -13.1% | **97.0%** | the whole bounce-light character | washed-out flat ambient — destroys the look |
| nofog | -5.9% | **~100%** | entire image, distance haze gone | distance reads as cut-out — destroys the look |
| novolfog | -5.8% | 25.3% (top third 48%) | light shafts in the canopy | canopy shafts gone, depth cueing weaker — clearly visible |
| shipped | -21.3% | 0.80% | leaf silhouettes, ground shadow edges | indistinguishable from base in the still |
| treelod | -17.2% | 0.62% | distant leaf silhouettes | indistinguishable in the still |
| shadowlod | -12.5% | 0.20% | shadow edge under far trees | indistinguishable in the still |
| msaa0 | -5.2% | 2.12% | foliage edges | slightly crisper-edge noise in leaves |
| msaa2x | -2.7% | 1.35% | slight edge softening | no visible difference at normal scale |
| nossao | -1.1% | 2.22% | contact darkening at trunks/ground | no visible difference at normal scale |
| noglow | -0.8% | 0.62% (mean 2.12) | sky/bloom bright areas | bright haze slightly dimmer |
| bal_looks | **-25.4%** | 4.28% (vs base), 3.60% (vs shipped) | high-frequency leaf edges | essentially identical to shipped/base stills at normal scale |

Whether edge-only changes are visible *in motion* cannot be answered by still
captures — no temporal claim is made.

Interpretation against the user's goal (believable forest, smoother, not maximum
detail):

- The **big visual identity is shadows + GI + fog**: removing any one of them
  wins 6–30% frame time and changes 25–100% of the frame. Those are the
  "believable" features and stay.
- The **cheap levers are visibility policy and render settings**: LOD rings +
  far shadow cut (-21.3%, 0.8% of pixels), MSAA 4x→2x (-2.7%, 1.35%), SSAO off
  (-1.1%, 2.2%), resolution 900p→720p (-9.1% vs shipped, resolution cost).
- Tree geometry LOD alone is worth -17.2%; far-shadow cut alone -12.5%; together
  -21.3% (slightly less than additive — they share shadow-pass work).

## Recommended balanced preset — `bal_looks`

**`bal_looks` = shipped + MSAA 2x + SSAO off at 1600×900: 27.99 ms median
(-25.4% vs base), 35.7 FPS.** Two of three repeats have zero frames over 50 ms
and worst frames of ~31 ms; r1 carries the three-frame hitch cluster described
above (66.8–71.0 ms at frames 20–23). Image: 4.28% of pixels differ vs max
quality, concentrated in high-frequency leaf edges; in the viewed stills
(subjective) it is essentially indistinguishable from `shipped` and `base` at
normal scale. Whether the edge differences are visible in motion is untested.

**`bal_perf` (same + 720p): 25.81 ms (-31.2%), 38.7 FPS**, as the lower-end
option. Viewed: the same scene, noticeably softer — the resolution loss is the
only visible change; lighting, shadows and fog are all preserved. Pixel-diff vs
base is not meaningful across resolutions; the 720p like-for-like diff vs
`res720` is 3.73% (the MSAA/SSAO component only).

Recommendation: adopt `bal_looks` as the default preset — it keeps every
load-bearing visual (shadows, GI, both fogs) and cuts a quarter of the frame
time for a change that is invisible in the stills I viewed (subjective call,
backed by the 4.28% edge-pixel metric). `bal_perf` for users who prefer FPS
over sharpness. `noshadow`/`nogi`/`nofog`/`novolfog` are **not** recommended —
their speedups are real but the viewed captures confirm the image cost is
severe. Per instruction, defaults are **not** changed by this pass; this is a
measured recommendation for the user to approve. Applying it is a settings
change only (`main.gd` does not yet expose MSAA/SSAO switches — the app reads
`HDDAGI_*` env vars for LOD already).

## Moving camera — teleport hitch under the corrected trajectory

Teleport every 25 frames (12 jumps over the 300 measured frames; jump indices
are recorded in `trajectory.teleport_measured_frames`).

| cell | rep p50s | median p50 | worst-rep p95 | worst-rep p99 | max | >50 ms frames (per rep) |
|---|---|---:|---:|---:|---:|---|
| tele_base | 38.41, 38.51, 38.35 | 38.41 | 65.31 | 79.06 | 124.2 | 63, 63, 63 |
| tele_shipped | 30.52, 30.50, 30.45 | 30.50 | 54.31 | 63.83 | 99.8 | 31, 32, 32 |

Each recorded jump frame is followed within ~2 frames by a cluster of >50 ms
frames — about 5 per jump on base, ~2.7 on shipped. The hitch is the cascade
rebuild the jump triggers (consistent with `teleport_hitch.md`, where the
budget-1 spread was characterized); the LOD/shadow policy roughly halves the
hitch count and trims the tail from ~124 ms to ~100 ms. It does not remove the
hitch — that needs engine-side rebuild amortization beyond the current budget.

## Cold vs warm (single runs, shader cache moved aside)

| cell | cache | elapsed | scene-built ms | p50 | max | peak RSS |
|---|---|---:|---:|---:|---:|---:|
| cold_base | cold | 26.6 s | 4,839 | 37.42 | 45.4 | **702** |
| base r0-2 | warm | ~19.1 s | ~1,480 | 37.39–37.59 | 40.1 | 466 |
| cold_shipped | cold | 23.0 s | — | 29.34 | 35.6 | **738** |
| shipped r0-2 | warm | ~15.5 s | ~1,470 | 29.55 | 31.3 | 466 |

On this binary the cold penalty lands in **startup** (+3.4 s to scene-built,
+7 s end-to-end) and in **peak RSS** (+~240 MB, consistent with pipeline
compilation work, not steady state). The measured-window p50 is essentially
unchanged (37.42 vs 37.53); no >80 ms frame appeared in either cold run — the
450 ms late spike seen in `cold_start.md` under binary `29fa35ed` did **not**
reproduce under `a3e594ca` in these single cold runs (n=1 each; not disproven
either).

## Memory — measured, kept separate from arithmetic

| metric | what it is | base | shipped | nogi | cold_* |
|---|---|---:|---:|---:|---:|
| `peak_rss_mb` | whole-process peak RSS: startup + warmup + measurement + readback | 466 | 466 | **362** | 702–738 |
| `static_mb` p50 | `Performance.MEMORY_STATIC` per measured frame | 83.2 | 83.5 | **72.9** | 83 |
| buffer arithmetic | `HDDAGI_PROCESS_BUDGET` line: 7 buffers × 1.60 MiB | 11.20 MiB (estimate, all cells) | | | |

- GI off saves **~104 MB RSS** and ~10 MB static — the only cell that moves
  memory meaningfully. LOD/shadow toggles do not reduce measured RSS (the ring
  split *adds* draw batches: objects 47→93, and meshes stay resident).
- **VRAM is not measured** — no Metal GPU timestamps or allocator counters are
  available in this fork, so nothing here is claimed about video memory. The
  11.20 MiB figure is allocation arithmetic from the engine's budget log,
  reported as an estimate, not a measurement.
- `cpu_render_ms` (render submission) is ~0.8 ms on most cells; 720p cells and
  bal_looks show ~2.4–2.8 ms — recorded, unexplained; no GPU-stage attribution
  is possible on Metal here, so no causal claim is made about it.

## Reproducing

```bash
cd hddagi-sparse

# the whole matrix (89 bounded runs: 53 measured + 17 prewarm + 19 quality,
# ~25 min, one at a time; aborts on the first failure)
python3 tools/run_matrix.py

# just the balanced cells / just captures / just the table
CELLS="bal_looks bal_perf" python3 tools/run_matrix.py --phase timing
python3 tools/run_matrix.py --phase quality
python3 tools/run_matrix.py --summarize

# one cell by hand (identical like-for-like env)
env SCENE=forest TREES=1500 RATIO=0.10 FRAMES=300 WARMUP=120 TIMEOUT=180 \
    CACHE_STATE=warm TAG=my_run BENCH_LOD=rings BENCH_SHADOW_LOD=far \
    ./tools/bench_run.sh

# pixel diffs
python3 tools/img_diff.py artifacts/bench/matrix/snaps/q_shipped_f100.png \
                          artifacts/bench/matrix/snaps/q_base_f100.png
```

## Known limitations

- GPU stage attribution is impossible on Metal here: frame time is wall-clock
  between `_process` calls; `gpu_ms` is structurally 0 and `gpu_timing_available`
  is false. Deltas are stated as frame-time deltas, not "GPU savings".
- Cold means *Godot shader cache absent*; the OS page cache and any Apple
  driver caches are uncontrolled. Cold cells are single runs (n=1).
- `q_*` timings are unusable by design (readback inside the window); they exist
  for image diffs only.
- The bench harness defaults LOD/shadow policy **off** while the packaged app
  defaults to rings + far; every matrix cell sets explicit toggles, and the
  effective set is recorded in `settings`, so this cannot confuse the table.
- Pixel-change percentages are a change proxy, not a perceptual quality metric;
  the "viewed" judgements are subjective reads of still captures, and temporal
  artifacts (aliasing shimmer in motion) are untested.
- The `bal_looks` r1 hitch cluster (frames 20–23) and the `lod.md` 70 ms outlier
  (frame ~87) are at different measured positions; no common cause is claimed.
- run-to-run spread at p50 is ±0.2 ms; deltas below ~1 ms (nossao, noglow) are
  real but close to the noise floor and rest on repeat-median agreement.
- `objects`/`prims` columns show ring-split cells add draw batches
  (47→93–117 objects); the frame-time numbers already include that cost.
