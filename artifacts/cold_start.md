# Cold start and remaining hitches — packaged 1,500-tree configuration

Executed 2026-11-08 on Apple M2 Pro, macOS 26.2, Metal 4, Forward+, 1600x900.
Engine binary `29fa35ed5bc45167ed2e23368a82ecef49f029dd83fb9c31946bbf714eb77a9e`
— an earlier build than the binary currently embedded in `HDDAGI.app`
(`a3e594ca…`, which adds the sparse probe gate). These rows predate the gate;
they are not comparable to `matrix.md` rows run under `a3e594ca`. Scene: forest,
1,500 trees, GI on, `solid_cell_ratio` at the project value (0.10).

The bundle embeds this exact project (107/107 files identical at package time). The
runs below use the source project so the timing instrumentation added for this pass is
present; the app is rebuilt from the same source at the end.

## Method

- **Cold** = the Godot shader/pipeline cache
  (`~/Library/Application Support/Godot/app_userdata/HDDAGI Forest/shader_cache`) is
  moved aside before the run. It is moved, never deleted
  (`shader_cache.bak-<stamp>-<config>`). The OS page cache is **not** dropped, and
  any driver-level Metal caches Apple keeps outside the Godot directory are not
  controlled, so "cold" here means strictly *Godot shader cache absent* — not
  "all caches cold".
- **Warm** = the same configuration immediately after, using the cache the cold run
  produced.
- Frame times are wall-clock between `_process` calls with vsync off and `max_fps=0`;
  GPU timestamps do not exist on Metal in this fork, so `gpu_ms` is 0 and
  `gpu_timing_available` is false.
- Distributions and spike counts come from `raw_frame_ms` in each JSON, not from the
  printed average.

## App startup (main scene, 1,500 trees, 5 frames)

`/usr/bin/time -p` around the packaged engine binary, two independent cold/warm pairs:

| run | cold | warm |
|---|---:|---:|
| pair 1 | **11.38 s** | 2.66 s |
| pair 2 | **10.10 s** | 2.60 s |

The first launch after the cache is gone costs **~8 s more** than a warm launch. The
cold run is compiling the pipeline variants the scene needs on first use.

## Bench-scene startup breakdown

Process-relative milliseconds recorded in each JSON's `timing_ms`:

| run | engine ready | scene built | scene build | 120 warmup frames | avg warmup frame |
|---|---:|---:|---:|---:|---:|
| cold static | 3,606 | 4,644 | 1,038 | 9,773 | 81.4 ms |
| warm static | 1,226 | 1,468 | 242 | 5,534 | 46.1 ms |
| cold teleport | 3,593 | 4,656 | 1,063 | 10,732 | 89.4 ms |
| warm teleport | 1,180 | 1,416 | 236 | 6,251 | 52.1 ms |
| cold cut (60 warmup) | 3,579 | 4,647 | 1,068 | 7,636 | 127.2 ms |
| warm cut (60 warmup) | 1,242 | 1,477 | 235 | 3,064 | 51.1 ms |

Cold costs ~2.4 s in engine boot, ~0.8 s in scene construction, and roughly doubles
the per-frame cost of the first 60-120 frames.

## Frame-time distribution

| tag | trees | cam | p50 | p95 | p99 | max | >33 | >50 | >80 | time>50 | worst# | start |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| cold_static_t1500 | 1500 | static | 37.01 | 37.76 | 39.33 | 450.3 | 298 | 2 | 1 | 517 | 50 | 4644 |
| warm_static_t1500 | 1500 | static | 37.41 | 38.64 | 39.37 | 41.2 | 300 | 0 | 0 | 0 | 3 | 1468 |
| cold_teleport_t1500 | 1500 | teleport | 38.19 | 65.04 | 78.56 | 123.4 | 299 | 69 | 3 | 4416 | 220 | 4656 |
| warm_teleport_t1500 | 1500 | teleport | 38.00 | 65.34 | 78.87 | 123.9 | 300 | 67 | 3 | 4314 | 138 | 1416 |
| cold_cut_t1500 | 1500 | cut | 38.37 | 60.88 | 87.06 | 113.7 | 60 | 5 | 2 | 389 | 12 | 4647 |
| warm_cut_t1500 | 1500 | cut | 38.49 | 63.51 | 68.78 | 93.8 | 59 | 7 | 1 | 473 | 12 | 1477 |

