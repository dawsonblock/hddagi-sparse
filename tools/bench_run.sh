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
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(dirname "$HERE")"
BUILD_ROOT="$(dirname "$WORKSPACE")/hddagi-build"
BIN="$BUILD_ROOT/godot-dynamic_gi_2/bin/godot.macos.editor.dev.arm64"
PROJECT="$WORKSPACE/platform/test_project"
OUTDIR="$WORKSPACE/artifacts/bench"

SCENE="${SCENE:-forest}"
CAMERA="${CAMERA:-static}"
GI="${GI:-on}"
RATIO="${RATIO:-}"
TREES="${TREES:-600}"
FRAMES="${FRAMES:-300}"
WARMUP="${WARMUP:-120}"
CASCADES="${CASCADES:-6}"
REBUILD="${REBUILD:-}"

[ -x "$BIN" ] || { echo "binary not found: $BIN" >&2; exit 1; }
[ -d "$PROJECT" ] || { echo "project not found: $PROJECT" >&2; exit 1; }
mkdir -p "$OUTDIR"

if [ -z "$RATIO" ]; then
	TAG="${TAG:-${SCENE}_${CAMERA}_gi${GI}_t${TREES}}"
else
	TAG="${TAG:-${SCENE}_${CAMERA}_gi${GI}_r${RATIO}_t${TREES}}"
fi

OUT="$OUTDIR/$TAG.json"
OVERRIDE="$PROJECT/override.cfg"
TIMEFILE="$(mktemp -t hddagi_bench_time)"

cleanup() { rm -f "$OVERRIDE" "$TIMEFILE" "$TIMEFILE.log"; }
trap cleanup EXIT

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

set +e
/usr/bin/time -l env \
	BENCH_SCENE="$SCENE" \
	BENCH_CAMERA="$CAMERA" \
	BENCH_GI="$GI" \
	BENCH_TAG="$TAG" \
	BENCH_OUT="$OUT" \
	BENCH_FRAMES="$FRAMES" \
	BENCH_WARMUP="$WARMUP" \
	BENCH_CASCADES="$CASCADES" \
	BENCH_CUT_FRAME="${BENCH_CUT_FRAME:-10}" \
	BENCH_SNAP="${BENCH_SNAP:-}" \
	BENCH_SNAP_DIR="${BENCH_SNAP_DIR:-/tmp/hddagi_snap}" \
	HDDAGI_HUD="${HUD:-0}" \
	HDDAGI_WIND="${WIND:-0}" \
	HDDAGI_MENU=0 \
	HDDAGI_TREES="$TREES" \
	"$BIN" --path "$PROJECT" res://bench.tscn \
	> "$TIMEFILE.log" 2> "$TIMEFILE"
STATUS=$?
set -e

# `|| true` matters: with pipefail a grep that finds nothing would abort the script
# under set -e before it can report the failure below.
PEAK_RSS=$(grep -E "maximum resident set size" "$TIMEFILE" | awk '{print $1}' | head -1 || true)
BUDGET=$(grep -E "HDDAGI_PROCESS_BUDGET" "$TIMEFILE.log" | head -1 || true)
REBUILD_LOG=$(grep -E "HDDAGI_REBUILD_BUDGET" "$TIMEFILE.log" | head -1 || true)
RESULT=$(grep -E "BENCH_RESULT" "$TIMEFILE.log" | head -1 || true)
BIN_SHA=$(shasum -a 256 "$BIN" | awk '{print $1}' || true)

if [ -z "$RESULT" ]; then
	echo "FAILED $TAG (status $STATUS)"
	tail -20 "$TIMEFILE.log" >&2
	exit 1
fi

# Fold the externally measured values into the JSON so one file holds the row: the
# peak RSS, the two engine budget lines, and the identity of the binary that ran.
if [ -f "$OUT" ]; then
	python3 - "$OUT" "$PEAK_RSS" "$BUDGET" "$REBUILD_LOG" "$BIN_SHA" <<'PY'
import json, sys
path, rss, budget, rebuild, sha = sys.argv[1:6]
with open(path) as f:
    d = json.load(f)
if rss:
    d["peak_rss_mb"] = float(rss) / 1048576.0
d["process_budget_log"] = budget
d["rebuild_budget_log"] = rebuild
d["binary_sha256"] = sha
with open(path, "w") as f:
    json.dump(d, f, indent=2)
PY
fi

echo "$RESULT"
if [ -n "$PEAK_RSS" ]; then
	echo "PEAK_RSS_MB=$(awk -v bytes="$PEAK_RSS" 'BEGIN { printf "%.1f", bytes / 1048576 }')"
else
	echo "PEAK_RSS_MB=unknown"
fi
echo "BUDGET=$BUDGET"
echo "REBUILD=$REBUILD_LOG"
echo "SHA256=$BIN_SHA"
echo "JSON=$OUT"
