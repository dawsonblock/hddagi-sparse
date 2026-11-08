#!/usr/bin/env bash
# Builds a double-clickable HDDAGI.app from the macOS build.
#
#   ./make_mac_app.sh            build the bundle next to the build tree
#   ./make_mac_app.sh --open     build it and launch it
#
# The bundle embeds the project so it can be moved around; the launcher passes
# --path to the engine. HDDAGI_TREES and HDDAGI_CAPTURE can be overridden from
# the environment when launching from a terminal.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(dirname "$HERE")"
BUILD_TREE="$(dirname "$WORKSPACE")/hddagi-build/godot-dynamic_gi_2"
OUT="$(dirname "$WORKSPACE")/hddagi-run/HDDAGI.app"
BIN="$BUILD_TREE/bin/godot.macos.editor.dev.arm64"

if [ ! -x "$BIN" ]; then
	echo "engine binary not found: $BIN" >&2
	echo "run platform/build_and_run.sh first" >&2
	exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

cp "$BIN" "$OUT/Contents/MacOS/godot"
cp -R "$HERE/test_project" "$OUT/Contents/Resources/project"
rm -rf "$OUT/Contents/Resources/project/.godot"

cat > "$OUT/Contents/Info.plist" <<'PLIST'
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

cat > "$OUT/Contents/MacOS/launch" <<'LAUNCH'
#!/bin/sh
DIR="$(cd "$(dirname "$0")" && pwd)"
: "${HDDAGI_TREES:=1500}"
: "${HDDAGI_CAPTURE:=0}"
export HDDAGI_TREES
export HDDAGI_CAPTURE
exec "$DIR/godot" --path "$DIR/../Resources/project" "$@"
LAUNCH

chmod +x "$OUT/Contents/MacOS/launch" "$OUT/Contents/MacOS/godot"
echo "built $OUT"

if [ "${1:-}" = "--open" ]; then
	open "$OUT"
	echo "launched"
fi