`>33/50/80` are frame counts; `time>50` is total milliseconds spent in frames over
50 ms. At 1,500 trees the static baseline is **37.4 ms p50 (26.7 FPS)**, against
24.16 ms (41.3 FPS) at 600 trees in `frame_budget.md`: density costs ~13 ms.

## The remaining hitches

**1. A 450 ms late spike in the first cold run.** `cold_static` has one 450.3 ms
frame at measured frame 50 (process frame 170), with a 66 ms frame two frames later.
The warm run's worst frame is 41.2 ms. The most likely explanation is a pipeline
variant that is not needed until the GI/shadow state reaches a certain point, so
it survives 120 warmup frames and lands inside the measurement — but Metal gives
no GPU timestamps in this fork and no compile log was captured, so this is an
inference from the cold-vs-warm difference, not a measured compile event. It is
the largest single-frame cost left in the static path and it is not cascade work.

**2. Teleporting at 1,500 trees costs 22% of frames.** `warm_teleport` has p95
65.3 ms, max 123.9 ms, **67 of 300 frames over 50 ms**, and 4.31 s spent in those
frames. It is essentially identical cold and warm (65.0 vs 65.3 ms p95), so this is
the cascade rebuild cost, not the shader cache. The 123 ms frames recur roughly every
93 measured frames (three times in 300), while 78 ms frames are the ordinary
post-teleport rebuild frames.

The rebuild budget of 1 is still doing its job — without it the 600-tree measurement
was a single 106 ms frame; here it is spread across frames — but at this density one
cascade rebuild plus the 38 ms base frame lands at ~60-80 ms, so a teleport every
second keeps the scene permanently in rebuild.

**3. A deterministic cut costs 94-114 ms, then decays.** `warm_cut` frame 12 is
93.8 ms, then 63.5, 61.8, 64.6, 68.8 over the next frames. Cold is 113.7 ms. This is
the same cascade work as the teleport, concentrated at the cut.

## Reproducing

```bash
cd hddagi-sparse

# six runs: {cold,warm} x {static,teleport,cut}, cache moved aside per cold run
PROJECT="$PWD/platform/test_project" TREES=1500 ./tools/profile_cold_warm.sh

python3 tools/analyze_runs.py \
  artifacts/bench/cold_static_t1500.json artifacts/bench/warm_static_t1500.json \
  artifacts/bench/cold_teleport_t1500.json artifacts/bench/warm_teleport_t1500.json \
  artifacts/bench/cold_cut_t1500.json artifacts/bench/warm_cut_t1500.json

# packaged-app startup, cold then warm
CACHE="$HOME/Library/Application Support/Godot/app_userdata/HDDAGI Forest/shader_cache"
mv "$CACHE" "$CACHE.bak-manual-$(date +%s)"
/usr/bin/time -p env HDDAGI_TREES=1500 HDDAGI_HUD=0 HDDAGI_WIND=0 \
  "../hddagi-build/godot-dynamic_gi_2/bin/godot.macos.editor.dev.arm64" \
  --path platform/test_project --quit-after 5
/usr/bin/time -p env HDDAGI_TREES=1500 HDDAGI_HUD=0 HDDAGI_WIND=0 \
  "../hddagi-build/godot-dynamic_gi_2/bin/godot.macos.editor.dev.arm64" \
  --path platform/test_project --quit-after 5
```

JSONs and full engine logs: `artifacts/bench/{cold,warm}_*_t1500.json` and
`artifacts/bench/logs/`. The cold runs' cache backups remain in the Godot user-data
directory and can be deleted by hand.

## Known limitations

- Cold means pipeline cache only. The OS page cache stays warm, so disk-read costs are
  not represented.
- The teleport camera jumps every second, which is a stress pattern rather than normal
  play. The 22% over-50 ms figure describes that pattern, not a typical session.
- These runs use the source project with the packaged engine binary; the bundle is
  rebuilt from the same source at the end of this pass. At package time the embedded
  project was verified byte-identical (107/107 files).
- GPU time is unavailable on Metal in this fork. CPU render submission is ~0.8 ms
  against a ~37 ms wall-clock frame, which is consistent with GPU-bound
  rendering but is not proof of it: the wall clock also includes compositing,
  present and driver queues, and no GPU stage can be timed here.
- The 450 ms cold compile is characterized, not fixed. The likely fix (pre-warming
  pipelines at load, or async compilation) is outside the benchmark harness.
