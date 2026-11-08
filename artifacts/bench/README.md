# Phase 2 bench runs

One JSON per `tools/bench_run.sh` invocation. These are raw evidence rather than curated
summaries: every number quoted in `artifacts/*.md` is derived from a file here, and the
files are kept so a claim can be re-derived instead of trusted.

`logs/<tag>.log` holds the complete engine output for the same run. A result JSON only
exists if the run passed the hardening checks in `artifacts/bench_hardening.md`: exit 0,
no engine/script/shader/resource errors, a captured frame with real contrast, and a
freshly written JSON whose tag and frame count match. A failed run keeps the previous
JSON of the same tag untouched.

## Reading a file

| key | meaning |
|---|---|
| `frame_ms` | wall-clock frame time over the measured frames: mean, p50, p95, p99, min, max |
| `raw_frame_ms` | the per-frame samples the percentiles and the "frames over N ms" counts come from |
| `cpu_render_ms` | `viewport_get_measured_render_time_cpu`, a real measurement |
| `gpu_ms` | always 0 on Metal in this fork; `gpu_timing_available` records that explicitly |
| `static_mb` | `Performance.MEMORY_STATIC`, sampled per measured frame — the steady-state engine figure |
| `peak_rss_mb` | whole-process peak RSS from `tools/run_timed.py`; includes startup, warmup and the final capture readback, not a steady-state sample (`peak_rss_scope` says so) |
| `process_budget_log` | the engine's `HDDAGI_PROCESS_BUDGET` line (`solid_cell_ratio`) |
| `rebuild_budget_log` | the engine's `HDDAGI_REBUILD_BUDGET` line (`full_rebuild_budget`) |
| `binary_sha256` | identity of the binary that produced the run |
| `run_log` | the preserved engine log for this run |
| `run_kind`, `timing_usable` | `timing` runs have clean timings; `quality` runs snap frames inside the window and are for image diffs only |
| `settings` | the effective toggle set read back from the live scene (LOD, shadows, fog, MSAA, GI, viewport…) |
| `trajectory` | camera path parameters; `indexed_by: frame` means the path is identical across configurations |
| `cache_state` | `cold` = Godot shader cache moved aside; `warm` = present; `unknown` = not recorded |
| `project_manifest_sha256` | base-project hash excluding `.godot/` and `override.cfg`; comparable to the package manifest |
| `override_cfg_sha256`, `override_cfg` | the exact override that was in force, hashed and inlined |
| `matrix_cell`, `rep` | matrix cell name and repeat index |
| `elapsed_s` | whole engine invocation time measured by `run_timed.py` |

`rebuild_budget_log` and `binary_sha256` were added after the first runs, and
`settings`/`trajectory`/`cache_state`/manifest fields were added for the matrix pass,
so earlier files do not carry those keys. The provenance of those runs is in the header
of the artifact document that quotes them.

## Tags

A tag is either derived from the configuration
(`<scene>_<camera>_gi<on|off>[_r<ratio>]_t<trees>`) or passed explicitly with `TAG=`.

| files | backs | what it is |
|---|---|---|
| `base.json`, `base_after_grass.json` | `frame_budget.md` §2 | before/after grass shadow casting |
| `no_shadows`, `no_tree_shadow`, `no_grass_shadow`, `gs0`, `gs1` | `frame_budget.md` §1-2 | shadow cost, one layer at a time |
| `no_volfog`, `no_msaa`, `no_ssao`, `no_fog`, `no_glow` | `frame_budget.md` §1 | one feature disabled per run |
| `shadow1024`, `shadow2048` | `frame_budget.md` §3-4 | shadow map resolution sweep |
| `treelod2` | `frame_budget.md` §3B | whole forest forced to LOD2 |
| `static_after`, `move_after`, `move_after_grass` | `frame_budget.md` §2 | post-fix static and moving baselines |
| `hud_0`, `hud_1` | `README.md` HUD section | overlay cost |
| `tele_casc1`, `tele_casc2` | `teleport_hitch.md` §2 | per-cascade cost, by cascade count |
| `tele_budget0..3`, `tele_rep0`, `tele_rep1` | `teleport_hitch.md` §4 | rebuild-budget sweep and repeats |
| `b0`, `b1`, `b0_rerun`, `c0`, `c1` | `teleport_hitch.md` §5 | the deterministic cut, budget 0 vs 1 |
| `perf*_wind0/1`, `perf_move_wind`, `wind0`, `wind1` | `wind.md` §5 | wind cost, two independent pairs |
| `windcal`, `windcal2`, `windref` | `wind.md` §4 | wind calibration runs |
| `forest_*`, `empty_*`, `room_*`, `rep_forest600_static_*` | `phase2_baseline.md` | baseline grid: scene x GI x ratio x trees |
| `cold_*_t1500`, `warm_*_t1500` | `cold_start.md` | packaged 1,500-tree config, pipeline cache cleared vs warm |
| `lod_*`, `lodq_*`, `lodimg_*` | `lod.md` | distance tree LOD and shadow LOD sweeps |
| `hardening_clean` | `bench_hardening.md` | control run for the failure-injection suite |
| `matrix/` | `matrix.md` | controlled 1,500-tree isolation matrix: `pre_*` prewarm, `m_<cell>_r<0..2>` interleaved repeats, `m_cold_*` shader-cache-cold runs, `q_*` quality snaps; `matrix_runs.json` lists the valid run IDs and `summary.json` aggregates them |

Reruns are kept deliberately. Run-to-run variation on this machine is a few tenths of a
millisecond at p50 and several milliseconds at max, which is why any claim that turns on
a difference below ~1 ms is backed by at least two runs.
