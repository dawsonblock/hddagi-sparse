#!/usr/bin/env bash
# Executes the sparse-brick kernels on this machine's GPU.
#
#   GLSL -> SPIR-V (glslang) -> MSL (spirv-cross) -> Metal
#
# This is not Vulkan and not the engine. It exists because it can run here, and
# because running the real compiled shader on real hardware catches a class of bug
# that neither the CPU twin nor spirv-val can: dispatch sizing.
set -euo pipefail
cd "$(dirname "$0")"

CXX="${CXX:-clang++}"
mkdir -p build/shaders

# 1. Shaders + fixtures + CPU twin.
./build.sh >/dev/null

# 2. SPIR-V -> MSL.
for name in hddagi_sparse_brick_probe hddagi_sparse_brick_canary_write \
		hddagi_sparse_brick_canary_check hddagi_sparse_brick_manage; do
	short="${name#hddagi_sparse_brick_}"
	/usr/local/bin/spirv-cross --msl --msl-version 30000 \
		"build/shaders/$name.spv" > "build/shaders/$short.msl"
done

# 3. Harnesses.
swiftc -O -o build/run_probe metal/run_probe.swift
swiftc -O -o build/run_canary metal/run_canary.swift
swiftc -O -o build/run_manage metal/run_manage.swift

echo
echo "== translation parity (1,180 fixtures) =="
./build/run_probe build/shaders/probe.msl fixtures/probe_fixtures.json fixtures/probe_fixtures.bin

echo
echo "== atlas canary (1,024 pages, 64x64x128) =="
./build/run_canary build/shaders/canary_write.msl build/shaders/canary_check.msl 1024 8 8 16

echo
echo "== allocator (4,096 slots, 256 pages, 300 requests) =="
./build/run_manage build/shaders/manage.msl 4096 256 300

echo
echo "all GPU checks passed"
