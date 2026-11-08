#!/usr/bin/env bash
# Failure-injection regressions for the benchmark runner and app packaging.
#
# Every case runs against a temporary copy of the project or bundle. The real
# project, the real bundle and the real artifacts are never modified, and the
# temporary directory is removed on exit.
#
#   ./tools/test_failure_modes.sh
#
# What is covered:
#   benchmark  clean run, missing tree mesh, missing texture asset, broken script,
#              engine nonzero exit, stale JSON for a reused tag, pre-existing
#              override.cfg, flat/white capture rejection
#   packaging  import failure preserves the previous bundle, binary mismatch,
#              missing embedded file, unexpected extra file, missing import dest
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(dirname "$HERE")"
ROOT="$(dirname "$WORKSPACE")"
BIN="$ROOT/hddagi-build/godot-dynamic_gi_2/bin/godot.macos.editor.dev.arm64"
APP="$ROOT/hddagi-run/HDDAGI.app"
BENCH="$WORKSPACE/tools/bench_run.sh"
VERIFY="$WORKSPACE/platform/verify_app.py"
CAPCHECK="$WORKSPACE/tools/capture_check.py"
SRC_PROJECT="$WORKSPACE/platform/test_project"

TMP="$(mktemp -d -t hddagi_failtest)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { echo "PASS  $*"; pass=$((pass + 1)); }
no() { echo "FAIL  $*"; fail=$((fail + 1)); }

expect_ok() {
	local name="$1"; shift
	local out="$TMP/$name.out"
	if "$@" > "$out" 2>&1; then ok "$name"; else no "$name"; tail -12 "$out"; fi
}

expect_fail() {
	local name="$1"; local needle="$2"; shift 2
	local out="$TMP/$name.out"
	if "$@" > "$out" 2>&1; then
		no "$name (unexpected success)"
		return
	fi
	if [ -n "$needle" ] && ! grep -q "$needle" "$out"; then
		no "$name (failed, but output lacks '$needle')"
		tail -12 "$out"
		return
	fi
	ok "$name"
}

[ -x "$BIN" ] || { echo "engine binary missing: $BIN" >&2; exit 1; }
[ -d "$APP" ] || { echo "app bundle missing: $APP" >&2; exit 1; }

PROJ="$TMP/project"
rsync -a --exclude '.godot' "$SRC_PROJECT/" "$PROJ/"
if ! "$BIN" --headless --path "$PROJ" --import > "$TMP/import.log" 2>&1; then
	echo "could not prepare the temporary project; see $TMP/import.log" >&2
	exit 1
fi
OUTDIR="$TMP/out"
mkdir -p "$OUTDIR"

bench() {
	# Arguments are env assignments for the runner, e.g. `bench TAG=clean`.
	env PROJECT="$PROJ" OUTDIR="$OUTDIR" SCENE=forest TREES=20 FRAMES=8 WARMUP=8 RATIO=0.10 \
		"$@" "$BENCH"
}

# ---------------------------------------------------------------------------
# Benchmark: clean run is the control
# ---------------------------------------------------------------------------
expect_ok bench_clean bench TAG=clean
[ -f "$OUTDIR/clean.json" ] && ok "bench_clean writes JSON" || no "bench_clean writes JSON"
[ -f "$OUTDIR/logs/clean.log" ] && ok "bench_clean keeps the engine log" || no "bench_clean keeps the engine log"

# ---------------------------------------------------------------------------
# Benchmark: missing tree mesh must fail, not benchmark an empty forest
# ---------------------------------------------------------------------------
OAK="$PROJ/demo/foliage/models/oak_lod0.res"
cp "$OAK" "$TMP/oak.bak"
rm "$OAK"
expect_fail bench_missing_mesh "FAILED" bench TAG=missing_mesh
[ ! -f "$OUTDIR/missing_mesh.json" ] && ok "no JSON for a missing mesh" || no "no JSON for a missing mesh"
grep -q "BENCH_FAILED reason=tree mesh failed to load" "$OUTDIR/logs/missing_mesh.log" \
	&& ok "missing mesh reports the exact asset" || no "missing mesh reports the exact asset"
cp "$TMP/oak.bak" "$OAK"

