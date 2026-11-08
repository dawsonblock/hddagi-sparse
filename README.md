# HDDAGI Forest — sparse-cascade research work tree

A macOS/Metal development tree for **HDDAGI** (hierarchical dynamic diffuse global
illumination) in a custom **Godot 4.8.dev / Forward+** engine fork, plus a dense
procedurally-seeded forest used as the benchmark scene. The goal: a *believable*
forest that runs faster — measured, not guessed.

> **Platform** Apple M2 Pro · macOS 26.2 · Metal 4 · Forward+ · 1600×900 reference
> **Engine** custom `godot.macos.editor.dev.arm64` (`a3e594ca…`)
> **Status** packaged `HDDAGI.app` verified 23/23 · controlled feature matrix done · sparse bricks probe-only

---

## What this is — and is not

- **A measurement-first performance study.** Every claim traces to a JSON artifact
  under `artifacts/bench/` or a report under `artifacts/`. The benchmark harness
  is *fail-closed*: a run that errors, hangs, or produces a flat/black capture can
  never be reported as a speedup.
- **A working packaged app.** `platform/make_mac_app.sh` stages, validates and
  swaps `HDDAGI.app` atomically; the previous bundle is always preserved.
- **A sparse-brick *infrastructure* study — not a shipping feature.** Sparse
  allocator/probe/canary kernels execute on GPU behind an opt-in gate, but there is
  **no radiance store and no atlas sampling in lighting yet**. The dense renderer is
  the only source of light. Nothing sparse is a renderer saving.
- **Not** a VRAM study. Metal has no GPU timestamps or allocator counters in this
  fork; RSS and static memory are reported separately and never as VRAM.

## Headline results (controlled matrix, 1,500 trees, warm, n=3 interleaved)

All rows: same scene, seed 987654, 1600×900, MSAA 4x, frame-indexed camera path,
binary `a3e594ca…`. Median of three repeats; tails are worst-repeat values.
Full table, per-repeat rows and image diffs: **[`artifacts/matrix.md`](artifacts/matrix.md)**.

| configuration | median p50 | vs base | pixels changed >8* | verdict |
|---|---:|---:|---:|---|
| base — everything on | 37.53 ms | — | — | reference |
| **shipped preset** (LOD rings + far-ring no-shadow) | 29.55 ms | −21.3% | 0.80% | current app default |
| **`bal_looks`** (shipped + MSAA 2x + SSAO off) | **27.99 ms** | **−25.4%** | 4.28% | **recommended** |
| `bal_perf` (bal_looks @720p) | 25.81 ms | −31.2% | n/a (res) | FPS-first option |
| no shadows | 26.36 ms | −29.8% | **83.7%** | real speed, destroys the look |
| GI off | 32.62 ms | −13.1% | **97.0%** (−104 MB RSS) | destroys the look |
| no fog | 35.32 ms | −5.9% | ~100% | destroys the look |

\* A pixel-change % is a **change proxy**, not a perceptual quality score. The
"destroys the look" verdicts are subjective reads of the actual captures in
`artifacts/bench/matrix/snaps/` — the images were viewed, not inferred.

**Recommended balanced preset — `bal_looks`:** keeps every load-bearing visual
(shadows, GI, volumetric + depth fog) and cuts a quarter of the frame time for a
change that is invisible in the viewed stills. Defaults are **not** changed —
applying it is a settings change for the user to approve.

## Repository layout

```
platform/test_project/     the Godot project (forest scene + benchmark harness)
  main.tscn / main.gd      interactive forest scene; env-var capture & smoke hooks
  bench.tscn / bench.gd    deterministic benchmark scene (seeded forest, frame-indexed
                           camera trajectories, per-frame timing, JSON result)
  hddagi_hud.gd            autoloaded perf HUD (F3)
  hddagi_settings_menu.gd  F1 live-settings panel
  hddagi_wind.gd           foliage-wind global uniforms + gust envelope
platform/
  make_mac_app.sh          stage → import → verify → atomic-swap the .app (keeps backups)
  verify_app.py            23-check bundle verifier (parity, imports, headless + rendered smoke)
  test_verify_app.py       capture-parser / image-check unit regressions
  engine_changes.patch     all engine deltas vs the supplied tree (applies at -p1)
  hddagi_sparse_selftest.* sparse probe/self-test source mirrored into the engine build
tools/
  bench_run.sh             one bounded benchmark → artifacts/bench/<tag>.json (fail-closed)
  run_timed.py             process-group timeout wrapper (SIGTERM→SIGKILL, exit 124)
  run_matrix.py            controlled multi-cell matrix: interleaved repeats, prewarm,
                           provenance-validated summary (fails closed on mismatch)
  capture_check.py         structured CAPTURE_STATS parser + flat/white/black rejection
  img_diff.py              pixel-diff between captures (>8/255 channel delta)
  test_failure_modes.sh    29-case failure-injection suite for bench + packaging
  profile_cold_warm.sh     cold/warm × static/teleport/cut profile runner
  analyze_runs.py          distributions and spike counts from bench JSON
  check_engine_copies.sh   engine-copy / patch-drift enforcement (11 checks)
tests/renderer_hddagi_sparse/   CPU oracle: brick layout, allocator, 43 cases
gpu/                       four compute shaders + CPU twin + Metal harnesses
engine/                    capability/dispatch plan core (no RD dependency)
artifacts/                 every report, raw JSON, log, capture and diff — the evidence
```

