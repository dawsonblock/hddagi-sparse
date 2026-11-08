#!/usr/bin/env bash
# M2 scaffold build.
#
#   1. regenerate the binary fixtures from the M1 JSON
#   2. compile every shader to SPIR-V and validate it
#   3. build and run the CPU twin tests
#
# A GPU is not required and is not used. Compiled SPIR-V proves the shaders are
# syntactically and semantically valid; it does not prove they execute correctly.
set -euo pipefail
cd "$(dirname "$0")"

find_tool() {
	if command -v "$1" >/dev/null 2>&1; then
		command -v "$1"
	else
		echo "/opt/homebrew/bin/$1"
	fi
}

GLSLANG="${GLSLANG:-$(find_tool glslangValidator)}"
SPIRV_VAL="${SPIRV_VAL:-$(find_tool spirv-val)}"
CXX="${CXX:-clang++}"
CXXFLAGS="${CXXFLAGS:-}"

mkdir -p build/shaders

python3 make_fixture_bin.py

shopt -s nullglob
shaders=(shaders/*.comp)
if [ ${#shaders[@]} -eq 0 ]; then
	echo "no shaders found" >&2
	exit 1
fi

for f in "${shaders[@]}"; do
	name=$(basename "$f" .comp)
	out="build/shaders/$name.comp"
	# The common block must follow #version, and the shader's #version may not be
	# its first line (files start with a comment), so hoist it explicitly.
	{ echo "#version 450"; cat shaders/hddagi_sparse_brick_common.glsl; grep -v '^#version' "$f"; } > "$out"
	"$GLSLANG" -V --target-env vulkan1.0 -o "build/shaders/$name.spv" "$out" >/dev/null
	"$SPIRV_VAL" "build/shaders/$name.spv"
	echo "  ok  $name.spv"
done

"$CXX" -std=c++17 -O2 -g -Wall -Wextra -Wno-unused-parameter $CXXFLAGS \
	-o build/test_gpu_model test_gpu_model.cpp

exec ./build/test_gpu_model "$@"