# ---------------------------------------------------------------------------
# Benchmark: missing texture asset must fail
# ---------------------------------------------------------------------------
GRASS="$PROJ/demo/foliage/textures/grass_albedo.png"
GRASS_IMPORT="$PROJ/demo/foliage/textures/grass_albedo.png.import"
cp "$GRASS" "$TMP/grass.bak"
cp "$GRASS_IMPORT" "$TMP/grass_import.bak"
rm "$GRASS" "$GRASS_IMPORT"
expect_fail bench_missing_texture "FAILED" bench TAG=missing_texture
[ ! -f "$OUTDIR/missing_texture.json" ] && ok "no JSON for a missing texture" || no "no JSON for a missing texture"
cp "$TMP/grass.bak" "$GRASS"
cp "$TMP/grass_import.bak" "$GRASS_IMPORT"

# ---------------------------------------------------------------------------
# Benchmark: a script error must fail even if the engine keeps running
# ---------------------------------------------------------------------------
cp "$PROJ/bench.gd" "$TMP/bench.gd.bak"
printf '\nfunc broken(\n' >> "$PROJ/bench.gd"
expect_fail bench_script_error "FAILED" bench TAG=script_error
grep -qE "SCRIPT ERROR:|Parse Error" "$OUTDIR/logs/script_error.log" \
	&& ok "script error is visible in the log" || no "script error is visible in the log"
cp "$TMP/bench.gd.bak" "$PROJ/bench.gd"

# ---------------------------------------------------------------------------
# Benchmark: engine nonzero exit must fail
# ---------------------------------------------------------------------------
mv "$PROJ/bench.tscn" "$PROJ/bench.tscn.off"
expect_fail bench_nonzero_exit "FAILED" bench TAG=nonzero_exit
[ ! -f "$OUTDIR/nonzero_exit.json" ] && ok "no JSON after a failed engine start" || no "no JSON after a failed engine start"
mv "$PROJ/bench.tscn.off" "$PROJ/bench.tscn"

# ---------------------------------------------------------------------------
# Benchmark: a hung engine times out without publishing a result
# ---------------------------------------------------------------------------
FAKE_SLEEP="$TMP/fake_sleep"
printf '#!/bin/sh\nsleep 60\n' > "$FAKE_SLEEP"
chmod +x "$FAKE_SLEEP"
printf '{"prior": true}\n' > "$OUTDIR/hung.json"
printf '[rendering]\n# keep me\nsome/setting=1\n' > "$PROJ/override.cfg"
HUNG_BEFORE=$(shasum -a 256 "$PROJ/override.cfg" | awk '{print $1}')
expect_fail bench_timeout "timed out" \
	env PROJECT="$PROJ" OUTDIR="$OUTDIR" TAG=hung TIMEOUT=2 HDDAGI_BIN="$FAKE_SLEEP" \
	SCENE=forest TREES=20 FRAMES=8 WARMUP=8 RATIO=0.10 "$BENCH"
python3 - "$OUTDIR/hung.json" <<'PY' && ok "timeout leaves the prior JSON untouched" || no "timeout leaves the prior JSON untouched"
import json, sys
assert json.load(open(sys.argv[1])) == {"prior": True}
PY
HUNG_AFTER=$(shasum -a 256 "$PROJ/override.cfg" | awk '{print $1}')
[ "$HUNG_BEFORE" = "$HUNG_AFTER" ] && ok "timeout restores override.cfg" || no "timeout restores override.cfg"
rm -f "$PROJ/override.cfg"

# ---------------------------------------------------------------------------
# Benchmark: a reused tag must not resurrect a stale JSON
# ---------------------------------------------------------------------------
printf '{"stale": true}\n' > "$OUTDIR/stale.json"
rm "$OAK"
expect_fail bench_stale_not_replaced "FAILED" bench TAG=stale
python3 - "$OUTDIR/stale.json" <<'PY' && ok "failed run leaves the stale JSON untouched" || no "failed run leaves the stale JSON untouched"
import json, sys
assert json.load(open(sys.argv[1])) == {"stale": True}
PY
cp "$TMP/oak.bak" "$OAK"
expect_ok bench_stale_replaced bench TAG=stale
python3 - "$OUTDIR/stale.json" <<'PY' && ok "successful run replaces the stale JSON" || no "successful run replaces the stale JSON"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["tag"] == "stale" and "frame_ms" in d
PY

