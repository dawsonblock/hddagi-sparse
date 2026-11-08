#!/usr/bin/env bash
# Regenerates platform/engine_changes.patch from the supplied tree and the build tree.
#
#   ./platform/gen_engine_patch.sh
#
# The patch is the record of every engine change. New files are diffed against
# /dev/null and headed with the supplied-tree path so `patch -p1` creates them in
# the right directory; modified files keep the build-tree path on the +++ side.
#
# platform/check_engine_copies.sh verifies that the result applies and reproduces
# the build tree byte for byte.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(dirname "$HERE")"
ROOT="$(dirname "$WORKSPACE")"
SRC="$ROOT/godot-dynamic_gi_2"
BUILD="$ROOT/hddagi-build/godot-dynamic_gi_2"
OUT="$WORKSPACE/platform/engine_changes.patch"

ENV_DIR="servers/rendering/renderer_rd/environment"
MODIFIED="$ENV_DIR/gi.cpp $ENV_DIR/gi.h servers/rendering/rendering_server.cpp"
NEW="$ENV_DIR/hddagi_sparse_plan.h $ENV_DIR/hddagi_sparse_plan.cpp \
	$ENV_DIR/hddagi_sparse_selftest.h $ENV_DIR/hddagi_sparse_selftest.cpp \
	$ENV_DIR/hddagi_sparse_shaders.inc"

[ -d "$SRC" ] || { echo "supplied tree not found: $SRC" >&2; exit 1; }
[ -d "$BUILD" ] || { echo "build tree not found: $BUILD" >&2; exit 1; }

{
	for f in $MODIFIED; do
		diff -u --label "godot-dynamic_gi_2/$f" \
			--label "hddagi-build/godot-dynamic_gi_2/$f" \
			"$SRC/$f" "$BUILD/$f" || true
	done
	for f in $NEW; do
		diff -u --label "/dev/null" --label "godot-dynamic_gi_2/$f" \
			/dev/null "$BUILD/$f" || true
	done
} > "$OUT"

echo "wrote $OUT ($(wc -l < "$OUT") lines)"
