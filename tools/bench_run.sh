#!/usr/bin/env bash
# Phase 2 benchmark runner.
#
# Runs one configuration of the HDDAGI smoke project under the bench harness and
# records frame-time statistics, CPU render time and peak resident memory.
#
# The configuration is passed through override.cfg, which Godot loads on top of
# project.godot. Nothing in the project is edited, so runs are reproducible and
# the checked-in project file keeps its own defaults.
#
# A run only produces a result file if it is trustworthy:
#   - the engine must exit 0 within TIMEOUT seconds (a hung engine is killed, 124)
#   - the log must contain BENCH_RESULT and BENCH_CAPTURE_STATS
#   - the log must contain no engine, script, shader or resource errors
#   - the captured frame must have real contrast (not blank or uniform)
#   - the JSON is written to a temporary path and moved into place only on success,
#     so a reused TAG can never leave a stale file looking like a fresh result
#   - an existing override.cfg is backed up and restored
#   - the full engine log is kept in artifacts/bench/logs/<tag>.log
#
#   SCENE=forest CAMERA=static GI=on RATIO=0.10 ./bench_run.sh
#
# Variables:
#   SCENE   empty | room | forest      (default forest)
#   CAMERA  static | move | teleport   (default static)
#   GI      on | off                   (default on)
#   RATIO   solid_cell_ratio           (default: leave project value)
#   TREES   forest tree count          (default 600)
#   FRAMES  measured frames            (default 300)
#   WARMUP  discarded frames           (default 120)
#   TAG     output label               (default derived from the above)
#   PROJECT project path               (default platform/test_project; for tests)
#   OUTDIR  output directory           (default artifacts/bench; for tests)
#   HDDAGI_BIN engine binary           (default the build tree; set to the packaged app)
#   TIMEOUT seconds                    (default 300; hard kill, exit 124)
#   COLD    1 moves the Godot shader cache aside first (cold = cache absent;
#           the moved cache is kept as shader_cache.bak-cold-<tag>-<time>)
#   CACHE_STATE recorded in the JSON   (cold|warm|unknown; default unknown,
#           forced to cold by COLD=1)
#   REP / MATRIX_CELL                  repeat index / cell name recorded in JSON
#   BENCH_* feature toggles are passed through to the harness (see bench.gd)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(dirname "$HERE")"
BUILD_ROOT="$(dirname "$WORKSPACE")/hddagi-build"
BIN="${HDDAGI_BIN:-$BUILD_ROOT/godot-dynamic_gi_2/bin/godot.macos.editor.dev.arm64}"
PROJECT="${PROJECT:-$WORKSPACE/platform/test_project}"
OUTDIR="${OUTDIR:-$WORKSPACE/artifacts/bench}"
LOG_DIR="$OUTDIR/logs"

SCENE="${SCENE:-forest}"
CAMERA="${CAMERA:-static}"
GI="${GI:-on}"
RATIO="${RATIO:-}"
TREES="${TREES:-600}"
FRAMES="${FRAMES:-300}"
WARMUP="${WARMUP:-120}"
CASCADES="${CASCADES:-6}"
REBUILD="${REBUILD:-}"
TIMEOUT="${TIMEOUT:-300}"
COLD="${COLD:-0}"
CACHE_STATE="${CACHE_STATE:-unknown}"

[ -x "$BIN" ] || { echo "binary not found: $BIN" >&2; exit 1; }
[ -d "$PROJECT" ] || { echo "project not found: $PROJECT" >&2; exit 1; }
mkdir -p "$OUTDIR" "$LOG_DIR"

if [ -z "$RATIO" ]; then
	TAG="${TAG:-${SCENE}_${CAMERA}_gi${GI}_t${TREES}}"
else
	TAG="${TAG:-${SCENE}_${CAMERA}_gi${GI}_r${RATIO}_t${TREES}}"
fi

OUT="$OUTDIR/$TAG.json"
LOG="$LOG_DIR/$TAG.log"
FRESH="$LOG_DIR/$TAG.fresh.json"
OVERRIDE="$PROJECT/override.cfg"
TIMEFILE="$(mktemp -t hddagi_bench_time)"
OVERRIDE_BACKUP=""

if [ -e "$OVERRIDE" ]; then
	OVERRIDE_BACKUP="$(mktemp -t hddagi_override)"
	cp -p "$OVERRIDE" "$OVERRIDE_BACKUP"
	echo "preserving existing $OVERRIDE (restored on exit)"
fi

cleanup() {
	rm -f "$OVERRIDE" "$TIMEFILE" "$FRESH"
	if [ -n "$OVERRIDE_BACKUP" ] && [ -f "$OVERRIDE_BACKUP" ]; then
		mv "$OVERRIDE_BACKUP" "$OVERRIDE"
	fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
	echo "FAILED $TAG: $*" >&2
	echo "log $LOG" >&2
	if [ -f "$OUT" ]; then
		echo "kept previous $OUT unchanged" >&2
	fi
	tail -30 "$LOG" >&2 || true
	exit 1
}