## Quick start

### Run the app

```bash
# build the packaged app (stages, imports, verifies, then swaps in; keeps the old bundle)
platform/make_mac_app.sh "/Users/dawsonblock/Downloads/hddagi-run/HDDAGI.app"

# or just run the project with the dev engine binary
"/Users/dawsonblock/Downloads/hddagi-build/godot-dynamic_gi_2/bin/godot.macos.editor.dev.arm64" \
    --path platform/test_project
```

In-app: **F1** settings menu · **F3** perf HUD · foliage wind is on by default.

### One benchmark

```bash
env SCENE=forest TREES=1500 RATIO=0.10 FRAMES=300 WARMUP=120 TIMEOUT=180 \
    TAG=my_run BENCH_LOD=rings BENCH_SHADOW_LOD=far \
    ./tools/bench_run.sh
# → artifacts/bench/my_run.json  (raw per-frame ms, p50/95/99, settings,
#   manifest + binary hashes, cache state, peak RSS + scope)
```

### The full controlled matrix

```bash
python3 tools/run_matrix.py            # 89 bounded runs, ~25 min, aborts on first failure
python3 tools/run_matrix.py --summarize  # re-validate + regenerate the table only
CELLS="bal_looks bal_perf" python3 tools/run_matrix.py --phase timing
```

### Verify everything

```bash
platform/verify_app.py "/Users/dawsonblock/Downloads/hddagi-run/HDDAGI.app"   # 23 checks
cd platform && python3 -m unittest test_verify_app -v                        # 14 unit tests
tools/test_failure_modes.sh                                                 # 29 injected-failure tests
tools/check_engine_copies.sh                                                # 11 drift checks
```

## The benchmark harness (why the numbers can be trusted)

`tools/bench_run.sh` is fail-closed. A run **fails** when:

- the engine exits non-zero **or** is killed by the `run_timed.py` timeout (124);
- the log contains script/shader/resource-error patterns;
- no fresh `BENCH_RESULT` line, malformed/stale JSON, or missing frame samples;
- the capture is missing, flat, solid-white or solid-black (contrast gate);
- an existing same-tag JSON would have to be overwritten — failures publish nothing.

Each published JSON records: raw `frame_ms`, percentile distribution, startup
phases, `settings` (effective toggles read back from the live scene), `trajectory`
(frame-indexed), `cache_state`, `binary_sha256`, `project_manifest_sha256`
(`.godot/` + `override.cfg` excluded), `override_cfg_sha256` + contents,
`peak_rss_mb` + `peak_rss_scope` (whole process — *not* steady state), `static_mb`
per-frame, and `timing_usable`. Quality/snapshot runs set `timing_usable: false`
because the readback is inside the window.

`run_matrix.py` pins the entire `BENCH_*` environment per cell, interleaves
repeats, records valid run IDs in `matrix_runs.json`, and re-validates binary +
manifest + `timing_usable` at summary time — a stale or foreign JSON exits 1.

## Feature notes

### Distance / shadow LOD (shipped default)

Camera-relative rings — near <35 m lod0, mid 35–75 m lod1, far >75 m lod2 with the
far ring not casting shadows; rebuilt after 5 m of camera movement. Validated at a
*moved* viewpoint (origin-fixed rings change 24.5% of pixels there; camera-relative
is within run noise). −21.3% frame time, 0.80% of pixels; teleport hitch time
roughly halved. `HDDAGI_LOD`, `HDDAGI_SHADOW_LOD`, `HDDAGI_LOD_NEAR/MID`,
`BENCH_LOD_CAMERA` control it; details in [`artifacts/lod.md`](artifacts/lod.md).

### Teleport hitch

Fixed cause: a teleport marked every GI cascade dirty and rebuilt all six in one
frame (~100 ms). `rendering/global_illumination/hddagi/full_rebuild_budget`
(default 1) spreads them; worst frame 106→64 ms, >50 ms time −90%. Under the
frame-indexed trajectory, each recorded jump still precedes a ~5-frame cluster
(~2.7 on shipped) — reduced, not eliminated; needs engine-side rebuild
amortization beyond the current budget. [`artifacts/teleport_hitch.md`](artifacts/teleport_hitch.md)

