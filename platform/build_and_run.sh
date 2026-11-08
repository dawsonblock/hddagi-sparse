#!/usr/bin/env bash
# Builds the fork for macOS/Metal in a separate tree and runs the HDDAGI smoke
# project. The supplied source tree is never modified: the build happens in a
# copy, so its hash stays verifiable.
#
#   ./build_and_run.sh            build (incremental) then run 300 frames
#   ./build_and_run.sh --run-only skip the build
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(dirname "$HERE")"
SRC="$WORKSPACE/godot-dynamic_gi_2"
BUILD_ROOT="$(dirname "$WORKSPACE")/hddagi-build"
BUILD_TREE="$BUILD_ROOT/godot-dynamic_gi_2"
SCONS="${SCONS:-$HOME/Library/Python/3.9/bin/scons}"

if [ "${1:-}" != "--run-only" ]; then
	if [ ! -d "$BUILD_TREE" ]; then
		echo "copying source tree to $BUILD_TREE"
		mkdir -p "$BUILD_ROOT"
		rsync -a "$SRC/" "$BUILD_TREE/"
	fi
	echo "building"
	(cd "$BUILD_TREE" && "$SCONS" platform=macos target=editor dev_build=yes vulkan=no -j"$(sysctl -n hw.ncpu)")
fi

BIN="$BUILD_TREE/bin/godot.macos.editor.dev.arm64"
[ -x "$BIN" ] || { echo "binary not found: $BIN" >&2; exit 1; }

echo "running smoke project"
"$BIN" --path "$HERE/test_project" --quit-after 300
