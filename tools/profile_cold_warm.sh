#!/usr/bin/env bash
# Runs the packaged 1,500-tree configuration cold and warm.
#
#   ./tools/profile_cold_warm.sh                    # static, teleport, cut
#   CONFIGS="static" ./tools/profile_cold_warm.sh
#   TREES=600 ./tools/profile_cold_warm.sh
#
# "Cold" means the Godot shader/pipeline cache is moved aside before the run, so
# first-use pipeline compilation is paid inside the measurement. "Warm" is the
# same configuration immediately after, with the cache the cold run produced.
#
# The cache is moved, never deleted: it is kept as shader_cache.bak-<stamp>-<cfg>.
# The OS page cache is not dropped (that needs privileges), so this isolates
# pipeline compilation, not file I/O.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(dirname "$HERE")"
BUNDLE="${BUNDLE:-$(dirname "$WORKSPACE")/hddagi-run/HDDAGI.app}"
BIN="${HDDAGI_BIN:-$BUNDLE/Contents/MacOS/godot}"
PROJECT="${PROJECT:-$BUNDLE/Contents/Resources/project}"
TREES="${TREES:-1500}"
FRAMES="${FRAMES:-300}"
WARMUP="${WARMUP:-120}"
CONFIGS="${CONFIGS:-static teleport cut}"

[ -x "$BIN" ] || { echo "engine binary not found: $BIN" >&2; exit 1; }
[ -d "$PROJECT" ] || { echo "project not found: $PROJECT" >&2; exit 1; }

PROJECT_NAME=$(grep -m1 '^config/name=' "$PROJECT/project.godot" | cut -d'"' -f2)
CACHE="$HOME/Library/Application Support/Godot/app_userdata/$PROJECT_NAME/shader_cache"
STAMP=$(date +%Y%m%d-%H%M%S)

echo "project=$PROJECT_NAME trees=$TREES cache=$CACHE"

for cfg in $CONFIGS; do
	case "$cfg" in
		cut) f=60; w=60 ;;
		*) f="$FRAMES"; w="$WARMUP" ;;
	esac

	if [ -d "$CACHE" ]; then
		mv "$CACHE" "$CACHE.bak-$STAMP-$cfg"
		echo "cold: moved the shader cache aside for $cfg"
	fi

	for phase in cold warm; do
		tag="${phase}_${cfg}_t${TREES}"
		echo "=== $tag ==="
		HDDAGI_BIN="$BIN" PROJECT="$PROJECT" TAG="$tag" SCENE=forest CAMERA="$cfg" \
			GI=on TREES="$TREES" FRAMES="$f" WARMUP="$w" \
			"$WORKSPACE/tools/bench_run.sh"
	done
done
