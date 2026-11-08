#!/usr/bin/env python3
"""Controlled 1,500-tree benchmark matrix for the HDDAGI project.

One bounded run at a time, interleaved repeats so machine drift lands on every
cell evenly, and every repeat is kept on disk — the report uses the median of
the repeats, never a cherry-picked clean one.

    python3 tools/run_matrix.py                 # full matrix
    python3 tools/run_matrix.py --phase timing  # timing cells only
    python3 tools/run_matrix.py --phase quality # capture/diff runs only
    CELLS="base shipped" python3 tools/run_matrix.py

Like-for-like contract: forest scene, 1,500 trees, GI on, solid_cell_ratio 0.10,
1600x900, the same engine binary, warm Godot shader cache (each cell is prewarmed
before its repeats), deterministic RNG placement and a frame-indexed camera
trajectory. Runs labelled cold move the shader cache aside first.

Results go to artifacts/bench/matrix/; an aggregate summary.json and a printed
Markdown table are produced at the end.
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parent
OUTDIR = WORKSPACE / "artifacts" / "bench" / "matrix"
BENCH = WORKSPACE / "tools" / "bench_run.sh"
BIN = WORKSPACE.parent / "hddagi-build" / "godot-dynamic_gi_2" / "bin" / "godot.macos.editor.dev.arm64"
SNAP_DIR = OUTDIR / "snaps"

REPS = 3

# Every toggle the harness or runner reads is pinned here, and run_one strips
# all BENCH_* keys from the inherited environment first: an exported
# BENCH_SHADOWS=0 or CAMERA=teleport in the caller's shell must not contaminate
# the `base` cell. Empty strings mean "harness default".
BASELINE = {
    "CAMERA": "static",
    "COLD": "0",
    "EXTRA": "",
    "REBUILD": "",
    "CASCADES": "6",
    "HUD": "0",
    "WIND": "0",
    "BENCH_SHADOWS": "1",
    "BENCH_TREE_SHADOW": "1",
    "BENCH_GRASS_SHADOW": "0",
    "BENCH_LOD": "off",
    "BENCH_LOD_NEAR": "35",
    "BENCH_LOD_MID": "75",
    "BENCH_LOD_CAMERA": "1",
    "BENCH_SHADOW_LOD": "off",
    "BENCH_TREE_LOD": "0",
    "BENCH_SHADOW_DISTANCE": "150",
    "BENCH_FOG": "1",
    "BENCH_VOLFOG": "1",
    "BENCH_SSAO": "1",
    "BENCH_GLOW": "1",
    "BENCH_MSAA": "",
    "BENCH_WIDTH": "1600",
    "BENCH_HEIGHT": "900",
    "BENCH_TELEPORT_PERIOD": "25",
    "BENCH_CUT_FRAME": "10",
    "BENCH_SNAP": "",
    "BENCH_SNAP_DIR": str(SNAP_DIR),
}

# Each cell changes exactly one thing relative to `base`, except `shipped` and
# `res720`, which compose the two implemented visibility levers the app ships.
SHIPPED = {"BENCH_LOD": "rings", "BENCH_SHADOW_LOD": "far"}
CELLS = {
    # name        env overrides                    description
    "base":      ({},                              "everything on, lod0, all shadows"),
    "noshadow":  ({"BENCH_SHADOWS": "0"},          "sun shadow map off"),
    "treelod":   ({"BENCH_LOD": "rings"},          "geometry LOD only; all trees still cast"),
    "shadowlod": ({"BENCH_SHADOW_LOD": "far"},     "far ring stops casting; lod0 geometry"),
    "shipped":   (SHIPPED,                         "app default: rings + far shadows off"),
    "nogi":      ({"GI": "off"},                   "HDDAGI dynamic GI off"),
    "novolfog":  ({"BENCH_VOLFOG": "0"},           "volumetric fog off, cheap fog kept"),
    "nofog":     ({"BENCH_VOLFOG": "0", "BENCH_FOG": "0"}, "both fog paths off"),
    "msaa0":     ({"BENCH_MSAA": "0"},             "MSAA off (project default is 4x)"),
    "msaa2x":    ({"BENCH_MSAA": "1"},             "MSAA 2x instead of 4x"),
    "nossao":    ({"BENCH_SSAO": "0"},             "SSAO off"),
    "noglow":    ({"BENCH_GLOW": "0"},             "bloom off"),
    "res720":    ({**SHIPPED, "BENCH_WIDTH": "1280", "BENCH_HEIGHT": "720"},
                  "shipped toggles at 1280x720"),
    # Balanced-preset candidates (phase B): composed from the measured cheap
    # levers. bal_looks keeps 1600x900 and both fog paths; bal_perf also drops
    # to 720p. Neither touches shadows, GI or tree LOD policy.
    "bal_looks": ({**SHIPPED, "BENCH_MSAA": "1", "BENCH_SSAO": "0"},
                  "shipped + MSAA 2x + SSAO off, 1600x900"),
    "bal_perf":  ({**SHIPPED, "BENCH_MSAA": "1", "BENCH_SSAO": "0",
                   "BENCH_WIDTH": "1280", "BENCH_HEIGHT": "720"},
                  "shipped + MSAA 2x + SSAO off at 1280x720"),
}

# Moving-camera cells share the identical frame-indexed trajectory.
TELEPORT_CELLS = {
    "tele_base":    ({"CAMERA": "teleport"}, "base toggles, teleport every 25 frames"),
    "tele_shipped": ({**SHIPPED, "CAMERA": "teleport"}, "shipped toggles, teleport"),
}

# Cold = Godot shader cache moved aside once; a single run per cell.
COLD_CELLS = {
    "cold_base":    ({"COLD": "1"}, "base toggles, shader cache absent"),
    "cold_shipped": ({**SHIPPED, "COLD": "1"}, "shipped toggles, shader cache absent"),
}

# Quality runs snap a frame for pixel diffs; their timings are flagged unusable.
QUALITY_SNAPS = {"static": ("100", "120", "60"), "cut": ("30", "40", "60")}
QUALITY_CELLS = ["base", "treelod", "shadowlod", "shipped", "noshadow", "nogi",
                 "novolfog", "nossao", "msaa0", "msaa2x", "noglow", "res720", "nofog",
                 "bal_looks", "bal_perf"]
QUALITY_CUT_CELLS = ["base", "treelod", "shadowlod", "shipped"]


def run_one(tag, env_overrides, outdir=OUTDIR):
    # Strip every harness toggle first so the caller's shell cannot leak a
    # BENCH_*/CAMERA/COLD/EXTRA into a cell that did not ask for it.
    env = {k: v for k, v in os.environ.items() if not k.startswith("BENCH_")}
    env.update({
        "SCENE": "forest",
        "TREES": "1500",
        "RATIO": "0.10",
        "GI": "on",
        "FRAMES": "300",
        "WARMUP": "120",
        "TIMEOUT": "180",
        "HDDAGI_BIN": str(BIN),
        "OUTDIR": str(outdir),
        "CACHE_STATE": "warm",
        "TAG": tag,
    })
    env.update(BASELINE)
    env.update(env_overrides)
    t0 = time.monotonic()
    proc = subprocess.run([str(BENCH)], env=env)
    dt = time.monotonic() - t0
    return proc.returncode, dt


def phase_timing(cells):
    wanted = [c for c in cells if c in CELLS]
    # One prewarm per cell before its first measured repeat: rep0 must not pay
    # first-use pipeline compilation or it is not a warm run. Repeats are
    # interleaved (r0 of every cell, then r1s, then r2s) so machine drift lands
    # on every cell evenly.
    jobs = []
    for c in wanted:
        jobs.append((f"pre_{c}", {**CELLS[c][0], "WARMUP": "30", "FRAMES": "30",
                                  "MATRIX_CELL": c, "REP": "-1"}))
    for rep in range(REPS):
        for c in wanted:
            jobs.append((f"m_{c}_r{rep}", {**CELLS[c][0], "MATRIX_CELL": c, "REP": str(rep)}))
    # Teleport and cold cells belong to the full matrix; a subset run via
    # CELLS=... (e.g. a follow-up balanced cell) skips them.
    if os.environ.get("CELLS"):
        return jobs
    # Teleport prewarm covers the full 4-point cycle: a jump happens every
    # BENCH_TELEPORT_PERIOD=25 frames, so the prewarm needs >100 frames total to
    # visit all four viewpoints before its repeats are measured.
    for name in TELEPORT_CELLS:
        env = TELEPORT_CELLS[name][0]
        jobs.append((f"pre_{name}", {**env, "WARMUP": "60", "FRAMES": "60",
                                     "MATRIX_CELL": name, "REP": "-1"}))
    for rep in range(REPS):
        for name in TELEPORT_CELLS:
            env = TELEPORT_CELLS[name][0]
            jobs.append((f"m_{name}_r{rep}", {**env, "MATRIX_CELL": name, "REP": str(rep)}))
    for name, (env, _desc) in COLD_CELLS.items():
        jobs.append((f"m_{name}", {**env, "MATRIX_CELL": name, "REP": "0",
                                   "CACHE_STATE": "cold"}))
    return jobs


def phase_quality(cells):
    snap, frames, warmup = QUALITY_SNAPS["static"]
    csnap, cframes, cwarmup = QUALITY_SNAPS["cut"]
    jobs = []
    for c in QUALITY_CELLS:
        if cells and c not in cells:
            continue
        env = CELLS[c][0]
        jobs.append((f"q_{c}", {**env, "BENCH_SNAP": snap, "FRAMES": frames,
                                "WARMUP": warmup, "BENCH_SNAP_DIR": str(SNAP_DIR),
                                "MATRIX_CELL": c, "REP": "0"}))
    for c in QUALITY_CUT_CELLS:
        if cells and c not in cells:
            continue
        env = {**CELLS[c][0], "CAMERA": "cut"}
        jobs.append((f"q_{c}_cut", {**env, "BENCH_SNAP": csnap, "FRAMES": cframes,
                                    "WARMUP": cwarmup, "BENCH_SNAP_DIR": str(SNAP_DIR),
                                    "MATRIX_CELL": c + "_cut", "REP": "0"}))
    return jobs


def sha256_file(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def base_project_digest():
    sys.path.insert(0, str(WORKSPACE / "platform"))
    from verify_app import manifest_digest, tree_manifest
    return manifest_digest(
        tree_manifest(WORKSPACE / "platform" / "test_project",
                      exclude=(".godot", "override.cfg")))


def summarize():
    """Aggregates only the runs this matrix recorded in matrix_runs.json.

    A stale m_*_r*.json left by an older or aborted run must not enter the
    table, so membership comes from the run manifest, and every row is checked
    against the current binary hash, the base-project manifest hash and
    timing_usable/run_kind. Fail-closed: a missing manifest, a missing JSON or
    any provenance mismatch is an error, never silently skipped.
    """
    run_list = OUTDIR / "matrix_runs.json"
    if not run_list.is_file():
        print("error: matrix_runs.json missing; refusing to aggregate unnamed files",
              file=sys.stderr)
        return 1
    recorded = {r["tag"]: r for r in json.loads(run_list.read_text())}
    paths = [OUTDIR / f"{tag}.json" for tag in sorted(recorded)]
    bin_sha = sha256_file(BIN)
    proj_sha = base_project_digest()
    problems = []

    rows = {}
    skipped = []
    for path in paths:
        if not path.is_file():
            problems.append(f"{path.name}: recorded but JSON missing")
            continue
        tag = path.stem
        if not tag.startswith("m_"):
            skipped.append(tag)
            continue
        d = json.loads(path.read_text())
        if d.get("tag") != tag:
            problems.append(f"{tag}: inner tag {d.get('tag')!r} mismatch")
            continue
        if d.get("binary_sha256") != bin_sha:
            problems.append(f"{tag}: binary {str(d.get('binary_sha256'))[:12]} != {bin_sha[:12]}")
            continue
        if d.get("project_manifest_sha256") != proj_sha:
            problems.append(f"{tag}: project manifest mismatch")
            continue
        if d.get("run_kind") != "timing" or d.get("timing_usable") is not True:
            problems.append(f"{tag}: not a usable timing run")
            continue
        cell = d.get("matrix_cell", d.get("tag"))
        raw = d.get("raw_frame_ms") or []
        row = {
            "tag": tag,
            "rep": d.get("rep"),
            "cache_state": d.get("cache_state"),
            "p50": d["frame_ms"]["p50"],
            "p95": d["frame_ms"]["p95"],
            "p99": d["frame_ms"]["p99"],
            "max": d["frame_ms"]["max"],
            "mean": d["frame_ms"]["mean"],
            "o33": sum(1 for x in raw if x > 33),
            "o50": sum(1 for x in raw if x > 50),
            "o80": sum(1 for x in raw if x > 80),
            "time50": round(sum(x for x in raw if x > 50), 1),
            "worst_frame": raw.index(max(raw)) if raw else -1,
            "peak_rss_mb": d.get("peak_rss_mb"),
            "static_mb_p50": d.get("static_mb", {}).get("p50"),
            "elapsed_s": d.get("elapsed_s"),
            "scene_built_ms": (d.get("timing_ms") or {}).get("scene_built"),
            "viewport": (d.get("settings") or {}).get("viewport_size"),
        }
        rows.setdefault(cell, []).append(row)
    summary_rows = {}
    for cell, rs in rows.items():
        rs.sort(key=lambda r: (r["rep"] if r["rep"] is not None else 9))
        p50s = sorted(r["p50"] for r in rs)
        med = p50s[len(p50s) // 2]
        summary_rows[cell] = {
            "reps": rs,
            "median_p50": med,
            "spread_p50": round(max(p50s) - min(p50s), 3),
            "worst_rep_p95": max(r["p95"] for r in rs),
            "worst_rep_p99": max(r["p99"] for r in rs),
            "n": len(rs),
        }
    out = {
        "generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "reps_per_cell": REPS,
        "binary_sha256": bin_sha,
        "project_manifest_sha256": proj_sha,
        "validation_problems": problems,
        "skipped_non_timing": sorted(skipped),
        "cells": {c: {"env": CELLS.get(c, ({}, ""))[0], "description": CELLS.get(c, ({}, ""))[1]}
                  for c in summary_rows},
        "results": summary_rows,
    }
    (OUTDIR / "summary.json").write_text(json.dumps(out, indent=2) + "\n")

    print("| cell | rep p50s | median p50 | worst-rep p95 | worst-rep p99 | max | >50ms sum | RSS MB |")
    print("|---|---|---|---|---|---|---|---|")
    for cell in summary_rows:
        info = summary_rows[cell]
        rs = info["reps"]
        p50s = ", ".join(f"{r['p50']:.2f}" for r in rs)
        rss = max((r["peak_rss_mb"] or 0) for r in rs)
        o50 = sum(r["o50"] for r in rs)
        print(f"| {cell} | {p50s} | {info['median_p50']:.2f} | {info['worst_rep_p95']:.2f} | "
              f"{info['worst_rep_p99']:.2f} | {max(r['max'] for r in rs):.1f} | "
              f"{o50} | {rss:.0f} |")
    if problems:
        print()
        print("validation problems:")
        for p in problems:
            print(f"  - {p}")
        print(f"FAIL: {len(problems)} validation problem(s); table above is not trustworthy",
              file=sys.stderr)
        return 1
    return 0


def main():
    phase = "all"
    args = sys.argv[1:]
    if "--phase" in args:
        phase = args[args.index("--phase") + 1]
    cells = os.environ.get("CELLS", "").split() or list(CELLS)
    if "--summarize" in args:
        return summarize()

    OUTDIR.mkdir(parents=True, exist_ok=True)
    SNAP_DIR.mkdir(parents=True, exist_ok=True)

    jobs = []
    if phase in ("all", "timing"):
        jobs += phase_timing(cells)
    if phase in ("all", "quality"):
        jobs += phase_quality(cells)
    total = len(jobs)
    print(f"{total} bounded runs, one at a time; aborting on the first failure")
    run_list = OUTDIR / "matrix_runs.json"
    completed = json.loads(run_list.read_text()) if run_list.is_file() else []
    completed_map = {r["tag"]: r for r in completed}
    # Planned env per tag over the keys that actually reach the harness/runner;
    # unrelated shell variables are not part of a run's identity.
    fixed = {"SCENE": "forest", "TREES": "1500", "RATIO": "0.10", "GI": "on",
             "FRAMES": "300", "WARMUP": "120", "TIMEOUT": "180",
             "HDDAGI_BIN": str(BIN), "OUTDIR": str(OUTDIR), "CACHE_STATE": "warm"}
    planned = {tag: {**fixed, **BASELINE, **env, "TAG": tag} for tag, env in jobs}
    for i, (tag, env) in enumerate(jobs, 1):
        if tag in completed_map:
            # Resume is only legitimate when the recorded run used the identical
            # job overrides. Older entries recorded just the override dict, so
            # the comparison is exactly the keys that define the run; the JSON
            # itself is re-validated (binary, manifest, timing_usable) by
            # summarize(). A tag collision with different overrides is a stale
            # artifact — fail closed rather than reuse it.
            rec_env = completed_map[tag].get("env") or {}
            mismatches = sorted(k for k in env if rec_env.get(k) != env.get(k))
            if mismatches:
                print(f"recorded run {tag} has different settings for {mismatches}; "
                      f"refusing to reuse it. Remove artifacts/bench/matrix/{tag}.json "
                      f"and the matrix_runs.json entry, then re-run.", file=sys.stderr)
                return 1
            print(f"[{i}/{total}] {tag} ... already recorded, skipping")
            continue
        print(f"[{i}/{total}] {tag} ...", flush=True)
        code, dt = run_one(tag, env)
        print(f"    {'ok' if code == 0 else 'FAILED'} in {dt:.1f}s", flush=True)
        if code != 0:
            print(f"matrix aborted: {tag} failed (see artifacts/bench/matrix/logs/{tag}.log)",
                  file=sys.stderr)
            return 1
        completed.append({"tag": tag, "env": planned[tag], "elapsed_s": round(dt, 1)})
        run_list.write_text(json.dumps(completed, indent=2) + "\n")
    if phase in ("all", "timing"):
        summarize()
    return 0


if __name__ == "__main__":
    sys.exit(main())
