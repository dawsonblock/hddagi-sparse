#!/usr/bin/env bash
# Verifies the engine changes are internally consistent.
#
# The sparse-brick self-test sources exist in three places: platform/ (the copies
# that ship with this repo), platform/engine_changes.patch (the record of the engine
# diff), and the build tree. Nothing else keeps them in step, so this script fails on
# drift instead of letting a stale copy go unnoticed.
#
# It also applies the patch to a throwaway skeleton of the supplied tree with -p1,
# which is the documented way to reproduce the engine changes. That checks the patch
# paths as well as the patch content: a new-file hunk with the wrong prefix still
# applies, but writes the file to the wrong directory.
#
#   ./tools/check_engine_copies.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(dirname "$HERE")"
ROOT="$(dirname "$WORKSPACE")"
SRC="$ROOT/godot-dynamic_gi_2"
BUILD_TREE="$ROOT/hddagi-build/godot-dynamic_gi_2"
PATCH="$WORKSPACE/platform/engine_changes.patch"
ENV_DIR="servers/rendering/renderer_rd/environment"

# Shipped in platform/ as well as created by the patch.
SELFTEST="hddagi_sparse_selftest.h hddagi_sparse_selftest.cpp hddagi_sparse_shaders.inc"
# Created by the patch only; platform/ has no copy.
PATCH_ONLY="hddagi_sparse_plan.h hddagi_sparse_plan.cpp"
# Modified by the patch; compared against the build tree.
MODIFIED="$ENV_DIR/gi.cpp $ENV_DIR/gi.h servers/rendering/rendering_server.cpp"

status=0
fail() { echo "FAIL  $*" >&2; status=1; }
ok() { echo "ok    $*"; }

# 1. platform/ copies against the build tree.
if [ -d "$BUILD_TREE" ]; then
	for f in $SELFTEST; do
		if diff -q "$WORKSPACE/platform/$f" "$BUILD_TREE/$ENV_DIR/$f" >/dev/null 2>&1; then
			ok "platform/$f matches the build tree"
		else
			fail "platform/$f differs from the build tree"
		fi
	done
else
	echo "skip  platform copies: no build tree at $BUILD_TREE"
fi

# 2. The patch applies with -p1 to the supplied tree and reproduces the result.
[ -d "$SRC" ] || { echo "FAIL  supplied tree not found: $SRC" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/$ENV_DIR" "$TMP/servers/rendering"
cp "$SRC/$ENV_DIR/gi.cpp" "$SRC/$ENV_DIR/gi.h" "$TMP/$ENV_DIR/"
cp "$SRC/servers/rendering/rendering_server.cpp" "$TMP/servers/rendering/"
(cd "$TMP" && patch -p1 -s < "$PATCH")

for f in $SELFTEST; do
	if diff -q "$WORKSPACE/platform/$f" "$TMP/$ENV_DIR/$f" >/dev/null 2>&1; then
		ok "patch creates $f"
	else
		fail "patch does not reproduce platform/$f"
	fi
done

if [ -d "$BUILD_TREE" ]; then
	for f in $PATCH_ONLY; do
		if diff -q "$BUILD_TREE/$ENV_DIR/$f" "$TMP/$ENV_DIR/$f" >/dev/null 2>&1; then
			ok "patch creates $f"
		else
			fail "patch does not reproduce $f"
		fi
	done
	for f in $MODIFIED; do
		if diff -q "$BUILD_TREE/$f" "$TMP/$f" >/dev/null 2>&1; then
			ok "patch reproduces $f"
		else
			fail "patch does not reproduce $f"
		fi
	done
else
	echo "skip  patch-only and modified files: no build tree"
fi

exit $status
