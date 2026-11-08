# Benchmark hardening

A benchmark that measures a broken scene reports a speedup. The Phase 2 runner used
to accept a `BENCH_RESULT` line even when the engine exited non-zero, ignored stderr,
and wrote directly to `artifacts/bench/<tag>.json`, so a failed run could leave an old
file looking fresh. The harness itself only warned when a tree mesh failed to load.

This pass makes a run either trustworthy or explicitly failed.

## What a run must satisfy now

`tools/bench_run.sh` refuses to publish a result unless all of these hold:

1. the engine exits **0** (previously ignored)
2. the log contains `BENCH_RESULT`
3. the log contains `BENCH_CAPTURE_STATS` — proof that the final frame was captured
4. the captured frame has real contrast: `range >= 30`, `max >= 50`, `mean >= 20`
5. the log contains no `ERROR:`, `SCRIPT ERROR:`, `SHADER ERROR:`,
   `Failed loading resource:`, `Failed to load`, `Can't open file` or
   `Failed to compile`
6. the JSON was written to a temporary path this run, has the requested tag, the
   requested measured-frame count, that many raw samples, and a non-zero p50
7. only then is it moved over `artifacts/bench/<tag>.json`

Diagnostics are kept in `artifacts/bench/logs/<tag>.log` (engine stdout and stderr
together; `/usr/bin/time` stats go to a separate temp file). A failed run leaves any
previous JSON of the same tag untouched and says so.

An existing `override.cfg` in the project is copied aside before the run and restored
on exit, including on INT/TERM.

## Harness changes (`platform/test_project/bench.gd`)

- missing tree mesh, wrong species count, missing grass mesh, missing terrain albedo,
  wrong instance count and an empty rendering adapter all call `_fail()`, print
  `BENCH_FAILED reason=...` and exit 2
- after the measured frames, the harness captures the final frame and prints
  `BENCH_CAPTURE_STATS <json>`; the readback is after measurement, so it never enters
  the timings
- `platform/test_project/capture_stats.gd` is shared with the smoke scene and uses
  `preload`, so it works before the global script-class cache is regenerated
- `tools/capture_check.py` is the single implementation of the contrast thresholds,
  used by both the app verifier and the bench runner

## Failure matrix

`tools/test_failure_modes.sh` runs 26 assertions against temporary copies; the real
project, bundle and artifacts are never modified. Result: **26 passed, 0 failed**.

| case | expected | result |
|---|---|---|
| clean run | exit 0, JSON and log written | pass |
| missing `oak_lod0.res` | fail, no JSON, log names the asset | pass |
| missing `grass_albedo.png` + `.import` | fail, no JSON | pass |
| parse error appended to `bench.gd` | fail, `SCRIPT ERROR` in log | pass |
| `bench.tscn` missing | fail, no JSON | pass |
| stale JSON + failing run (same tag) | fail, stale file unchanged | pass |
| stale JSON + clean run (same tag) | exit 0, stale file replaced | pass |
| pre-existing `override.cfg` | restored byte for byte | pass |
| solid white capture | rejected as flat | pass |
| rendered capture | accepted | pass |
| package import failure (fake engine) | exit 1, previous bundle unchanged | pass |
| verifier binary mismatch | fail | pass |
| verifier missing embedded file | fail | pass |
| verifier unexpected extra file | fail | pass |
| verifier missing import dest | fail | pass |

## Reproducing

```bash
cd hddagi-sparse
./tools/test_failure_modes.sh          # 26 failure-injection assertions
python3 platform/test_verify_app.py    # 13 parser/image regressions
TAG=clean SCENE=forest TREES=60 FRAMES=20 WARMUP=20 RATIO=0.10 ./tools/bench_run.sh
```

The last command writes `artifacts/bench/hardening_clean.json` and
`artifacts/bench/logs/hardening_clean.log`; it is the control run for the matrix.

## Known limitations

- The error scan is substring-based. It deliberately does not fail on `WARNING:`;
  a new benign line containing `ERROR:` would have to be added to the allowlist
  (there is none today).
- `BENCH_CAPTURE_STATS` samples every 7th pixel. It is a blank/flat-frame detector,
  not an image-quality metric.
- The failure suite runs a 20-tree, 8-frame scene so the cases stay fast; the clean
  control is not a performance measurement.
- GPU timing remains unavailable on Metal in this fork, so `gpu_ms` is 0 and
  `gpu_timing_available` is false. The runner records that rather than treating 0 as
  free.
