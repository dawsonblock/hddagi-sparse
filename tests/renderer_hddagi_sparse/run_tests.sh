#!/usr/bin/env bash
# Builds and runs the M1 CPU oracle. No engine, no GPU, no external dependencies.
#
#   ./run_tests.sh              run only
#   ./run_tests.sh --fixtures   also regenerate fixtures/
set -euo pipefail

cd "$(dirname "$0")"

CXX="${CXX:-clang++}"
CXXFLAGS="${CXXFLAGS:-}"
BUILD="${BUILD:-build}"
mkdir -p "$BUILD"

SOURCES=(
	hddagi_brick_allocator.cpp
	test_main.cpp
	test_brick_addressing.cpp
	test_brick_allocator.cpp
	test_scroll_replay.cpp
	test_randomized.cpp
	test_negative.cpp
	test_format_roundtrip.cpp
)

"$CXX" -std=c++17 -O2 -g -Wall -Wextra $CXXFLAGS \
	-Wno-unused-parameter \
	-o "$BUILD/run_tests" \
	"${SOURCES[@]}"

exec "./$BUILD/run_tests" "$@"
