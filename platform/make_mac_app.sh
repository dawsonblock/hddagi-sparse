#!/usr/bin/env bash
# Builds a double-clickable HDDAGI.app from the macOS build.
#
#   ./make_mac_app.sh              build, validate, then swap the bundle in
#   ./make_mac_app.sh --open       the same, then launch it
#   ./make_mac_app.sh --skip-rendered   skip the rendered Metal smoke check
#   ./make_mac_app.sh --trees 600  tree count for the rendered smoke (default 1500)
#
# The bundle is assembled in a staging directory and validated there. Only after
# every check passes does it replace the live bundle, and the previous bundle is
# kept as HDDAGI.app.bak-<timestamp> rather than deleted. Nothing in the source
# project is modified: the import cache is generated inside the staging copy.
#
# The import step is not allowed to fail silently. Its full output is kept in
# artifacts/app_build/<timestamp>/import.log and an ERROR in it fails the build.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(dirname "$HERE")"
BUILD_TREE="$(dirname "$WORKSPACE")/hddagi-build/godot-dynamic_gi_2"
# Overridable for failure-injection tests; the defaults are the real locations.
BIN="${HDDAGI_BIN:-$BUILD_TREE/bin/godot.macos.editor.dev.arm64}"
SRC="${HDDAGI_SOURCE:-$HERE/test_project}"
RUN_ROOT="${HDDAGI_RUN_ROOT:-$(dirname "$WORKSPACE")/hddagi-run}"
OUT="$RUN_ROOT/HDDAGI.app"

STAMP="$(date +%Y%m%d-%H%M%S)"
STAGE="$RUN_ROOT/HDDAGI.app.staging.$$"
LOG_DIR="$WORKSPACE/artifacts/app_build/$STAMP"
TREES=1500
SKIP_RENDERED=0

while [ $# -gt 0 ]; do
	case "$1" in
		--open) OPEN=1 ;;
		--skip-rendered) SKIP_RENDERED=1 ;;
		--trees) TREES="$2"; shift ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
	shift
done

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

if [ ! -x "$BIN" ]; then
	echo "engine binary not found: $BIN" >&2
	echo "run platform/build_and_run.sh first" >&2
	exit 1
fi

mkdir -p "$LOG_DIR"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources/project"

echo "staging $STAGE"
cp "$BIN" "$STAGE/Contents/MacOS/godot"
rsync -a --exclude '.godot' "$SRC/" "$STAGE/Contents/Resources/project/"

# Generate the import cache inside the staging copy. Without it the tree textures
# fail to load and the forest renders untextured; the cache is deliberately not
# committed. A failure here is fatal, and the log is kept either way.
if ! "$STAGE/Contents/MacOS/godot" --headless \
		--path "$STAGE/Contents/Resources/project" --import > "$LOG_DIR/import.log" 2>&1; then
	echo "import failed; see $LOG_DIR/import.log" >&2
	exit 1
fi
if grep -qE "ERROR:|SCRIPT ERROR:" "$LOG_DIR/import.log"; then
	echo "import logged errors; see $LOG_DIR/import.log" >&2
	grep -E "ERROR:|SCRIPT ERROR:" "$LOG_DIR/import.log" >&2 | head -20
	exit 1
fi

cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>HDDAGI</string>
	<key>CFBundleDisplayName</key><string>HDDAGI</string>
	<key>CFBundleIdentifier</key><string>dev.hddagi.smoke</string>
	<key>CFBundleVersion</key><string>1.0</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleExecutable</key><string>launch</string>
	<key>LSMinimumSystemVersion</key><string>11.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cat > "$STAGE/Contents/MacOS/launch" <<'LAUNCH'
#!/bin/sh
DIR="$(cd "$(dirname "$0")" && pwd)"
: "${HDDAGI_TREES:=1500}"
: "${HDDAGI_CAPTURE:=0}"
export HDDAGI_TREES
export HDDAGI_CAPTURE
exec "$DIR/godot" --path "$DIR/../Resources/project" "$@"
LAUNCH

chmod +x "$STAGE/Contents/MacOS/launch" "$STAGE/Contents/MacOS/godot"

echo "validating staged bundle"
VERIFY_ARGS=(
	--app "$STAGE"
	--app-label "$OUT"
	--source "$SRC"
	--binary "$BIN"
	--json "$LOG_DIR/manifest.json"
	--markdown "$LOG_DIR/report.md"
	--log-dir "$LOG_DIR"
	--trees "$TREES"
)
if [ "$SKIP_RENDERED" = "1" ]; then
	VERIFY_ARGS+=(--skip-rendered)
fi
python3 "$HERE/verify_app.py" "${VERIFY_ARGS[@]}"

# Validation passed. Preserve the previous bundle, then swap the staged one in.
if [ -e "$OUT" ]; then
	BACKUP="$OUT.bak-$STAMP"
	mv "$OUT" "$BACKUP"
	echo "kept previous bundle at $BACKUP"
fi
mv "$STAGE" "$OUT"
trap - EXIT
echo "built $OUT"

# The staged path appears in the logs; rewrite the manifest to the final path so
# the recorded provenance points at the bundle that is actually installed.
python3 - "$LOG_DIR/manifest.json" "$OUT" <<'PY'
import json, sys
path, final = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
d["app"] = final
d["staged_path"] = d.get("staged_path") or d.get("app")
with open(path, "w") as f:
    json.dump(d, f, indent=2)
PY

echo "manifest $LOG_DIR/manifest.json"
echo "report   $LOG_DIR/report.md"
echo "$STAMP" > "$WORKSPACE/artifacts/app_build/LATEST"
echo "binary   $(shasum -a 256 "$OUT/Contents/MacOS/godot" | awk '{print $1}')"

if [ "${OPEN:-0}" = "1" ]; then
	open "$OUT"
	echo "launched"
fi