### Foliage wind

Five `global uniform` wind parameters registered + gust envelope on `wind_power`
(the others are phase terms — animating them pops the forest). ≤0.1 ms cost.
`HDDAGI_WIND=0` pins power to zero while keeping globals registered; capture mode
disables it. [`artifacts/wind.md`](artifacts/wind.md)

### Perf HUD & settings menu

HUD (F3): FPS/peak, frame/cpu ms, `gpu` falls back to `frame−cpu` labelled
`(est)` because Metal timestamps read 0 — always marked an estimate. Menu (F1):
wind, lighting, fog, overlay — live against the running scene.

## Sparse bricks — honest status

Gate: `rendering/global_illumination/hddagi/sparse_enabled` (default **false**).

- `false` → dense renderer only; logs `HDDAGI_SPARSE_MODE dense`.
- `true` → capability probe (+ self-test if `sparse_selftest`), logs
  `HDDAGI_SPARSE_MODE probe (lighting remains dense; no sparse savings claimed)`.

Measured: image parity effectively exact (0.022% of pixels — GI temporal noise),
zero per-frame cost, probe +36 ms startup, self-test ~0.6 s startup. **No speedup
or memory saving is claimed.** Missing for real sparse lighting: a radiance-store
kernel, a page-table→atlas sampling path in the GI light pass, and per-frame
allocator integration with overflow fallback. [`artifacts/sparse_status.md`](artifacts/sparse_status.md)

## Reports index

| artifact | what it records |
|---|---|
| [`artifacts/matrix.md`](artifacts/matrix.md) | controlled 1,500-tree feature matrix + balanced-preset recommendation |
| [`artifacts/lod.md`](artifacts/lod.md) | tree/shadow LOD before-after + camera-relative validation |
| [`artifacts/cold_start.md`](artifacts/cold_start.md) | packaged cold vs warm startup, distributions, hitches |
| [`artifacts/app_package.md`](artifacts/app_package.md) | app provenance: binary + manifest hashes, 23-check list |
| [`artifacts/bench_hardening.md`](artifacts/bench_hardening.md) | why a failed run can't look like a speedup |
| [`artifacts/sparse_status.md`](artifacts/sparse_status.md) | gate, parity/cost measurements, exact missing pieces |
| [`artifacts/teleport_hitch.md`](artifacts/teleport_hitch.md) | root cause + budget fix |
| [`artifacts/frame_budget.md`](artifacts/frame_budget.md) | where the frame goes (older binary — labelled) |
| [`artifacts/phase2_baseline.md`](artifacts/phase2_baseline.md) | earlier-baseline measurements (older binary — labelled) |
| [`artifacts/decision.md`](artifacts/decision.md) | M0 gate record |
| [`artifacts/m1_report.md`](artifacts/m1_report.md) · [`artifacts/m2_scaffold.md`](artifacts/m2_scaffold.md) | sparse CPU oracle + kernel scaffold |
| [`artifacts/bench/README.md`](artifacts/bench/README.md) | index of every JSON and which claim it backs |

Binary identity matters: numbers gathered under `29fa35ed…` are kept in their
reports but are **not** mixed into `a3e594ca…` comparisons.

## Known limitations

- **No GPU-stage causality on Metal** — timestamps read 0; deltas are frame-time
  deltas, never "GPU savings" or "VRAM savings".
- **Cold** = Godot shader cache moved aside; OS page cache and driver-level Metal
  caches are uncontrolled. Cold cells are single runs (n=1).
- **Pixel diffs are change proxies**; stills cannot show motion shimmer — no
  temporal claims are made.
- **`bal_looks` r1 has a three-frame hitch cluster** (66.8/68.8/71.0 ms at frames
  20–23); retained, cause unconfirmed, not hidden.
- **Run-to-run p50 spread ≈ ±0.2 ms**; sub-millisecond deltas rest on
  repeat-median agreement.
- The sparse path lights nothing — step 5 (radiance storage/sampling + lighting
  integration) is open work, tracked in `sparse_status.md`.

## Working rules this repo follows

- Nothing in `artifacts/` is a VRAM measurement; arithmetic estimates are labelled.
- Every report names its binary hash, project manifest hash, and run conditions.
- The previous `HDDAGI.app` bundle is always preserved (`HDDAGI.app.bak-*`).
- `platform/` engine copies, `engine_changes.patch` and the build tree must agree —
  `check_engine_copies.sh` enforces it.
- Benchmark defaults ≠ app defaults by design; every matrix cell sets explicit
  toggles and records the effective set.
