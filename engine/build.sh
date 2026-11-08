#!/usr/bin/env bash
# Builds and runs the M2.01 / M2.04 decision-core tests. No engine, no GPU.
set -euo pipefail
cd "$(dirname "$0")"
CXX="${CXX:-clang++}"
CXXFLAGS="${CXXFLAGS:-}"
mkdir -p build
"$CXX" -std=c++17 -O2 -g -Wall -Wextra -Wno-unused-parameter $CXXFLAGS \
	-o build/test_sparse_plan hddagi_sparse_plan.cpp test_sparse_plan.cpp
exec ./build/test_sparse_plan "$@"