{
	echo '[rendering]'
	echo 'global_illumination/hddagi/sparse_selftest=false'
	if [ -n "$RATIO" ]; then
		echo "global_illumination/hddagi/solid_cell_ratio=$RATIO"
	fi
	if [ -n "$REBUILD" ]; then
		echo "global_illumination/hddagi/full_rebuild_budget=$REBUILD"
	fi
	# Raw project-setting overrides, one "key=value" per line in EXTRA (newline separated).
	if [ -n "${EXTRA:-}" ]; then
		printf '%s\n' "$EXTRA"
	fi
} > "$OVERRIDE"
OVERRIDE_SHA=$(shasum -a 256 "$OVERRIDE" | awk '{print $1}')

# Cold means the Godot shader/pipeline cache is absent. It is moved aside, never
# deleted; the OS page cache and any driver-level Metal caches are not
# controlled, so "cold" must not be read as "all caches cold".
if [ "$COLD" != "0" ]; then
	PNAME=$(grep -m1 '^config/name=' "$PROJECT/project.godot" | cut -d'"' -f2 || true)
	CDIR="$HOME/Library/Application Support/Godot/app_userdata/$PNAME/shader_cache"
	if [ -n "$PNAME" ] && [ -d "$CDIR" ]; then
		CDEST="$CDIR.bak-cold-${TAG}-$(date +%H%M%S)"
		mv "$CDIR" "$CDEST"
		echo "cold: moved $CDIR to $CDEST" >&2
	else
		echo "cold: no shader cache to move at $CDIR" >&2
	fi
	CACHE_STATE="cold"
fi

rm -f "$FRESH"
set +e
python3 "$WORKSPACE/tools/run_timed.py" --timeout "$TIMEOUT" --log "$LOG" --stats "$TIMEFILE" -- \
	env \
	BENCH_SCENE="$SCENE" \
	BENCH_CAMERA="$CAMERA" \
	BENCH_GI="$GI" \
	BENCH_TAG="$TAG" \
	BENCH_OUT="$FRESH" \
	BENCH_FRAMES="$FRAMES" \
	BENCH_WARMUP="$WARMUP" \
	BENCH_CASCADES="$CASCADES" \
	BENCH_CUT_FRAME="${BENCH_CUT_FRAME:-10}" \
	BENCH_SNAP="${BENCH_SNAP:-}" \
	BENCH_SNAP_DIR="${BENCH_SNAP_DIR:-/tmp/hddagi_snap}" \
	BENCH_SHADOWS="${BENCH_SHADOWS:-}" \
	BENCH_TREE_SHADOW="${BENCH_TREE_SHADOW:-}" \
	BENCH_GRASS_SHADOW="${BENCH_GRASS_SHADOW:-}" \
	BENCH_LOD="${BENCH_LOD:-}" \
	BENCH_LOD_NEAR="${BENCH_LOD_NEAR:-}" \
	BENCH_LOD_MID="${BENCH_LOD_MID:-}" \
	BENCH_LOD_CAMERA="${BENCH_LOD_CAMERA:-}" \
	BENCH_SHADOW_LOD="${BENCH_SHADOW_LOD:-}" \
	BENCH_TREE_LOD="${BENCH_TREE_LOD:-}" \
	BENCH_SHADOW_DISTANCE="${BENCH_SHADOW_DISTANCE:-}" \
	BENCH_FOG="${BENCH_FOG:-}" \
	BENCH_VOLFOG="${BENCH_VOLFOG:-}" \
	BENCH_SSAO="${BENCH_SSAO:-}" \
	BENCH_GLOW="${BENCH_GLOW:-}" \
	BENCH_MSAA="${BENCH_MSAA:-}" \
	BENCH_WIDTH="${BENCH_WIDTH:-}" \
	BENCH_HEIGHT="${BENCH_HEIGHT:-}" \
	BENCH_TELEPORT_PERIOD="${BENCH_TELEPORT_PERIOD:-}" \
	BENCH_CACHE_STATE="$CACHE_STATE" \
	HDDAGI_HUD="${HUD:-0}" \
	HDDAGI_WIND="${WIND:-0}" \
	HDDAGI_MENU=0 \
	HDDAGI_TREES="$TREES" \
	"$BIN" --path "$PROJECT" res://bench.tscn
STATUS=$?
set -e

if [ "$STATUS" -eq 124 ]; then
	fail "engine timed out after ${TIMEOUT}s"
fi
[ "$STATUS" -eq 0 ] || fail "engine exited $STATUS"

# `|| true` matters: with pipefail a grep that finds nothing would abort the script
# under set -e before it can report the failure.
RESULT=$(grep -E "BENCH_RESULT" "$LOG" | head -1 || true)
[ -n "$RESULT" ] || fail "no BENCH_RESULT line"
grep -q "BENCH_CAPTURE_STATS" "$LOG" || fail "no BENCH_CAPTURE_STATS line"

