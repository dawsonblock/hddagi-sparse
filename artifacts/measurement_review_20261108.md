# Independent measurement review, 2026-11-08

This review predates the new controlled measurement matrix. It is not a claim that
all requested profiling is complete. Devin received the findings in the existing
Godot Review Working Changes session and is preparing the matrix.

## Checks repeated

- `python3 platform/test_verify_app.py`: 14 tests pass.
- `bash tools/check_engine_copies.sh`: 11 checks pass.
- `bash -n tools/bench_run.sh platform/make_mac_app.sh tools/profile_cold_warm.sh`: pass.
- No staged Git changes at inspection. Existing dirty work preserved.
- Fresh read-only source/bundle comparison: 107 files each, no missing, differing,
  or extra files; manifest `56f0a387a960112cd9782bb42c03acd9399d6280ce225149b9ae10624bba1b56`.
- Build-tree binary matches installed binary; installed manifest identifies
  `a3e594ca1e6748c5506f50e1962b6a31042f1ed508022589f7bf1eb40532c59b`.
- Existing installed verification manifest reports 23 checks passing and rendered
  smoke 11.441 seconds. This duration is not a frame time or time-to-first-frame.
- Viewed its normal.png: forest canopy, textured trunks/ground, grass, shadows and
  fog are visibly present. This is a visual sanity check, not proof of GI parity.

## Findings that constrain previous claims

1. `warm_static_t1500` and `warm_teleport_t1500` use binary `29fa35ed5bc4...`;
   camera-relative LOD results use `a3e594ca1e67...`. Fresh same-binary controls
   are required before attributing the full difference to LOD.
2. Move and teleport trajectories use wall time, while samples are a fixed number
   of frames. Faster variants therefore sample different camera histories and
   teleport counts. Use frame-indexed trajectories for paired comparisons.
3. BENCH_SNAP synchronously captures within the measurement window. Those runs
   must not be treated as clean performance runs; keep quality runs separate.
4. JSON records the engine hash but lacks full effective toggles and project
   identity. A complete matrix needs recorded effective settings and cache state.
5. Historical reports select a cleaner LOD repeat. Both repeats must be retained:
   p50 29.428/29.367 ms, p99 31.437/30.640 ms, max 70.162/31.151 ms; 300 samples each.
6. Clearing Godot's cache does not establish a fully cold OS/Metal cache. CPU
   render time is not total CPU time, and absent GPU timestamps cannot prove a
   bottleneck split. Pipeline-compilation/cascade explanations remain hypotheses
   without isolated telemetry.
7. The app defaults to geometry rings and far shadow LOD; the harness defaults
   to both off. Merely using the packaged binary/project is insufficient to
   establish packaged-default equivalence.
8. Trees are grouped in MultiMeshes (three species, optionally three rings each),
   not explicitly spatially chunked for per-tree visibility culling. No explicit
   occlusion/visibility test toggle was present at review. Do not claim such
   optimization measured without implementation and controls.
9. Existing peak RSS covers the whole process including setup and final capture;
   it is neither steady-state resident memory nor dedicated VRAM. Static memory
   counters and allocation arithmetic must remain separately labelled.

## Pending

Controlled same-binary interleaved 1,500-tree matrix, raw distributions and
run-to-run variability, warm/cold scope, separate correctness captures, final
package revalidation if scripts change, and explicit unmeasured limitations.
Sparse support is still probe-only, not an integrated sparse lighting renderer.

## Completed follow-up review

Devin completed 53 measured timing runs (51 warm repeats, 2 Godot-cache-cleared
runs), 17 prewarm runs and 19 separate quality runs. Independent final checks:
all 53 timing JSONs share one engine and base-project hash, have 300 finite,
positive frame samples, and mark timing usable; all 19 quality JSONs mark timing
unusable. Missing matrix manifest and wrong-binary aggregation tests fail closed.
The 14 verifier unit tests, 11 engine-copy checks and shell syntax pass again.

Fresh installed/source manifests match at
`6a5d68fe500f74bedf80be1e13d2a4c4d28f3394bb8f9306d493440944a2cb32`.
Installed manifest `app_build/20261108-024210/installed-manifest.json` passes
23 checks; rendered smoke exits 0 in 7.753 s, and prior bundle is preserved.
No defaults changed and no Git changes were staged or pushed.

Key static medians across three repeats: full-detail baseline 37.535 ms;
geometry LOD only 31.080 ms; shadow LOD only 32.835 ms; combined 29.555 ms;
Devin's recommended 900p balanced preset (combined plus MSAA 2x and SSAO off)
27.991 ms; 720p balanced 25.814 ms. These correspond to inverse-median rates
of 26.6, 35.7 and 38.7 FPS for baseline/900p/720p, not guarantees.

Balanced900p worst-repeat p95/p99 are 29.925/31.899 ms, with three >50 ms
frames in repeat1 totaling 206.6 ms (max70.995 ms). Balanced720p worst p95/p99
26.952/28.363 ms, max46.639 ms. Initial prose transcription errors in the
Devin report were caught and corrected against JSON before delivery.

Viewed full-detail, balanced900p and balanced720p images. Lighting, shadows,
fog and populated forest remain visible. Balanced900p has 4.28% of pixels
changed >8/255 and mean channel difference1.483/255 vs baseline, but these
are image differences, not perceptual scores or motion quality validation.

Devin recommends balanced900p, with balanced720p as a sharper-performance
tradeoff; neither establishes 60 FPS. Latest full report: `artifacts/matrix.md`.
Remaining limits: CPU/GPU stage attribution and VRAM unavailable; cold scope
limited; moving-camera balanced presets themselves not separately measured;
no actual sparse lighting integration, per-tree visibility/occlusion comparison,
full motion-shimmer evaluation or cross-machine/release-build validation.