# ---------------------------------------------------------------------------
# Benchmark: a pre-existing override.cfg is restored byte for byte
# ---------------------------------------------------------------------------
printf '[rendering]\n# user override\nsome/setting=1\n' > "$PROJ/override.cfg"
BEFORE=$(shasum -a 256 "$PROJ/override.cfg" | awk '{print $1}')
expect_ok bench_override_restored bench TAG=override
AFTER=$(shasum -a 256 "$PROJ/override.cfg" | awk '{print $1}')
[ "$BEFORE" = "$AFTER" ] && ok "pre-existing override.cfg is preserved" || no "pre-existing override.cfg is preserved"

# ---------------------------------------------------------------------------
# Capture check: uniform bright frames are rejected, rendered frames accepted
# ---------------------------------------------------------------------------
printf 'BENCH_CAPTURE_STATS {"min":255,"max":255,"mean":255,"range":0}\n' > "$TMP/white.log"
expect_fail capture_rejects_white "flat image" python3 "$CAPCHECK" --log "$TMP/white.log" --marker BENCH_CAPTURE_STATS
printf 'BENCH_CAPTURE_STATS {"min":20,"max":223,"mean":110.5,"range":203}\n' > "$TMP/good.log"
expect_ok capture_accepts_rendered python3 "$CAPCHECK" --log "$TMP/good.log" --marker BENCH_CAPTURE_STATS

# ---------------------------------------------------------------------------
# Packaging: import failure leaves the previous bundle untouched
# ---------------------------------------------------------------------------
FAKE="$TMP/fake_engine"
printf '#!/bin/sh\nexit 1\n' > "$FAKE"
chmod +x "$FAKE"
mkdir -p "$TMP/run/HDDAGI.app/Contents/MacOS"
printf 'sentinel\n' > "$TMP/run/HDDAGI.app/Contents/MacOS/sentinel"
BUNDLE_BEFORE=$(find "$TMP/run/HDDAGI.app" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256)
expect_fail package_import_failure "import failed" \
	env HDDAGI_BIN="$FAKE" HDDAGI_SOURCE="$PROJ" HDDAGI_RUN_ROOT="$TMP/run" \
	"$WORKSPACE/platform/make_mac_app.sh" --skip-rendered
BUNDLE_AFTER=$(find "$TMP/run/HDDAGI.app" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256)
[ "$BUNDLE_BEFORE" = "$BUNDLE_AFTER" ] && ok "failed package preserves the previous bundle" || no "failed package preserves the previous bundle"

# ---------------------------------------------------------------------------
# Packaging: verifier catches binary mismatch and project drift
# ---------------------------------------------------------------------------
expect_fail verify_binary_mismatch "engine binary matches" \
	python3 "$VERIFY" --app "$APP" --binary /bin/ls --skip-rendered --log-dir "$TMP/v1"

APP2="$TMP/app_test"
cp -cR "$APP" "$APP2" 2>/dev/null || cp -R "$APP" "$APP2"

mv "$APP2/Contents/Resources/project/main.gd" "$TMP/main.gd.bak"
expect_fail verify_missing_file "no source file missing" \
	python3 "$VERIFY" --app "$APP2" --skip-rendered --log-dir "$TMP/v2"
mv "$TMP/main.gd.bak" "$APP2/Contents/Resources/project/main.gd"

printf 'stray\n' > "$APP2/Contents/Resources/project/stray.txt"
expect_fail verify_extra_file "extras are only" \
	python3 "$VERIFY" --app "$APP2" --skip-rendered --log-dir "$TMP/v3"
rm "$APP2/Contents/Resources/project/stray.txt"

IMPORT_FILE="$APP2/Contents/Resources/project/demo/foliage/textures/grass_albedo.png.import"
DEST=$(grep -o 'res://[^"]*grass_albedo[^"]*' "$IMPORT_FILE" | head -1 | sed 's|res://||')
DEST_PATH="$APP2/Contents/Resources/project/$DEST"
cp "$DEST_PATH" "$TMP/ctex.bak"
rm "$DEST_PATH"
expect_fail verify_missing_import "dest_file exists" \
	python3 "$VERIFY" --app "$APP2" --skip-rendered --log-dir "$TMP/v4"
cp "$TMP/ctex.bak" "$DEST_PATH"

# ---------------------------------------------------------------------------
echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