# Engine, script, shader and resource errors make the timings meaningless: a scene
# that failed to load is fast. This is checked before anything is accepted.
ERRORS=$(grep -nE "SCRIPT ERROR:|SHADER ERROR:|ERROR:|Failed loading resource:|Failed to load|Can't open file|Failed to compile" "$LOG" | head -10 || true)
[ -z "$ERRORS" ] || fail "log contains errors: $(echo "$ERRORS" | head -1)"

# The captured frame must have real contrast; a blank or uniform frame means the
# render path failed even if the engine exited 0.
python3 "$WORKSPACE/tools/capture_check.py" --log "$LOG" --marker "BENCH_CAPTURE_STATS" --kind normal \
	|| fail "capture check failed"

[ -s "$FRESH" ] || fail "no JSON written to $FRESH"

# Validate the fresh file before it is allowed to replace anything: the tag must
# match, the frame count must be the requested one, and the samples must be real.
python3 - "$FRESH" "$TAG" "$FRAMES" <<'PY' || fail "fresh JSON failed validation"
import json, sys
path, tag, frames = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(path) as f:
    d = json.load(f)
assert d.get("tag") == tag, f"tag {d.get('tag')!r} != {tag!r}"
assert d.get("measured_frames") == frames, f"frames {d.get('measured_frames')} != {frames}"
raw = d.get("raw_frame_ms") or []
assert len(raw) == frames, f"raw samples {len(raw)} != {frames}"
assert d["frame_ms"]["p50"] > 0, "p50 is zero"
PY

PEAK_RSS=$(python3 -c "import json;print(json.load(open('$TIMEFILE'))['max_rss_bytes'])" 2>/dev/null || true)
ELAPSED=$(python3 -c "import json;print(json.load(open('$TIMEFILE'))['elapsed_s'])" 2>/dev/null || true)
BUDGET=$(grep -E "HDDAGI_PROCESS_BUDGET" "$LOG" | head -1 || true)
REBUILD_LOG=$(grep -E "HDDAGI_REBUILD_BUDGET" "$LOG" | head -1 || true)
BIN_SHA=$(shasum -a 256 "$BIN" | awk '{print $1}' || true)

# Fold the externally measured values into the JSON so one file holds the row:
# peak RSS, the engine budget lines, binary identity, project identity, the
# override that was in force, cache state and repeat bookkeeping.
#
# project_manifest_sha256 excludes .godot/ and the temporary override.cfg so it
# is the base-project hash and equals the package manifest when the bundled
# project matches the source (same canonicalization as platform/verify_app.py).
# The override that was in force is recorded separately, hashed, in
# override_cfg_sha256/override_cfg.
python3 - "$FRESH" "$PEAK_RSS" "$ELAPSED" "$BUDGET" "$REBUILD_LOG" "$BIN_SHA" "$LOG" \
	"$OVERRIDE_SHA" "$OVERRIDE" "$CACHE_STATE" "${MATRIX_CELL:-}" "${REP:-}" "$PROJECT" "$WORKSPACE" <<'PY'
import datetime
import json
import sys
from pathlib import Path

(path, rss, elapsed, budget, rebuild, sha, log, osha, opath, cache_state,
 cell, rep, project, workspace) = sys.argv[1:15]

sys.path.insert(0, str(Path(workspace) / "platform"))
from verify_app import manifest_digest, tree_manifest  # noqa: E402

with open(path) as f:
    d = json.load(f)
if rss:
    # Whole-process peak: startup, warmup, measurement AND the final capture
    # readback are all inside it. It is not a steady-state sample; the
    # steady-state engine number is static_mb_p50, sampled per measured frame.
    d["peak_rss_mb"] = float(rss) / 1048576.0
    d["peak_rss_scope"] = "whole process incl. startup, warmup and readback"
if elapsed:
    d["elapsed_s"] = float(elapsed)
d["process_budget_log"] = budget
d["rebuild_budget_log"] = rebuild
d["binary_sha256"] = sha
d["run_log"] = log
d["project_manifest_sha256"] = manifest_digest(
    tree_manifest(Path(project), exclude=(".godot", "override.cfg")))
d["project_manifest_scope"] = "source project excluding .godot/ and override.cfg"
d["override_cfg_sha256"] = osha
d["override_cfg"] = [ln for ln in Path(opath).read_text().splitlines()
                     if ln.strip() and not ln.strip().startswith("#")]
d["cache_state"] = cache_state
if cell:
    d["matrix_cell"] = cell
if rep != "":
    d["rep"] = int(rep)
d["runner_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
with open(path, "w") as f:
    json.dump(d, f, indent=2)
PY

# Only now is the result allowed to replace a previous file of the same tag.
mv "$FRESH" "$OUT"

echo "$RESULT"
if [ -n "$PEAK_RSS" ]; then
	echo "PEAK_RSS_MB=$(awk -v bytes="$PEAK_RSS" 'BEGIN { printf "%.1f", bytes / 1048576 }')"
else
	echo "PEAK_RSS_MB=unknown"
fi
echo "BUDGET=$BUDGET"
echo "REBUILD=$REBUILD_LOG"
echo "SHA256=$BIN_SHA"
echo "LOG=$LOG"
echo "JSON=$OUT"
